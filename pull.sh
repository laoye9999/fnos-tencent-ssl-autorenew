#!/bin/bash
# ============================================================
#  一键拉取脚本: 从 GitHub 拉取最新代码到飞牛 NAS
#  自动检查/安装环境依赖 → 弹出菜单: 1 一键安装  2 一键卸载
#
#  用法:
#    bash pull.sh              # 拉取后显示菜单,手动选择(公开仓库无需令牌)
#    bash pull.sh 1            # 拉取后直接执行 1=安装 / 2=卸载 / q=退出
#    bash pull.sh <token>      # 私有 fork 可传入只读 token
# ============================================================
set -euo pipefail

REPO="laoye9999/fnos-tencent-ssl-autorenew"
BRANCH="main"
TARGET="${TARGET:-/vol1/1000/fnos-tencent-ssl-autorenew}"

# ---------- 0. 解析参数 ----------
# 兼容 curl | bash 拉取方式: 标准输入若是管道(不是终端),改从终端读取,
# 否则菜单的 read 会读到管道 EOF 而直接退出,用户来不及选择。
if [ ! -t 0 ] && [ -t /dev/tty ]; then
    exec < /dev/tty
fi

# 通过 /tmp 方式拉取执行时(bash /tmp/fnos-pull.sh),退出前清理自身
cleanup_self() {
    case "$0" in
        /tmp/fnos-pull.sh) rm -f "$0" ;;
    esac
}
trap cleanup_self EXIT

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
echo "[拉取] 正在从 GitHub 下载最新代码..."
TMP_ZIP="/tmp/fnos-ssl-repo.zip"
TMP_DIR="/tmp/fnos-ssl-pull"
AUTH_ARGS=()
if [ -n "$TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer $TOKEN")  # 仓库公开时无需令牌;私有 fork 可传 token
fi
curl -fsSL "${AUTH_ARGS[@]}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/zipball/$BRANCH" -o "$TMP_ZIP" \
    || { echo "[错误] 下载失败,请检查网络,或确认仓库地址: https://github.com/$REPO"; exit 1; }
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
