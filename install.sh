#!/bin/bash
CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_URL="https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-musl.tar.gz"
TMP_DIR="/tmp/realm-install"

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以 root 用户运行此脚本。${RESET}"
        exit 1
    fi
}

install_realm() {
    echo -e "${GREEN}正在安装 Realm TCP+UDP转发脚本...${RESET}"
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || exit 1
    curl -L -o realm.tar.gz "$REALM_URL"
    tar -xzf realm.tar.gz
    mv realm "$REALM_BIN"
    chmod +x "$REALM_BIN"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy
After=network.target

[Service]
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p $(dirname "$CONFIG_FILE")
    echo "# 默认配置" > "$CONFIG_FILE"

    systemctl daemon-reexec
    systemctl enable realm
    systemctl restart realm
    echo -e "${GREEN}Realm 安装完成。${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_FILE"
    systemctl daemon-reexec
    echo -e "${GREEN}Realm 已卸载。${RESET}"
}

restart_realm() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${RESET}"
}

add_rule() {
    read -p "请输入监听端口: " LISTEN
    read -p "请输入远程目标 IP:PORT: " REMOTE
    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
listen = "0.0.0.0:$LISTEN"
remote = "$REMOTE"
type = "tcp+udp"
EOF
    restart_realm
    echo -e "${GREEN}已添加规则并重启 Realm。${RESET}"
}

delete_rule() {
    RULES=($(grep -n '\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d: -f1))
    COUNT=${#RULES[@]}
    if [ "$COUNT" -eq 0 ]; then
        echo -e "${RED}无可删除规则。${RESET}"
        return
    fi
    echo "当前转发规则："
    for ((i=0; i<COUNT; i++)); do
        START=${RULES[$i]}
        END=${RULES[$((i+1))]:-99999}
        BLOCK=$(sed -n "$START,$((END-1))p" "$CONFIG_FILE")
        echo -e "$((i+1)). $(echo "$BLOCK" | grep listen | cut -d'"' -f2) -> $(echo "$BLOCK" | grep remote | cut -d'"' -f2)"
    done
    read -p "请输入要删除的规则编号: " IDX
    IDX=$((IDX-1))
    if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "$COUNT" ]; then
        echo -e "${RED}编号无效。${RESET}"
        return
    fi
    START=${RULES[$IDX]}
    END=${RULES[$((IDX+1))]:-99999}
    sed -i "$START,$((END-1))d" "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}规则已删除并重启 Realm。${RESET}"
}

clear_rules() {
    sed -i '/\[\[endpoints\]\]/,/^$/d' "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}已清空所有规则并重启 Realm。${RESET}"
}

list_rules() {
    echo -e "${GREEN}当前转发规则：${RESET}"
    grep -A3 '\[\[endpoints\]\]' "$CONFIG_FILE" | sed '/^--$/d'
}

view_log() {
    journalctl -u realm --no-pager --since "1 hour ago"
}

view_config() {
    cat "$CONFIG_FILE"
}

main_menu() {
    check_root
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
        read -p "请选择一个操作 [0-9]: " OPT
        case $OPT in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_rule ;;
            5) delete_rule ;;
            6) clear_rules ;;
            7) list_rules ;;
            8) view_log ;;
            9) view_config ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项。${RESET}" ;;
        esac
    done
}

main_menu
