#!/bin/bash
GREEN="\e[32m"
RESET="\e[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.toml"
REALM_SERVICE="realm"

install_realm() {
    echo -e "${GREEN}正在安装 Realm TCP+UDP转发...${RESET}"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_NAME="x86_64-unknown-linux-musl" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; return ;;
    esac

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取 Realm 最新版本失败。${RESET}"
        return
    fi

    TMP_DIR=$(mktemp -d)
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH_NAME}.tar.gz"
    echo -e "${GREEN}下载版本: ${LATEST_VERSION}${RESET}"
    echo -e "${GREEN}正在下载: ${DOWNLOAD_URL}${RESET}"

    curl -L --fail -o "$TMP_DIR/realm.tar.gz" "$DOWNLOAD_URL" || {
        echo -e "${RED}下载失败，请检查网络。${RESET}"
        return
    }

    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/realm" "$REALM_BIN"
    rm -rf "$TMP_DIR"

    mkdir -p /etc/realm
    echo -e "# 初始配置" > "$REALM_CFG"

    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
ExecStart=${REALM_BIN} -c ${REALM_CFG}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm

    echo -e "${GREEN}Realm 安装并启动完成！${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN"
    rm -f /etc/systemd/system/realm.service
    rm -rf /etc/realm
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

    tmp=$(mktemp)
    cp "$REALM_CFG" "$tmp"
    echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${LISTEN_PORT}\"\nremote = \"${TARGET_ADDR}\"\ntype = \"tcp+udp\"" >> "$tmp"
    mv "$tmp" "$REALM_CFG"

    restart_realm
    echo -e "${GREEN}转发规则已添加。${RESET}"
}

delete_all_realm_rules() {
    echo -e "# 配置重置" > "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}全部转发规则已删除。${RESET}"
}

list_realm_rules() {
    echo -e "${GREEN}当前 Realm 转发配置：${RESET}"
    cat "$REALM_CFG"
}

view_realm_log() {
    journalctl -u realm -n 50 --no-pager
}

main_menu() {
    while true; do
        echo -e "${GREEN}===== Realm TCP+UDP转发管理脚本 =====${RESET}"
        echo "1. 安装 Realm"
        echo "2. 卸载 Realm"
        echo "3. 重启 Realm"
        echo "--------------------"
        echo "4. 添加转发规则"
        echo "5. 删除全部规则"
        echo "6. 查看当前规则"
        echo "7. 查看日志"
        echo "8. 查看配置"
        echo "9. 退出"
        read -p "请选择一个操作 [1-9]: " CHOICE
        case "$CHOICE" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_realm_rule ;;
            5) delete_all_realm_rules ;;
            6) list_realm_rules ;;
            7) view_realm_log ;;
            8) cat "$REALM_CFG" ;;
            9) exit 0 ;;
            *) echo -e "${GREEN}请输入正确的选项！${RESET}" ;;
        esac
    done
}

main_menu
