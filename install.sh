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
    echo -e "${GREEN}正在安装 Realm TCP+UDP万能转发（zhboner/realm）...${RESET}"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_NAME="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; read -rp "按回车返回菜单..." _; return ;;
    esac

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取 Realm 最新版本失败。${RESET}"
        read -rp "按回车返回菜单..." _
        return
    fi

    TMP_DIR=$(mktemp -d)
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH_NAME}.tar.gz"
    echo -e "${GREEN}下载版本: ${YELLOW}${LATEST_VERSION}${RESET}"
    echo -e "${GREEN}正在下载: ${DOWNLOAD_URL}${RESET}"

    curl -L --fail -o "$TMP_DIR/realm.tar.gz" "$DOWNLOAD_URL" || {
        echo -e "${RED}下载失败，请检查网络。${RESET}"
        read -rp "按回车返回菜单..." _
        return
    }

    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/realm" /usr/local/bin/realm
    rm -rf "$TMP_DIR"

    mkdir -p /etc/realm
    cat > /etc/realm/config.toml <<EOF
[general]
log-level = "info"

[[endpoints]]
listen = "0.0.0.0:12345"
remote = "1.1.1.1:443"
type = "tcp"
EOF

    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm

    echo -e "${GREEN}Realm 安装并启动完成！默认监听 0.0.0.0:12345${RESET}"
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
