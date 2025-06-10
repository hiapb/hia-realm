#!/bin/bash
GREEN="\e[32m"
RESET="\e[0m"
REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.toml"
REALM_SERVICE="/etc/systemd/system/realm.service"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_NAME="x86_64-unknown-linux-musl" ;;
    aarch64) ARCH_NAME="aarch64-unknown-linux-musl" ;;
    *) echo "不支持架构 $ARCH"; exit 1 ;;
esac

install_realm() {
    VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep tag_name | cut -d '"' -f4)
    URL="https://github.com/zhboner/realm/releases/download/${VERSION}/realm-${ARCH_NAME}.tar.gz"
    TMP_DIR=$(mktemp -d)
    curl -L "$URL" -o "$TMP_DIR/realm.tar.gz"
    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/realm" "$REALM_BIN"
    rm -rf "$TMP_DIR"
    mkdir -p /etc/realm
    echo "# Realm Config" > "$REALM_CFG"

    cat > "$REALM_SERVICE" <<EOF
[Unit]
Description=Realm Proxy
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
    systemctl start realm
    echo -e "${GREEN}Realm 安装完成。${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN" "$REALM_SERVICE"
    rm -rf /etc/realm
    systemctl daemon-reload
    echo -e "${GREEN}Realm 已卸载。${RESET}"
}

restart_realm() {
    systemctl restart realm
}

add_rule() {
    read -p "请输入本机监听端口: " LPORT
    read -p "请输入目标 IP:PORT: " RADDR

    cat >> "$REALM_CFG" <<EOF

[[endpoints]]
listen = "0.0.0.0:$LPORT"
remote = "$RADDR"
type = "tcp+udp"
EOF

    restart_realm
    echo -e "${GREEN}已添加规则: $LPORT -> $RADDR${RESET}"
}

list_rules() {
    echo -e "${GREEN}当前转发规则：${RESET}"
    grep -A 3 '\[\[endpoints\]\]' "$REALM_CFG" | nl
}

delete_rule() {
    list_rules
    read -p "请输入要删除的规则编号: " LINE_NO
    sed -i "$(( (LINE_NO - 1) * 5 + 1 )),$(( (LINE_NO - 1) * 5 + 4 ))d" "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}已删除第 $LINE_NO 条规则。${RESET}"
}

delete_all_rules() {
    sed -i '/\[\[endpoints\]\]/,$d' "$REALM_CFG"
    restart_realm
    echo -e "${GREEN}已清空所有规则。${RESET}"
}

view_log() {
    journalctl -u realm -n 50 --no-pager
}

view_config() {
    cat "$REALM_CFG"
}

menu() {
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
        read -p "请选择一个操作 [0-9]: " opt
        case "$opt" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_rule ;;
            5) delete_rule ;;
            6) delete_all_rules ;;
            7) list_rules ;;
            8) view_log ;;
            9) view_config ;;
            0) exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

menu
