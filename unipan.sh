#!/bin/bash

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}开始彻底卸载 Realm 面板及 Rust 环境...${RESET}"

# 1. 停止并删除面板服务
echo -e ">>> 正在停止面板服务..."
systemctl stop realm-panel >/dev/null 2>&1
systemctl disable realm-panel >/dev/null 2>&1
rm -f /etc/systemd/system/realm-panel.service
systemctl daemon-reload
echo -e "${GREEN}[1/6] 面板服务已移除${RESET}"

# 2. 清理流量统计防火墙规则 
echo -e ">>> 正在清理流量统计规则..."
# 移除主链的引用
iptables -D INPUT -j REALM_IN 2>/dev/null || true
iptables -D OUTPUT -j REALM_OUT 2>/dev/null || true
# 清空自定义链
iptables -F REALM_IN 2>/dev/null || true
iptables -F REALM_OUT 2>/dev/null || true
# 删除自定义链
iptables -X REALM_IN 2>/dev/null || true
iptables -X REALM_OUT 2>/dev/null || true
echo -e "${GREEN}[2/6] 流量统计规则已清理${RESET}"

# 3. 删除面板程序及数据文件
echo -e ">>> 正在清理程序文件和配置文件..."
rm -f /usr/local/bin/realm-panel
rm -rf /opt/realm_panel
rm -f /etc/realm/panel_data.json 
echo -e "${GREEN}[3/6] 程序及数据文件已清理${RESET}"

# 4. 彻底卸载 Rust 环境
echo -e ">>> 正在卸载 Rust 环境..."
if command -v rustup &> /dev/null; then
    rustup self uninstall -y >/dev/null 2>&1
fi
# 强制清理可能残留的目录
rm -rf "$HOME/.cargo"
rm -rf "$HOME/.rustup"
# 清理环境变量设置
sed -i '/.cargo\/env/d' "$HOME/.bashrc"
echo -e "${GREEN}[4/6] Rust 环境已彻底移除${RESET}"

# 5. 清理系统编译依赖 
echo -e ">>> 正在清理系统编译依赖..."
if [ -f /etc/debian_version ]; then
    apt-get remove --purge -y build-essential pkg-config libssl-dev >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupremove -y "Development Tools" >/dev/null 2>&1
    yum remove -y openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN}[5/6] 系统编译依赖已清理${RESET}"

# 6. 清理临时文件
echo -e ">>> 正在清理临时文件..."
rm -rf /tmp/realm_tmp
echo -e "${GREEN}[6/6] 临时文件已清理${RESET}"

echo -e "\n${GREEN}==========================================${RESET}"
echo -e "${GREEN}       Realm 转发面板卸载完成！      ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

