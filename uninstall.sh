#!/bin/bash
# ============================================================
#  腾讯云免费 SSL 证书自动续期 + 飞牛到期提醒 —— 一键卸载脚本
#  使用方法: 在本仓库目录执行: bash uninstall.sh
#            或执行 bash pull.sh 后在菜单中选择 2
# ============================================================
set -euo pipefail

INSTALL_DIR="/vol1/1000/tencent-ssl"

echo ""
echo "=========================================================="
echo " 卸载腾讯云 SSL 证书自动续期脚本"
echo "=========================================================="
echo ""
echo "将执行: 1) 删除定时任务  2) 删除 $INSTALL_DIR"
read -r -p "确认卸载? [y/N]: " yn
case "$yn" in
    [Yy]*) : ;;
    *) echo "已取消。"; exit 0 ;;
esac

# ---------- 1. 删除定时任务 ----------
# 先写临时文件再安装,避免两个 crontab 进程并行抢锁(见 install.sh 说明)
CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v "tencent-ssl/renew.py" > "$CRON_TMP" || true
crontab "$CRON_TMP" || true
rm -f "$CRON_TMP"
echo "[完成] 已删除定时任务"

# ---------- 2. 删除前读取证书目录与提醒文件路径 ----------
output_dir=""
txt_path=""
if [ -f "$INSTALL_DIR/config.json" ]; then
    output_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("output_dir",""))' "$INSTALL_DIR/config.json" 2>/dev/null || true)"
    txt_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("txt_path",""))' "$INSTALL_DIR/config.json" 2>/dev/null || true)"
fi

# ---------- 3. 删除脚本目录 ----------
rm -rf "$INSTALL_DIR"
echo "[完成] 已删除 $INSTALL_DIR"

# ---------- 4. 询问是否删除证书与提醒文件 ----------
if [ -n "$output_dir" ] && [ -d "$output_dir" ]; then
    read -r -p "是否同时删除已下载的证书目录 $output_dir ? [y/N]: " yn
    case "$yn" in
        [Yy]*) rm -rf "$output_dir"; echo "[完成] 已删除 $output_dir" ;;
        *) echo "[信息] 已保留 $output_dir" ;;
    esac
fi
if [ -n "$txt_path" ] && [ -f "$txt_path" ]; then
    read -r -p "是否同时删除倒计时提醒文件 $txt_path ? [y/N]: " yn
    case "$yn" in
        [Yy]*) rm -f "$txt_path"; echo "[完成] 已删除 $txt_path" ;;
        *) echo "[信息] 已保留 $txt_path" ;;
    esac
fi

echo ""
echo "=========================================================="
echo " 卸载完成"
echo "=========================================================="
