#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
飞牛 NAS 版：腾讯云免费 SSL 证书（90天）自动续期，直接写本地目录。

流程：
  1. 检查该域名最新的免费证书，若距到期还早（> renew_before_days 天）则跳过。
  2. 否则 ApplyCertificate(DNS_AUTO) 申请新证书 → CompleteCertificate 触发验证 → 轮询签发。
  3. 下载证书，解出 fullchain + 私钥，写入 output_dir/<domain>/（另归档一份带日期）。
"""

import os
import sys
import json
import base64
import io
import zipfile
import datetime
import logging
import argparse
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))  # 本地 SDK 依赖（必须先于 tencentcloud 导入）
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.json")
LOG_PATH = os.path.join(SCRIPT_DIR, "renew.log")

from tencentcloud.common import credential
from tencentcloud.common.profile.client_profile import ClientProfile
from tencentcloud.common.profile.http_profile import HttpProfile
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.ssl.v20191205 import ssl_client, models

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
    ],
)
log = logging.getLogger("tencent-ssl")


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    for key in ("secret_id", "secret_key", "domains"):
        if key not in cfg:
            raise SystemExit("config.json 缺少字段: %s" % key)
    if cfg.get("secret_id", "").startswith("YOUR_"):
        raise SystemExit("config.json 里还是占位符，请先填入真实的 SecretId/SecretKey")
    return cfg


def get_client(secret_id, secret_key):
    cred = credential.Credential(secret_id, secret_key)
    hp = HttpProfile()
    hp.endpoint = "ssl.tencentcloudapi.com"
    cp = ClientProfile()
    cp.httpProfile = hp
    return ssl_client.SslClient(cred, "", cp)


def parse_time(s):
    if not s:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(s, fmt)
        except (ValueError, TypeError):
            continue
    return None


def find_latest_cert(client, domain):
    req = models.DescribeCertificatesRequest()
    req.SearchKey = domain
    req.FilterSource = "buy"
    req.Limit = 50
    resp = client.DescribeCertificates(req)
    best, best_end = None, None
    for c in resp.Certificates or []:
        if getattr(c, "Status", None) != 1:
            continue
        if getattr(c, "PackageType", None) != "83":  # 只统计免费证书
            continue
        if domain not in (getattr(c, "Domain", "") or ""):
            continue
        end = parse_time(getattr(c, "CertEndTime", None))
        if end and (best_end is None or end > best_end):
            best, best_end = c, end
    return best


def apply_cert(client, domain):
    req = models.ApplyCertificateRequest()
    req.DvAuthMethod = "DNS_AUTO"
    req.DomainName = domain
    req.PackageType = "83"
    req.ValidityPeriod = "3"
    req.CsrEncryptAlgo = "RSA"
    return client.ApplyCertificate(req).CertificateId


def complete_verification(client, cert_id):
    req = models.CompleteCertificateRequest()
    req.CertificateId = cert_id
    client.CompleteCertificate(req)


def poll_issued(client, cert_id, timeout_min=20, interval=15):
    import time
    deadline = datetime.datetime.now() + datetime.timedelta(minutes=timeout_min)
    while datetime.datetime.now() < deadline:
        req = models.DescribeCertificatesRequest()
        req.CertIds = [cert_id]
        for c in (client.DescribeCertificates(req).Certificates or []):
            if getattr(c, "CertificateId", None) == cert_id:
                log.info("证书 %s 状态=%s (%s)", cert_id, getattr(c, "Status", None), getattr(c, "StatusMsg", "") or "")
                if getattr(c, "Status", None) == 1:
                    return c
        time.sleep(interval)
    return None


def download_zip(client, cert_id):
    req = models.DownloadCertificateRequest()
    req.CertificateId = cert_id
    return base64.b64decode(client.DownloadCertificate(req).Content)


def extract_cert_and_key(zip_bytes):
    zf = zipfile.ZipFile(io.BytesIO(zip_bytes))
    key_bytes, fullchain_bytes, best_count = None, None, 0
    for name in zf.namelist():
        if name.endswith("/"):
            continue
        data = zf.read(name)
        try:
            text = data.decode("utf-8", errors="ignore")
        except Exception:
            text = ""
        if "PRIVATE KEY" in text:
            key_bytes = data
        elif "BEGIN CERTIFICATE" in text:
            cnt = text.count("BEGIN CERTIFICATE")
            if cnt > best_count:
                best_count, fullchain_bytes = cnt, data
    if key_bytes is None:
        for name in zf.namelist():
            if name.lower().endswith(".key"):
                key_bytes = zf.read(name)
                break
    if fullchain_bytes is None:
        for name in zf.namelist():
            low = name.lower()
            if ("bundle" in low or "fullchain" in low) and low.endswith((".crt", ".pem")):
                fullchain_bytes = zf.read(name)
                break
    if fullchain_bytes is None:
        for name in zf.namelist():
            if name.lower().endswith((".crt", ".pem")):
                fullchain_bytes = zf.read(name)
                break
    if fullchain_bytes is None or key_bytes is None:
        raise SystemExit("无法从下载包中识别出证书/私钥文件")
    return fullchain_bytes, key_bytes


def write_output(cfg, domain, zip_bytes, fullchain_bytes, key_bytes):
    out_root = cfg.get("output_dir", "/vol1/1000/certs")
    target = os.path.join(out_root, domain)
    os.makedirs(target, exist_ok=True)

    crt_path = os.path.join(target, "%s.crt" % domain)
    key_path = os.path.join(target, "%s.key" % domain)
    with open(crt_path, "wb") as f:
        f.write(fullchain_bytes)
    with open(key_path, "wb") as f:
        f.write(key_bytes)

    archive = os.path.join(target, "archive", datetime.date.today().isoformat())
    os.makedirs(archive, exist_ok=True)
    with open(os.path.join(archive, "%s.crt" % domain), "wb") as f:
        f.write(fullchain_bytes)
    with open(os.path.join(archive, "%s.key" % domain), "wb") as f:
        f.write(key_bytes)
    with open(os.path.join(archive, "%s.zip" % domain), "wb") as f:
        f.write(zip_bytes)

    log.info("证书已写入: %s", target)
    return target


def write_countdown_txt(cfg, domain, end_time, status):
    """把检查时间、到期时间、剩余天数写入倒计时 txt。"""
    path = cfg.get("txt_path", "/vol1/1000/证书到期倒计时.txt")
    now = datetime.datetime.now()
    if end_time is not None:
        remain = max(0, (end_time - now).days)
        end_str = end_time.strftime("%Y-%m-%d")
        remain_str = "%d 天" % remain
    else:
        end_str, remain_str = "未知", "未知"
    lines = [
        "%s 证书到期倒计时" % domain,
        "=" * 26,
        "检查时间：%s" % now.strftime("%Y-%m-%d %H:%M"),
        "到期时间：%s" % end_str,
        "剩余天数：%s" % remain_str,
        "状态：%s" % status,
    ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    log.info("已写入倒计时文件: %s", path)


def send_notification(cfg, domain, end_time, status):
    """往飞牛系统通知里发一条倒计时提醒（纯中文，删掉旧的同名通知避免堆积）。"""
    now = datetime.datetime.now()
    title = "证书到期倒计时"
    if end_time is not None:
        remain = max(0, (end_time - now).days)
        end_str = end_time.strftime("%Y-%m-%d")
        if "续期" in status:
            content = "%s 证书已自动续期，剩余 %d 天到期（%s）" % (domain, remain, end_str)
        else:
            content = "%s 证书剩余 %d 天到期（%s）" % (domain, remain, end_str)
    else:
        content = "%s 证书状态异常，请登录腾讯云查看" % domain

    title_s = title.replace("'", "''")
    content_s = content.replace("'", "''")
    sql = (
        "DELETE FROM notify_user WHERE notify_id IN (SELECT id FROM notify WHERE title = '%s');\n"
        "DELETE FROM notify WHERE title = '%s';\n"
        "WITH n AS (INSERT INTO notify (cat, level, title, source, content, dateandtime) "
        "VALUES (1, 0, '%s', 'main', '%s', extract(epoch from now())::bigint) RETURNING id) "
        "INSERT INTO notify_user (uid, notify_id, read) SELECT 1000, id, 0 FROM n;"
    ) % (title_s, title_s, title_s, content_s)

    tmp = "/tmp/ssl_notify_%d.sql" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(sql)
        pw = cfg.get("sudo_password", "")
        p = subprocess.run(
            ["sudo", "-S", "-p", "", "psql", "-U", "postgres", "-d", "trim", "-f", tmp],
            input=(pw + "\n"), capture_output=True, text=True,
        )
        if p.returncode != 0:
            log.error("发送系统通知失败: %s", p.stderr.strip())
        else:
            log.info("已发送系统通知: %s", content)
    except Exception as e:
        log.error("发送系统通知异常: %s", e)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def process_domain(client, cfg, domain, force):
    log.info("=" * 60)
    log.info("处理域名: %s", domain)

    latest = find_latest_cert(client, domain)
    cur_end = parse_time(getattr(latest, "CertEndTime", None)) if latest else None

    if not force and cur_end is not None:
        remain = (cur_end - datetime.datetime.now()).days
        if remain > int(cfg.get("renew_before_days", 20)):
            log.info("证书仍有效（%s 到期，还剩 %d 天），跳过", cur_end, remain)
            write_countdown_txt(cfg, domain, cur_end, "正常，无需更新")
            send_notification(cfg, domain, cur_end, "正常，无需更新")
            return
        log.info("证书将在 %d 天后到期，开始续期", remain)

    cert_id = apply_cert(client, domain)
    log.info("已申请 CertificateId=%s", cert_id)
    try:
        complete_verification(client, cert_id)
        log.info("已触发域名验证")
    except TencentCloudSDKException as e:
        log.warning("触发验证失败（可能已自动验证中），继续轮询: %s", e)

    cert = poll_issued(client, cert_id)
    if cert is None:
        log.error("证书 %s 超时未签发，请到腾讯云控制台查看", cert_id)
        write_countdown_txt(cfg, domain, cur_end, "续期超时，请检查")
        send_notification(cfg, domain, cur_end, "续期超时，请检查")
        return

    log.info("证书已签发，开始下载")
    zip_bytes = download_zip(client, cert_id)
    fullchain_bytes, key_bytes = extract_cert_and_key(zip_bytes)
    dated = write_output(cfg, domain, zip_bytes, fullchain_bytes, key_bytes)
    new_end = parse_time(getattr(cert, "CertEndTime", None))
    write_countdown_txt(cfg, domain, new_end, "已自动续期")
    send_notification(cfg, domain, new_end, "已自动续期")
    log.info("域名 %s 续期完成 → %s", domain, dated)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="忽略到期检查，强制申请新证书")
    args = parser.parse_args()

    cfg = load_config()
    client = get_client(cfg["secret_id"], cfg["secret_key"])
    for domain in cfg["domains"]:
        try:
            process_domain(client, cfg, domain, args.force)
        except TencentCloudSDKException as e:
            log.error("域名 %s 处理出错: %s", domain, e)
        except Exception:
            log.exception("域名 %s 出现未预期错误", domain)


if __name__ == "__main__":
    main()
