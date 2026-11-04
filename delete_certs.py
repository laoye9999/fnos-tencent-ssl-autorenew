#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
删除腾讯云 SSL 证书(谨慎使用!)

用法:
  python3 delete_certs.py                     # 仅列出 config.json 中域名下的免费证书(只读)
  python3 delete_certs.py --delete            # 列出后需输入 YES 确认,逐个删除(全部状态)
  python3 delete_certs.py --delete --issued-only
                                              # 只删除"已签发"的,保留"正在申请"的

注意:
  - 删除后无法恢复!
  - 只处理免费证书(90 天),收费证书不会被列入删除列表。
  - 已部署到腾讯云云资源(CDN/CLB 等)的证书可能删除失败,脚本会提示原因。
  - 本地已下载的证书文件不受影响,但删除后无法再从腾讯云下载该证书。
"""

import os
import sys
import json
import argparse
import datetime
import logging

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.json")

from tencentcloud.common import credential
from tencentcloud.common.profile.client_profile import ClientProfile
from tencentcloud.common.profile.http_profile import HttpProfile
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.ssl.v20191205 import ssl_client, models

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("tencent-ssl-delete")


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


def list_certs(client, domains):
    """返回 [(域名, 证书对象)]:免费证书中域名匹配 config 里 domains 的。"""
    req = models.DescribeCertificatesRequest()
    req.FilterSource = "buy"
    req.Limit = 50
    resp = client.DescribeCertificates(req)
    out = []
    for c in resp.Certificates or []:
        if getattr(c, "PackageType", None) != "83":  # 只列免费证书
            continue
        dom = getattr(c, "Domain", "") or ""
        if any(d in dom for d in domains):
            out.append((dom, c))
    return out


def fmt_time(s):
    if not s:
        return "未知"
    return s.replace("T", " ").replace("Z", "")[:19]


STATUS_MAP = {0: "审核中", 1: "已签发", 2: "审核失败", 3: "已过期"}


def main():
    parser = argparse.ArgumentParser(description="删除腾讯云 SSL 证书")
    parser.add_argument("--delete", action="store_true", help="确认后删除列出的证书(默认仅列出,不删除)")
    parser.add_argument("--issued-only", action="store_true", help="只删除已签发的证书,保留正在申请(审核中)的")
    args = parser.parse_args()

    cfg = load_config()
    client = get_client(cfg["secret_id"], cfg["secret_key"])

    certs = list_certs(client, cfg["domains"])
    if not certs:
        print("未找到匹配的免费证书(域名: %s)" % ", ".join(cfg["domains"]))
        return

    # 找出最新的一张(到期时间最晚),列表里做标记
    newest_id, best_end = None, None
    for dom, c in certs:
        end = getattr(c, "CertEndTime", None)
        if end and (best_end is None or end > best_end):
            best_end, newest_id = end, getattr(c, "CertificateId", None)

    print("")
    print("找到 %d 张免费证书,涉及域名: %s" % (
        len(certs), ", ".join(dict.fromkeys(d for d, _ in certs))))
    print("-" * 60)
    for i, (dom, c) in enumerate(certs, 1):
        cid = getattr(c, "CertificateId", "未知")
        tag = "   ← 最新" if cid == newest_id else ""
        print("[%d] 域名: %s%s" % (i, dom, tag))
        print("    证书ID: %s" % cid)
        print("    生效: %s" % fmt_time(getattr(c, "CertBeginTime", None)))
        print("    到期: %s" % fmt_time(getattr(c, "CertEndTime", None)))
        print("    状态: %s(%s)" % (
            getattr(c, "Status", "未知"),
            STATUS_MAP.get(getattr(c, "Status", None), "未知")))
    print("-" * 60)

    if not args.delete:
        print("当前为只读模式,未做任何删除。")
        print("确认删除请运行: python3 delete_certs.py --delete")
        return

    # 确定删除范围
    targets = certs
    skipped = []
    if args.issued_only:
        targets = [(d, c) for d, c in certs if getattr(c, "Status", None) == 1]
        skipped = [(d, c) for d, c in certs if getattr(c, "Status", None) != 1]
        if skipped:
            print("")
            print("将保留以下 %d 张正在申请/其他状态的证书:" % len(skipped))
            for d, c in skipped:
                print("  - %s (%s,%s)" % (
                    d, getattr(c, "CertificateId", "?"),
                    STATUS_MAP.get(getattr(c, "Status", None), "未知")))
        if not targets:
            print("没有已签发的证书,无需删除,已取消。")
            return

    print("")
    print("!!! 删除后无法恢复 !!!")
    print("本地已下载的证书文件不受影响,但删除后无法再从腾讯云下载该证书。")
    try:
        ans = input("确认删除以上 %d 张证书? 输入 YES 继续,其他任意键取消: " % len(targets))
    except EOFError:
        ans = ""
    if ans.strip() != "YES":
        print("已取消,未删除任何证书。")
        return

    ok = fail = 0
    for dom, c in targets:
        cert_id = getattr(c, "CertificateId", None)
        try:
            req = models.DeleteCertificateRequest()
            req.CertificateId = cert_id
            client.DeleteCertificate(req)
            log.info("已删除: %s (%s)", dom, cert_id)
            ok += 1
        except TencentCloudSDKException as e:
            log.error("删除失败: %s (%s): %s", dom, cert_id, e)
            fail += 1
        except Exception as e:
            log.error("删除异常: %s (%s): %s", dom, cert_id, e)
            fail += 1
    print("")
    print("删除完成: 成功 %d 张,失败 %d 张" % (ok, fail))
    if fail:
        print("失败的通常是已部署到腾讯云云资源的证书,需先在控制台取消部署,或登录控制台查看原因。")


if __name__ == "__main__":
    main()
