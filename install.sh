#!/bin/bash
GREEN="\e[32m"
RESET="\e[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.json"
REALM_SERVICE="realm"

if [ "$EUID" -ne 0 ]; then
    echo -e "${GREEN}请以 root 用户运行此脚本。${RESET}"
    exit 1
fi

install_realm() {
    mkdir -p /etc/realm
    curl -Lo $REALM_BIN https://github.com/zhxie/realm/releases/latest/download/realm-linux-amd64
    chmod +x $REALM_BIN
    cat > "$REALM_CFG" <<EOF
{
  "log-level": "info",
  "listen": []
}
EOF
    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
ExecStart=$REALM_BIN -c $REALM_CFG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
    echo -e "${GREEN}Realm 安装并启动成功。${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f $REALM_BIN $REALM_CFG /etc/systemd/system/realm.service
    systemctl daemon-reload
    echo -e "${GREEN}Realm 已卸载。${RESET}"
}

restart_realm() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${RESET}"
}

add_realm_rule() {
    read -p "请输入本机监听端口: " LISTEN_PORT
    read -p "请输入目标 IP:PORT: " TARGET_ADDR

    # 解析原始 JSON 并添加条目
    tmp=$(mktemp)
    jq ".listen += [{\"local\": \":$LISTEN_PORT\", \"remote\": \"$TARGET_ADDR\", \"type\": \"tcp+udp\"}]" "$REALM_CFG" > "$tmp" && mv "$tmp" "$REALM_CFG"
    
    restart_realm
    echo -e "${GREEN}万能转发规则已添加并应用。${RESET}"
}

list_realm_rules() {
    echo -e "${GREEN}当前 Realm 转发规则：${RESET}"
    jq -c '.listen[]' "$REALM_CFG" | nl
}

delete_realm_rule() {
    list_realm_rules
    read -p "请输入要删除的规则编号: " DEL_NO
    tmp=$(mktemp)
    jq "del(.listen[$((DEL_NO-1))])" "$REALM_CFG" > "$tmp" && mv "$tmp" "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}规则编号 $DEL_NO 已删除。${RESET}"
}

delete_all_realm_rules() {
    tmp=$(mktemp)
    jq ".listen = []" "$REALM_CFG" > "$tmp" && mv "$tmp" "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}全部转发规则已清空。${RESET}"
}

view_realm_log() {
    journalctl -u realm -n 50 --no-pager
}

view_realm_config() {
    cat "$REALM_CFG"
}

main_menu() {
    while true; do
        echo -e "${GREEN}===== Realm TCP+UDP转发管理脚本 =====${RESET}"
        echo "1. 安装 Realm"
        echo "2. 卸载 Realm"
        echo "3. 重启 Realm"
        echo "--------------------"
        echo "4. 添加转发规则"
        echo "5. 删除单条规则"
        echo "6. 删除全部规则"
        echo "7. 查看当前规则"
        echo "8. 查看日志"
        echo "9. 查看配置"
        echo "10. 退出"
        read -p "请选择一个操作 [1-10]: " CHOICE
        case "$CHOICE" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_realm_rule ;;
            5) delete_realm_rule ;;
            6) delete_all_realm_rules ;;
            7) list_realm_rules ;;
            8) view_realm_log ;;
            9) view_realm_config ;;
            10) exit 0 ;;
            *) echo -e "${GREEN}请输入正确的选项！${RESET}" ;;
        esac
    done
}

main_menu
