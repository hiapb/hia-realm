#!/bin/bash
GREEN="\e[32m"
RESET="\e[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.toml"
REALM_SERVICE="/etc/systemd/system/realm.service"
REALM_VERSION="v2.7.0"

# 安装 realm
install_realm() {
    echo -e "${GREEN}正在安装 Realm TCP+UDP万能转发（zhboner/realm）...${RESET}"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_NAME="x86_64-unknown-linux-musl" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-musl" ;;
        *) echo -e "不支持的架构: $ARCH"; return ;;
    esac

    TMP_DIR=$(mktemp -d)
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-${ARCH_NAME}.tar.gz"

    echo -e "下载地址: ${DOWNLOAD_URL}"
    curl -L --fail -o "$TMP_DIR/realm.tar.gz" "$DOWNLOAD_URL" || {
        echo -e "下载失败。"; return
    }

    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/realm" "$REALM_BIN"
    rm -rf "$TMP_DIR"

    mkdir -p /etc/realm
    echo -e "[endpoints]" > "$REALM_CFG"  # 空配置占位，启动失败防止

    cat > "$REALM_SERVICE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
ExecStart=$REALM_BIN -c $REALM_CFG
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    systemctl restart realm

    echo -e "${GREEN}Realm 安装并启动完成。${RESET}"
}

# 卸载 realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_SERVICE" "$REALM_BIN"
    rm -rf /etc/realm
    systemctl daemon-reload
    echo -e "${GREEN}Realm 已完全卸载。${RESET}"
}

# 重启 realm
restart_realm() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${RESET}"
}

# 添加转发规则
add_realm_rule() {
    read -p "请输入本机监听端口: " LISTEN_PORT
    read -p "请输入目标 IP:PORT: " TARGET_ADDR
    read -p "请输入类型（tcp、udp、tcp+udp）: " TYPE

    # 如果 config 是空文件，添加 header
    if ! grep -q "\[\[endpoints\]\]" "$REALM_CFG"; then
        echo -e "\n[[endpoints]]" > "$REALM_CFG"
    fi

    cat >> "$REALM_CFG" <<EOF

[[endpoints]]
listen = "0.0.0.0:${LISTEN_PORT}"
remote = "${TARGET_ADDR}"
type = "${TYPE}"
EOF

    restart_realm
    echo -e "${GREEN}已添加规则并重启 Realm。${RESET}"
}

# 查看规则
list_realm_rules() {
    echo -e "${GREEN}当前配置内容：${RESET}"
    grep -A 3 "\[\[endpoints\]\]" "$REALM_CFG" | nl
}

# 删除所有规则
delete_all_realm_rules() {
    echo "" > "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}全部规则已删除并重启。${RESET}"
}

# 查看日志
view_realm_log() {
    journalctl -u realm -n 50 --no-pager
}

# 查看配置
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
            8) view_realm_config ;;
            9) exit 0 ;;
            *) echo "请输入正确的数字。" ;;
        esac
    done
}

main_menu
