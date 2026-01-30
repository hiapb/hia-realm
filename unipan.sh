#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}正在卸载 Realm 面板...${RESET}"

systemctl stop realm-panel >/dev/null 2>&1
systemctl disable realm-panel >/dev/null 2>&1
rm -f /etc/systemd/system/realm-panel.service
systemctl daemon-reload
echo -e "${GREEN}面板服务已卸载${RESET}"

iptables -D INPUT -j REALM_IN 2>/dev/null || true
iptables -D OUTPUT -j REALM_OUT 2>/dev/null || true
iptables -F REALM_IN 2>/dev/null || true
iptables -F REALM_OUT 2>/dev/null || true
iptables -X REALM_IN 2>/dev/null || true
iptables -X REALM_OUT 2>/dev/null || true
echo -e "${GREEN}面板防火墙规则已清理${RESET}"

rm -f /etc/cron.d/realm-rules-export
rm -f /usr/local/bin/realm-export-rules.sh
echo -e "${GREEN}定时任务已移除${RESET}"

rm -f /usr/local/bin/realm-panel
rm -rf /opt/realm_panel
rm -f /etc/realm/panel_data.json 

if [ -d "/etc/realm/backups" ]; then
    echo -e "${YELLOW}检测到备份文件 (/etc/realm/backups/)${RESET}"
    read -p "是否删除所有备份？[y/N]: " del_bk
    case "$del_bk" in
        y|Y) 
            rm -rf /etc/realm/backups
            echo -e "${GREEN}备份已删除${RESET}" 
            ;;
        *) 
            echo -e "${GREEN}备份已保留${RESET}" 
            ;;
    esac
fi
echo -e "${GREEN}面板文件已清理${RESET}"

if command -v rustup &> /dev/null; then
    rustup self uninstall -y >/dev/null 2>&1
fi
rm -rf "$HOME/.cargo"
rm -rf "$HOME/.rustup"
sed -i '/.cargo\/env/d' "$HOME/.bashrc"
echo -e "${GREEN}Rust 环境已卸载${RESET}"

if [ -f /etc/debian_version ]; then
    apt-get remove --purge -y build-essential pkg-config libssl-dev >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupremove -y "Development Tools" >/dev/null 2>&1
    yum remove -y openssl-devel >/dev/null 2>&1
fi
rm -rf /tmp/realm_install
rm -rf /tmp/realm_tmp
echo -e "${GREEN}编译依赖已清理${RESET}"

echo -e "\n${GREEN}==========================================${RESET}"
echo -e "${GREEN}       Realm 面板卸载成功！      ${RESET}"
echo -e "${GREEN}==========================================${RESET}"
