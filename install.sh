#!/bin/bash
REALM_BIN="/usr/local/bin/realm"
CONFIG_FILE="/etc/realm/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
ARCH="x86_64-unknown-linux-musl"

install_realm() {
    echo "正在安装 Realm TCP+UDP万能转发脚本..."
    mkdir -p /tmp/realm
    cd /tmp/realm || exit 1
    LATEST_VERSION=$(curl -s https://github.com/zhboner/realm/releases/latest | grep "/tag/" | cut -d'"' -f2 | awk -F/ '{print $NF}')
    if [ -z "$LATEST_VERSION" ]; then
        echo "获取最新版本失败。"
        return
    fi
    echo "正在下载: https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH}.tar.gz"
    curl -L -o realm.tar.gz "https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH}.tar.gz"
    tar -xzf realm.tar.gz
    mv realm "$REALM_BIN"
    chmod +x "$REALM_BIN"

    mkdir -p /etc/realm
    cat > "$CONFIG_FILE" <<EOF
endpoints = []
EOF

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

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable realm
    systemctl restart realm

    echo "Realm 安装完成。"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN" "$CONFIG_FILE" "$SERVICE_FILE"
    systemctl daemon-reload
    echo "Realm 已卸载。"
}

restart_realm() {
    systemctl restart realm
    echo "Realm 已重启。"
}

add_rule() {
    read -rp "监听端口: " port
    read -rp "目标地址 (IP:PORT): " target
    read -rp "协议 (tcp/udp): " proto
    read -rp "名称（可选，默认 endpoint-$port）: " name
    [[ -z "$name" ]] && name="endpoint-$port"

    tmp=$(mktemp)
    echo 'endpoints = [' > "$tmp"
    grep '^{' "$CONFIG_FILE" >> "$tmp" 2>/dev/null
    echo "{ name = \"$name\", listen = \":$port\", remote = \"$target\", type = \"$proto\" }" >> "$tmp"
    echo ']' >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm
    echo "已添加规则: $name"
}

delete_rule() {
    echo "当前规则："
    grep 'name = ' "$CONFIG_FILE" | nl
    read -rp "输入要删除的编号: " idx
    tmp=$(mktemp)
    count=0
    echo 'endpoints = [' > "$tmp"
    while IFS= read -r line; do
        if [[ "$line" =~ name\ = ]]; then
            count=$((count+1))
            if [[ "$count" -eq "$idx" ]]; then
                read -r _  # 跳过该规则
                continue
            fi
        fi
        echo "$line" >> "$tmp"
    done < <(grep -v '^endpoints' "$CONFIG_FILE")
    echo ']' >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm
    echo "已删除规则 #$idx"
}

clear_rules() {
    echo 'endpoints = []' > "$CONFIG_FILE"
    restart_realm
    echo "所有规则已清空。"
}

show_rules() {
    echo "当前规则："
    grep 'name =\|listen =\|remote =' "$CONFIG_FILE"
}

show_logs() {
    journalctl -u realm --no-pager -n 50
}

show_config() {
    cat "$CONFIG_FILE"
}

main_menu() {
    while true; do
        echo "===== Realm TCP+UDP 转发脚本 ====="
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
        read -rp "请选择一个操作 [0-9]: " choice
        case "$choice" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_rule ;;
            5) delete_rule ;;
            6) clear_rules ;;
            7) show_rules ;;
            8) show_logs ;;
            9) show_config ;;
            0) exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

main_menu
