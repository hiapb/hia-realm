#!/bin/bash
GREEN="\e[32m"
RESET="\e[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.toml"
REALM_SERVICE="realm"
REALM_SYSTEMD="/etc/systemd/system/realm.service"
REALM_URL="https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-musl.tar.gz"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${GREEN}请以 root 用户运行此脚本。${RESET}"
        exit 1
    fi
}

install_realm() {
    mkdir -p /tmp/realm-install && cd /tmp/realm-install
    echo -e "${GREEN}正在下载 Realm...${RESET}"
    curl -L "$REALM_URL" -o realm.tar.gz
    tar -xzf realm.tar.gz
    install -m 755 realm -t /usr/local/bin

    cat > "$REALM_SYSTEMD" <<EOF
[Unit]
Description=Realm Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/realm
    echo "# Realm Config" > "$REALM_CFG"
    systemctl daemon-reexec
    systemctl enable realm
    systemctl start realm
    echo -e "${GREEN}Realm 安装完成。${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN" "$REALM_CFG" "$REALM_SYSTEMD"
    systemctl daemon-reexec
    echo -e "${GREEN}Realm 已卸载。${RESET}"
}

restart_realm() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${RESET}"
}

add_realm_rule() {
    read -p "请输入本机监听端口: " LISTEN_PORT
    read -p "请输入目标 IP:PORT: " TARGET_ADDR
    cat >> "$REALM_CFG" <<EOF
[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$TARGET_ADDR"
type = "tcp+udp"
EOF
    restart_realm
    echo -e "${GREEN}已添加并应用规则。${RESET}"
}

delete_single_rule() {
    echo -e "${GREEN}当前转发规则：${RESET}"
    RULES=($(grep -n '^\[\[endpoints\]\]' "$REALM_CFG" | cut -d: -f1))
    TOTAL=${#RULES[@]}
    for ((i=0; i<TOTAL; i++)); do
        START=${RULES[$i]}
        END=$(( (i+1 < TOTAL) ? ${RULES[$((i+1))]}-1 : $(wc -l < "$REALM_CFG") ))
        sed -n "$START,${END}p" "$REALM_CFG" | nl -v 1
        echo "---"
    done
    read -p "请输入要删除的规则编号: " RULE_NO
    IDX=$((RULE_NO-1))
    START=${RULES[$IDX]}
    END=$(( (IDX+1 < TOTAL) ? ${RULES[$((IDX+1))]}-1 : $(wc -l < "$REALM_CFG") ))
    sed -i "${START},${END}d" "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}规则已删除并重启 Realm。${RESET}"
}

delete_all_rules() {
    sed -i '/\[\[endpoints\]\]/,/^$/d' "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}已删除所有规则。${RESET}"
}

list_realm_rules() {
    echo -e "${GREEN}当前转发规则：${RESET}"
    grep -A 2 '^\[\[endpoints\]\]' "$REALM_CFG" | sed '/^--$/d'
}

view_log() {
    journalctl -u realm --no-pager -n 30
}

view_config() {
    cat "$REALM_CFG"
}

exit_script() {
    echo -e "${GREEN}已退出 Realm 管理脚本。${RESET}"
    exit 0
}

main_menu() {
    while true; do
        echo -e "${GREEN}===== Realm TCP+UDP 转发脚本 =====${RESET}"
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
        echo "0. 退出"
        read -p "请选择一个操作 [0-9]: " CHOICE
        case "$CHOICE" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_realm_rule ;;
            5) delete_single_rule ;;
            6) delete_all_rules ;;
            7) list_realm_rules ;;
            8) view_log ;;
            9) view_config ;;
            0) exit_script ;;
            *) echo -e "${GREEN}请输入正确的选项！${RESET}" ;;
        esac
    done
}

check_root
main_menu
