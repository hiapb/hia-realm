#!/bin/bash
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG="/etc/realm/config.toml"
REALM_SERVICE="realm"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本。${RESET}"
    exit 1
fi

install_realm() {
    echo -e "${GREEN}正在安装 Realm TCP+UDP万能转发（zhboner/realm）...${RESET}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_NAME="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; return ;;
    esac

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取 Realm 最新版本失败。${RESET}"
        return
    fi

    TMP_DIR=$(mktemp -d)
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH_NAME}.tar.gz"
    echo -e "${GREEN}正在下载: ${DOWNLOAD_URL}${RESET}"
    curl -L --fail -o "$TMP_DIR/realm.tar.gz" "$DOWNLOAD_URL" || {
        echo -e "${RED}下载失败，请检查网络。${RESET}"
        return
    }

    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/realm" /usr/local/bin/realm
    rm -rf "$TMP_DIR"

    mkdir -p /etc/realm
    cat > "$REALM_CFG" <<EOF
[general]
log-level = "info"
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

    echo -e "${GREEN}Realm 安装并启动完成！${RESET}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /usr/local/bin/realm
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

    cat >> "$REALM_CFG" <<EOF

[[endpoints]]
listen = "0.0.0.0:${LISTEN_PORT}"
remote = "${TARGET_ADDR}"
type = "tcp"
EOF

    systemctl restart realm
    echo -e "${GREEN}转发规则已添加并应用！${RESET}"
}

list_realm_rules() {
    echo -e "${GREEN}当前 Realm 转发规则：${RESET}"
    grep -A 3 '^\[\[endpoints\]\]' "$REALM_CFG"
}

delete_realm_rule() {
    echo -e "${GREEN}当前转发规则：${RESET}"
    RULES=()
    INDEX=0
    BLOCK=""
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ "$line" =~ \[\[endpoints\]\] ]]; then
            [[ -n "$BLOCK" ]] && RULES+=("$BLOCK")
            BLOCK="$line"$'\n'
        else
            BLOCK+="$line"$'\n'
        fi
    done < "$REALM_CFG"
    [[ -n "$BLOCK" ]] && RULES+=("$BLOCK")

    if [[ ${#RULES[@]} -eq 0 ]]; then
        echo -e "${RED}无规则可删除。${RESET}"
        return
    fi

    for i in "${!RULES[@]}"; do
        echo -e "${YELLOW}$((i+1)):${RESET}"
        echo "${RULES[$i]}"
        echo "----------------------"
    done

    read -p "请输入要删除的规则编号: " DEL_NO
    if ! [[ "$DEL_NO" =~ ^[0-9]+$ ]] || (( DEL_NO < 1 || DEL_NO > ${#RULES[@]} )); then
        echo -e "${RED}编号无效。${RESET}"
        return
    fi

    echo "[general]
log-level = \"info\"" > "$REALM_CFG"
    for i in "${!RULES[@]}"; do
        if (( i+1 != DEL_NO )); then
            echo "${RULES[$i]}" >> "$REALM_CFG"
        fi
    done

    systemctl restart realm
    echo -e "${GREEN}已删除规则 #${DEL_NO} 并重启 Realm。${RESET}"
}

delete_all_realm_rules() {
    echo "[general]
log-level = \"info\"" > "$REALM_CFG"
    systemctl restart realm
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
            *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
        esac
    done
}

main_menu
