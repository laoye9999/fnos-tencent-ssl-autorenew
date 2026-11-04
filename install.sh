#!/bin/bash
# ============================================================
#  腾讯云免费 SSL 证书自动续期 + 飞牛到期提醒 —— 一键部署脚本
#  使用方法: 把本仓库放到飞牛 NAS 上(任意目录),然后执行:
#            bash install.sh
#  交互式填写腾讯云 API 密钥和域名后,自动完成:
#  部署 → 安装定时任务 → 首次自动申请/下载证书 → 发通知
#  也可以先手动编辑好 config.json(参考 config.json.example)
#  放在本脚本同目录,执行时会跳过交互提问。
# ============================================================
set -euo pipefail

INSTALL_DIR="/vol1/1000/tencent-ssl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=========================================================="
echo " 腾讯云 SSL 证书自动续期 + 飞牛到期提醒 —— 一键部署"
echo "=========================================================="
echo ""

# ---------- 0. 环境检查 ----------
if [ ! -f "$SCRIPT_DIR/renew.py" ]; then
    echo "[错误] 当前目录没有 renew.py,请先 cd 到本仓库目录再执行。"
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "[错误] 未找到 python3,请先安装 Python 3。"; exit 1; }
[ -d /vol1/1000 ] || { echo "[错误] 未找到 /vol1/1000 目录,此脚本仅适配飞牛 fnOS 默认存储结构。"; exit 1; }

# ---------- 1. 配置 ----------
KEEP_CONFIG=0
if [ -f "$SCRIPT_DIR/config.json" ]; then
    echo "[信息] 检测到仓库目录下已有 config.json,直接使用(跳过提问)。"
elif [ -f "$INSTALL_DIR/config.json" ]; then
    read -r -p "检测到已存在配置 $INSTALL_DIR/config.json,是否保留旧配置? [Y/n]: " yn
    case "$yn" in
        [Nn]*) rm -f "$INSTALL_DIR/config.json" ;;
        *) echo "[信息] 保留现有配置,跳过配置步骤。"; KEEP_CONFIG=1 ;;
    esac
fi

if [ "$KEEP_CONFIG" != "1" ] && [ ! -f "$SCRIPT_DIR/config.json" ]; then
    if [ ! -t 0 ]; then
        echo "[错误] 需要交互式输入配置。可先手动创建 config.json(参考 config.json.example)再执行本脚本。"
        exit 1
    fi
    echo "---------- 填写配置 ----------"
    echo "腾讯云 API 密钥获取: 腾讯云控制台 → 访问管理 → API 密钥管理"
    read -r -p "SecretId: " secret_id
    read -r -s -p "SecretKey(输入不回显): " secret_key; echo ""
    read -r -p "域名(多个用英文逗号分隔,如 www.abc.com,abc.com): " domains
    read -r -p "提前几天续期 [默认20]: " renew_days
    read -r -p "证书输出目录 [默认 /vol1/1000/certs]: " output_dir
    read -r -p "倒计时提醒文件路径 [默认 /vol1/1000/证书到期倒计时.txt]: " txt_path
    read -r -s -p "NAS 用户 sudo 密码(用于发送系统通知,与 SSH 登录密码相同): " sudo_pw; echo ""

    renew_days="${renew_days:-20}"
    output_dir="${output_dir:-/vol1/1000/certs}"
    txt_path="${txt_path:-/vol1/1000/证书到期倒计时.txt}"

    if [ -z "$secret_id" ] || [ -z "$secret_key" ] || [ -z "$domains" ]; then
        echo "[错误] SecretId / SecretKey / 域名 不能为空。"
        exit 1
    fi

    # 域名列表 → JSON 数组
    domains_json=""
    IFS=',' read -r -a arr <<< "$domains"
    for d in "${arr[@]}"; do
        d="$(echo "$d" | xargs)"
        [ -n "$d" ] && domains_json="$domains_json\"$d\", "
    done
    domains_json="[${domains_json%, }]"
    if [ "$domains_json" = "[]" ]; then
        echo "[错误] 域名列表为空。"
        exit 1
    fi

    python3 - "$INSTALL_DIR/config.json.tmp" "$secret_id" "$secret_key" "$domains_json" "$renew_days" "$output_dir" "$txt_path" "$sudo_pw" << 'PYEOF'
import json, sys
cfg = {
    "secret_id": sys.argv[2],
    "secret_key": sys.argv[3],
    "domains": json.loads(sys.argv[4]),
    "renew_before_days": int(sys.argv[5]),
    "output_dir": sys.argv[6],
    "txt_path": sys.argv[7],
    "sudo_password": sys.argv[8],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF
    mv "$INSTALL_DIR/config.json.tmp" "$SCRIPT_DIR/config.json"
fi

# ---------- 2. 部署文件 ----------
echo ""
echo "[部署] 安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/lib"
cp -f "$SCRIPT_DIR/renew.py" "$INSTALL_DIR/renew.py"
cp -rf "$SCRIPT_DIR/lib/." "$INSTALL_DIR/lib/"
if [ -f "$SCRIPT_DIR/config.json" ]; then
    cp -f "$SCRIPT_DIR/config.json" "$INSTALL_DIR/config.json"
fi
chmod 600 "$INSTALL_DIR/config.json"
echo "[完成] renew.py 与依赖库已安装,config.json 权限已设为 600"

# ---------- 3. 创建输出目录与提醒文件目录 ----------
output_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("output_dir","/vol1/1000/certs"))' "$INSTALL_DIR/config.json")"
txt_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("txt_path","/vol1/1000/证书到期倒计时.txt"))' "$INSTALL_DIR/config.json")"
mkdir -p "$output_dir" "$(dirname "$txt_path")"
echo "[完成] 证书目录: $output_dir"
echo "[完成] 提醒文件: $txt_path"

# ---------- 4. 安装定时任务(幂等) ----------
CRON_L1="30 3 * * * /usr/bin/python3 $INSTALL_DIR/renew.py >> $INSTALL_DIR/cron.log 2>&1"
CRON_L2="@reboot /bin/bash -c 'until [ -f $INSTALL_DIR/renew.py ]; do sleep 10; done; sleep 30; /usr/bin/python3 $INSTALL_DIR/renew.py >> $INSTALL_DIR/cron.log 2>&1'"
{
  crontab -l 2>/dev/null | grep -v "tencent-ssl/renew.py"
  echo "$CRON_L1"
  echo "$CRON_L2"
} | crontab -
echo "[完成] 定时任务已安装: 每天 03:30 自动检查续期 + 开机自检"

# ---------- 5. 首次自动流程:申请/下载证书 ----------
echo ""
echo "[运行] 首次部署自动流程:为新域名自动申请证书,已有有效证书则直接下载..."
echo "       申请 + DNS 自动验证最长约需 1~3 分钟,请稍候..."
/usr/bin/python3 "$INSTALL_DIR/renew.py" || echo "[警告] 自动流程有异常,请查看日志: $INSTALL_DIR/renew.log"

echo ""
echo "=========================================================="
echo " 部署完成!"
echo "   脚本目录:   $INSTALL_DIR"
echo "   配置文件:   $INSTALL_DIR/config.json (权限 600)"
echo "   证书目录:   $output_dir"
echo "   运行日志:   $INSTALL_DIR/renew.log"
echo "   手动重跑:   /usr/bin/python3 $INSTALL_DIR/renew.py --force"
echo "   一键卸载:   在本仓库目录执行 bash uninstall.sh"
echo "=========================================================="
