#!/usr/bin/env bash
# 自动适配脚本 - 无需手动选择版本

set -e

# 检查系统版本
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    echo "[错误] 无法识别系统版本。"
    exit 1
fi

# 判断执行哪个脚本
if [ "$OS" = "debian" ] && [ "$VER" = "12" ]; then
    echo "[+] 检测到 Debian 12，正在执行优化..."
    bash <(curl -sL https://raw.githubusercontent.com/Samzzj/vps-3xui-Network-optimization/main/debian12.sh) apply
elif [ "$OS" = "debian" ] && [ "$VER" = "13" ]; then
    echo "[+] 检测到 Debian 13，正在执行优化..."
    bash <(curl -sL https://raw.githubusercontent.com/Samzzj/vps-3xui-Network-optimization/main/debian13.sh) apply
else
    echo "[错误] 仅支持 Debian 12 或 13，当前系统为 $OS $VER"
    exit 1
fi