#!/bin/bash
# ============================================================
#  一键拉取脚本: 从 GitHub 拉取最新代码到飞牛 NAS
#  自动检查/安装环境依赖 → 弹出菜单: 1 一键安装  2 一键卸载
#
#  用法:
#    bash pull.sh              # 拉取后显示菜单,手动选择
#    bash pull.sh <token>      # 提前传入 GitHub 只读 token(不交互询问)
#    bash pull.sh 1 <token>    # 拉取后直接执行 1=安装 / 2=卸载 / q=退出
# ============================================================
set -euo pipefail

REPO="laoye9999/fnos-tencent-ssl-autorenew"
BRANCH="main"
TARGET="${TARGET:-/vol1/1000/fnos-tencent-ssl-autorenew}"

# ---------- 0. 解析参数 ----------
TOKEN=""
CHOICE=""
for arg in "$@"; do
    case "$arg" in
        1|2|q|Q) CHOICE="$arg" ;;
        *) TOKEN="$arg" ;;
    esac
done

echo ""
echo "=========================================================="
echo " 腾讯云 SSL 证书自动续期 + 到期提醒 —— 一键拉取"
echo "=========================================================="
echo ""

# ---------- 1. 环境检查:缺失的工具自动安装 ----------
echo "[环境] 正在检查依赖工具 (curl / unzip / python3) ..."
need_pkgs=""
command -v curl   >/dev/null 2>&1 || need_pkgs="$need_pkgs curl"
command -v unzip  >/dev/null 2>&1 || need_pkgs="$need_pkgs unzip"
command -v python3 >/dev/null 2>&1 || need_pkgs="$need_pkgs python3"
command -v sudo   >/dev/null 2>&1 || { echo "[错误] 未找到 sudo,请手动安装后重试。"; exit 1; }

if [ -n "$need_pkgs" ]; then
    echo "[环境] 缺少工具:$need_pkgs,正在自动安装..."
    read -r -s -p "请输入 sudo 密码(用于安装系统工具): " SUDO_PW; echo ""
    echo "$SUDO_PW" | sudo -S -p "" apt-get update -qq >/dev/null 2>&1 || true
    echo "$SUDO_PW" | sudo -S -p "" apt-get install -y -qq $need_pkgs
    for c in $need_pkgs; do
        command -v "$c" >/dev/null 2>&1 || { echo "[错误] 工具 $c 安装失败,请手动安装后重试。"; exit 1; }
    done
    echo "[环境] 工具安装完成 ✓"
else
    echo "[环境] 依赖工具齐全 ✓"
fi

[ -d /vol1/1000 ] || { echo "[错误] 未找到 /vol1/1000 目录,此脚本仅适配飞牛 fnOS。"; exit 1; }
echo "[环境] 目标目录 /vol1/1000 正常 ✓"
echo ""

# ---------- 2. 拉取最新代码 ----------
if [ -z "$TOKEN" ]; then
    read -r -s -p "请输入 GitHub 只读访问令牌(输入不回显): " TOKEN
    echo ""
fi

echo "[拉取] 正在从 GitHub 下载最新代码..."
TMP_ZIP="/tmp/fnos-ssl-repo.zip"
TMP_DIR="/tmp/fnos-ssl-pull"
curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/zipball/$BRANCH" -o "$TMP_ZIP" \
    || { echo "[错误] 下载失败,请检查 token 是否有效(需要本仓库只读权限)。"; exit 1; }
rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
unzip -qo "$TMP_ZIP" -d "$TMP_DIR"
SRC_DIR="$(ls -d "$TMP_DIR"/*/ | head -1)"
mkdir -p "$TARGET"
cp -rf "$SRC_DIR". "$TARGET/"
rm -rf "$TMP_DIR" "$TMP_ZIP"
echo "[完成] 最新代码已就绪: $TARGET"
echo ""

# ---------- 3. 菜单 / 直接执行 ----------
run_choice() {
    case "$1" in
        1) bash "$TARGET/install.sh" ;;
        2) bash "$TARGET/uninstall.sh" ;;
        q|Q) echo "已退出。"; exit 0 ;;
        *) echo "输入无效,请输入 1、2 或 q。"; return 1 ;;
    esac
}

if [ -n "$CHOICE" ]; then
    echo "[执行] 直接执行所选操作: $CHOICE"
    run_choice "$CHOICE"
else
    while true; do
        echo "=========================================================="
        echo " 代码已就绪,请选择操作"
        echo "=========================================================="
        echo "  1. 一键安装"
        echo "  2. 一键卸载"
        echo "  q. 退出"
        echo "----------------------------------------------------------"
        read -r -p "请选择 [1/2/q]: " c
        run_choice "$c" && break
    done
fi
