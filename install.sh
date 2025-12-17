#!/bin/bash
set -e

CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}缺少依赖命令：$1，请先安装。${RESET}"
        exit 1
    }
}

get_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv7" ;; # 尽量兼容
        *) echo "unsupported" ;;
    esac
}

get_libc() {
    # musl: Alpine/部分OpenWRT; gnu: Debian/Ubuntu/CentOS...
    if ldd --version 2>&1 | grep -qi musl; then
        echo "musl"
    else
        echo "gnu"
    fi
}

get_realm_filename() {
    local arch libc
    arch="$(get_arch)"
    libc="$(get_libc)"

    case "$arch" in
        x86_64)
            echo "realm-x86_64-unknown-linux-$libc.tar.gz"
            ;;
        aarch64)
            echo "realm-aarch64-unknown-linux-$libc.tar.gz"
            ;;
        armv7)
            # 32位 ARM：官方文件名里是 armv7 + (gnu|musl) + eabihf
            if [ "$libc" = "musl" ]; then
                echo "realm-armv7-unknown-linux-musleabihf.tar.gz"
            else
                echo "realm-armv7-unknown-linux-gnueabihf.tar.gz"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

get_latest_realm_url() {
    local file
    file="$(get_realm_filename)"
    if [ -z "$file" ]; then
        return 1
    fi

    # 取 latest release 中匹配的平台包
    curl -s https://api.github.com/repos/zhboner/realm/releases/latest \
      | grep browser_download_url \
      | grep "$file" \
      | cut -d '"' -f 4
}

install_realm() {
    need_cmd curl
    need_cmd tar
    need_cmd systemctl

    echo -e "${GREEN}正在安装 Realm TCP+UDP 转发...${RESET}"

    local arch libc file url
    arch="$(get_arch)"
    libc="$(get_libc)"
    file="$(get_realm_filename)"

    if [ "$arch" = "unsupported" ] || [ -z "$file" ]; then
        echo -e "${RED}不支持的架构：$(uname -m)${RESET}"
        exit 1
    fi

    url="$(get_latest_realm_url || true)"
    if [ -z "$url" ]; then
        echo -e "${RED}获取 Realm 最新版本下载地址失败。可能是网络/限流或 release 中无对应包：$file${RESET}"
        exit 1
    fi

    echo -e "${GREEN}检测到架构：$arch  libc：$libc${RESET}"
    echo -e "${GREEN}将下载：$file${RESET}"
    echo -e "${GREEN}下载地址：$url${RESET}"

    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || exit 1
    rm -f realm.tar.gz realm

    curl -L -o realm.tar.gz "$url"
    tar -xzf realm.tar.gz

    if [ ! -f "realm" ]; then
        echo -e "${RED}解压后未找到 realm 可执行文件，请检查压缩包内容。${RESET}"
        exit 1
    fi

    mv realm "$REALM_BIN"
    chmod +x "$REALM_BIN"

    # systemd service
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

    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
# 默认配置
# 添加规则会自动追加 [[endpoints]] 块
EOF
    fi

    systemctl daemon-reexec
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm

    echo -e "${GREEN}Realm 安装完成。${RESET}"
    echo -e "${GREEN}Realm 版本信息：$($REALM_BIN --version 2>/dev/null || echo '未知')${RESET}"
}

uninstall_realm() {
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
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

    if ! [[ "$LISTEN" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}监听端口必须是数字。${RESET}"
        return
    fi

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
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在：$CONFIG_FILE${RESET}"
        return
    fi

    mapfile -t RULES < <(grep -n '\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d: -f1)
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
        L=$(echo "$BLOCK" | grep -m1 listen | cut -d'"' -f2)
        R=$(echo "$BLOCK" | grep -m1 remote | cut -d'"' -f2)
        echo -e "$((i+1)). ${L:-?} -> ${R:-?}"
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
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在：$CONFIG_FILE${RESET}"
        return
    fi
    # 删除 [[endpoints]] 到空行的块
    sed -i '/\[\[endpoints\]\]/,/^$/d' "$CONFIG_FILE"
    restart_realm
    echo -e "${GREEN}已清空所有规则并重启 Realm。${RESET}"
}

list_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在：$CONFIG_FILE${RESET}"
        return
    fi
    echo -e "${GREEN}当前转发规则：${RESET}"
    grep -A3 '\[\[endpoints\]\]' "$CONFIG_FILE" | sed '/^--$/d' || true
}

view_log() {
    journalctl -u realm --no-pager --since "1 hour ago"
}

view_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在：$CONFIG_FILE${RESET}"
        return
    fi
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
