#!/bin/bash

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
PLAIN="\e[0m"

CONFIG_FILE="/etc/realm/config.toml"
SERVICE_NAME="realm"
REALM_BIN="/usr/local/bin/realm"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以 root 权限运行此脚本。${PLAIN}"
        exit 1
    fi
}

install_realm() {
    echo -e "${GREEN}正在安装 Realm TCP+UDP转发脚本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep tag_name | cut -d '"' -f4)
    ARCH="x86_64-unknown-linux-musl"
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH}.tar.gz"
    
    mkdir -p /tmp/realm && cd /tmp/realm
    curl -L -o realm.tar.gz "$DOWNLOAD_URL"
    tar -xzvf realm.tar.gz
    mv realm "$REALM_BIN"
    chmod +x "$REALM_BIN"

    cat > /etc/systemd/system/realm.service <<EOF
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

    mkdir -p /etc/realm
    touch "$CONFIG_FILE"

    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm

    echo -e "${GREEN}Realm 安装完成。${PLAIN}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_BIN" /etc/systemd/system/realm.service "$CONFIG_FILE"
    systemctl daemon-reload
    echo -e "${GREEN}Realm 卸载完成。${PLAIN}"
}

restart_realm() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${PLAIN}"
}

add_forward_rule() {
    read -p "请输入本机监听端口: " LPORT
    read -p "请输入目标 IP:PORT: " RADDR
    echo -e "[[endpoints]]\nlisten = \"0.0.0.0:${LPORT}\"\nremote = \"${RADDR}\"\ntype = \"tcp+udp\"\n" >> "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}已添加并应用规则。${PLAIN}"
}

delete_single_rule() {
    RULES=($(grep -n 'listen = ' "$CONFIG_FILE" | cut -d: -f1))
    if [ ${#RULES[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有规则可删除。${PLAIN}"
        return
    fi
    echo -e "${GREEN}当前转发规则：${PLAIN}"
    INDEX=1
    for i in "${RULES[@]}"; do
        sed -n "$i,+2p" "$CONFIG_FILE"
        echo "---"
        INDEX=$((INDEX+1))
    done
    read -p "请输入要删除的规则编号: " NO
    LINE=${RULES[$((NO-1))]}
    if [ -z "$LINE" ]; then
        echo -e "${RED}编号无效。${PLAIN}"
        return
    fi
    sed -i "$LINE,+3d" "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}规则已删除。${PLAIN}"
}

delete_all_rules() {
    > "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}已删除所有规则。${PLAIN}"
}

view_rules() {
    echo -e "${GREEN}当前转发规则：${PLAIN}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "无规则。"
    else
        cat "$CONFIG_FILE"
    fi
}

view_log() {
    journalctl -u realm --no-pager --since "1 hour ago"
}

view_config() {
    echo -e "${GREEN}当前配置文件内容：${PLAIN}"
    cat "$CONFIG_FILE"
}

menu() {
    while true; do
        echo -e "${GREEN}===== Realm TCP+UDP 转发脚本 =====${PLAIN}"
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
        read -rp "请选择一个操作 [0-9]: " CHOICE
        case "$CHOICE" in
            1) install_realm;;
            2) uninstall_realm;;
            3) restart_realm;;
            4) add_forward_rule;;
            5) delete_single_rule;;
            6) delete_all_rules;;
            7) view_rules;;
            8) view_log;;
            9) view_config;;
            0) exit 0;;
            *) echo -e "${RED}无效选项，请重新输入。${PLAIN}";;
        esac
    done
}

check_root
menu
