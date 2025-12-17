#!/bin/bash
set -e

CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
TMP_DIR="/tmp/realm-install"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# ---------------------------
# Basic helpers
# ---------------------------
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

is_installed() {
    [ -x "$REALM_BIN" ] && [ -f "$SERVICE_FILE" ]
}

require_installed() {
    if ! is_installed; then
        echo -e "${RED}Realm 未安装，请先选择 1 安装。${RESET}"
        return 1
    fi
    return 0
}

# ---------------------------
# Arch & download
# ---------------------------
get_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv7" ;;
        *) echo "unsupported" ;;
    esac
}

get_libc() {
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
        x86_64) echo "realm-x86_64-unknown-linux-$libc.tar.gz" ;;
        aarch64) echo "realm-aarch64-unknown-linux-$libc.tar.gz" ;;
        armv7)
            if [ "$libc" = "musl" ]; then
                echo "realm-armv7-unknown-linux-musleabihf.tar.gz"
            else
                echo "realm-armv7-unknown-linux-gnueabihf.tar.gz"
            fi
            ;;
        *) echo "" ;;
    esac
}

get_latest_realm_url() {
    local file
    file="$(get_realm_filename)"
    [ -z "$file" ] && return 1

    curl -s https://api.github.com/repos/zhboner/realm/releases/latest \
      | grep browser_download_url \
      | grep "$file" \
      | cut -d '"' -f 4
}

ensure_config_file() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
# 默认配置
# 每条规则一个 [[endpoints]] 块
# 本脚本支持自定义字段 name 用于区分规则（Realm 会忽略未知字段）
EOF
    fi
}

# ---------------------------
# Service helpers
# ---------------------------
restart_realm_silent() {
    systemctl restart realm >/dev/null 2>&1 || systemctl restart realm
}

restart_realm_verbose() {
    systemctl restart realm
    echo -e "${GREEN}Realm 已重启。${RESET}"
}

get_realm_version_short() {
    # 只提取纯版本号，比如 "2.9.2" / "2.9.2-2"
    # 若提取失败，则返回 "未知"
    local raw ver
    raw="$($REALM_BIN --version 2>/dev/null || true)"
    ver="$(echo "$raw" | sed -n 's/.*Realm[[:space:]]\([0-9][0-9.]\+\(-[0-9]\+\)\?\).*/\1/p')"
    if [ -z "$ver" ]; then
        echo "未知"
    else
        echo "$ver"
    fi
}

get_status_line() {
    if ! is_installed; then
        echo -e "状态：${YELLOW}未安装${RESET}"
        return
    fi

    local status ver
    status="$(systemctl is-active realm 2>/dev/null || true)"
    ver="$(get_realm_version_short)"

    case "$status" in
        active) echo -e "状态：${GREEN}运行中${RESET}  |  版本：${GREEN}${ver}${RESET}" ;;
        inactive|failed) echo -e "状态：${RED}${status}${RESET}  |  版本：${GREEN}${ver}${RESET}" ;;
        *) echo -e "状态：${YELLOW}${status:-未知}${RESET}  |  版本：${GREEN}${ver}${RESET}" ;;
    esac
}

# ---------------------------
# Install / uninstall
# ---------------------------
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

    ensure_config_file
    systemctl daemon-reexec
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm

    echo -e "${GREEN}Realm 安装完成。${RESET}"
    echo -e "${GREEN}Realm 版本：$(get_realm_version_short)${RESET}"
}

uninstall_realm() {
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
    rm -f "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_FILE"
    systemctl daemon-reexec
    echo -e "${GREEN}Realm 已卸载。${RESET}"
}

# ---------------------------
# Rules indexing (valid blocks only)
# ---------------------------
RULE_STARTS=()
RULE_ENDS=()
RULE_NAMES=()
RULE_LISTENS=()
RULE_REMOTES=()
RULE_TYPES=()

get_endpoint_line_numbers() {
    [ -f "$CONFIG_FILE" ] || return 0
    grep -n '\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d: -f1
}

build_rules_index() {
    RULE_STARTS=()
    RULE_ENDS=()
    RULE_NAMES=()
    RULE_LISTENS=()
    RULE_REMOTES=()
    RULE_TYPES=()

    ensure_config_file

    mapfile -t LINES < <(get_endpoint_line_numbers)
    local n=${#LINES[@]}
    [ "$n" -eq 0 ] && return 0

    for ((i=0; i<n; i++)); do
        local START END BLOCK NAME LISTEN REMOTE TYPE
        START=${LINES[$i]}
        END=${LINES[$((i+1))]:-99999}
        BLOCK=$(sed -n "$START,$((END-1))p" "$CONFIG_FILE")

        LISTEN=$(echo "$BLOCK" | grep -m1 '^listen' | cut -d'"' -f2)
        REMOTE=$(echo "$BLOCK" | grep -m1 '^remote' | cut -d'"' -f2)
        TYPE=$(echo "$BLOCK"   | grep -m1 '^type'   | cut -d'"' -f2)
        NAME=$(echo "$BLOCK"   | grep -m1 '^name'   | cut -d'"' -f2)

        # 只收录完整规则，避免 ? -> ?
        if [ -z "$LISTEN" ] || [ -z "$REMOTE" ] || [ -z "$TYPE" ]; then
            continue
        fi

        RULE_STARTS+=("$START")
        RULE_ENDS+=("$END")
        RULE_NAMES+=("${NAME:-未命名}")
        RULE_LISTENS+=("$LISTEN")
        RULE_REMOTES+=("$REMOTE")
        RULE_TYPES+=("$TYPE")
    done
}

print_rules_pretty() {
    build_rules_index
    local COUNT=${#RULE_STARTS[@]}

    if [ "$COUNT" -eq 0 ]; then
        echo -e "${YELLOW}暂无转发规则。${RESET}"
        return 1
    fi

    echo -e "${GREEN}当前转发规则：${RESET}"
    for ((i=0; i<COUNT; i++)); do
        echo -e "$((i+1)). [${RULE_NAMES[$i]}] ${RULE_LISTENS[$i]} -> ${RULE_REMOTES[$i]} (${RULE_TYPES[$i]})"
    done
    return 0
}

# ---------------------------
# Rule operations
# ---------------------------
add_rule() {
    ensure_config_file

    read -p "请输入规则名称: " NAME
    read -p "请输入监听端口: " LISTEN
    read -p "请输入远程目标 IP:PORT: " REMOTE

    if [ -z "$NAME" ]; then
        echo -e "${RED}规则名称不能为空。${RESET}"
        return
    fi
    if ! [[ "$LISTEN" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}监听端口必须是数字。${RESET}"
        return
    fi

    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
name   = "$NAME"
listen = "0.0.0.0:$LISTEN"
remote = "$REMOTE"
type   = "tcp+udp"
EOF

    restart_realm_silent
    echo -e "${GREEN}已添加规则 [$NAME] 并已应用。${RESET}"
}

delete_rule() {
    if ! print_rules_pretty; then
        return
    fi

    local COUNT=${#RULE_STARTS[@]}
    read -p "请输入要删除的规则编号: " IDX
    IDX=$((IDX-1))

    if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "$COUNT" ]; then
        echo -e "${RED}编号无效。${RESET}"
        return
    fi

    local START END
    START=${RULE_STARTS[$IDX]}
    END=${RULE_ENDS[$IDX]}

    sed -i "$START,$((END-1))d" "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}规则已删除并已应用。${RESET}"
}

clear_rules() {
    ensure_config_file
    sed -i '/\[\[endpoints\]\]/,/^$/d' "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}已清空所有规则并已应用。${RESET}"
}

list_rules() {
    print_rules_pretty || true
}

escape_toml() {
    # 防止输入里包含 " 或 \ 破坏 toml
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

edit_rule() {
    if ! print_rules_pretty; then
        return
    fi

    local COUNT=${#RULE_STARTS[@]}
    read -p "请输入要修改的规则编号: " IDX
    IDX=$((IDX-1))
    if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "$COUNT" ]; then
        echo -e "${RED}编号无效。${RESET}"
        return
    fi

    local START END
    START=${RULE_STARTS[$IDX]}
    END=${RULE_ENDS[$IDX]}

    echo -e "${GREEN}选中规则：${RESET}$((IDX+1)). [${RULE_NAMES[$IDX]}] ${RULE_LISTENS[$IDX]} -> ${RULE_REMOTES[$IDX]} (${RULE_TYPES[$IDX]})"
    echo "要修改哪个字段？"
    echo "1. 名称 name"
    echo "2. 监听 listen（端口）"
    echo "3. 远程 remote（IP:PORT 或 域名:PORT）"
    echo "0. 返回"
    read -p "请选择 [0-3]: " OPT

    case "$OPT" in
        1)
            read -p "请输入新名称: " NEW
            [ -z "$NEW" ] && { echo -e "${RED}名称不能为空。${RESET}"; return; }
            NEW_ESC="$(escape_toml "$NEW")"

            if sed -n "${START},$((END-1))p" "$CONFIG_FILE" | grep -q '^name'; then
                sed -i "${START},$((END-1))s|^name[[:space:]]*=.*|name   = \"${NEW_ESC}\"|g" "$CONFIG_FILE"
            else
                sed -i "${START}a name   = \"${NEW_ESC}\"" "$CONFIG_FILE"
            fi
            ;;
        2)
            read -p "请输入新监听端口: " NEWP
            ! [[ "$NEWP" =~ ^[0-9]+$ ]] && { echo -e "${RED}端口必须是数字。${RESET}"; return; }
            sed -i "${START},$((END-1))s|^listen[[:space:]]*=.*|listen = \"0.0.0.0:${NEWP}\"|g" "$CONFIG_FILE"
            ;;
        3)
            read -p "请输入新远程目标（IP:PORT 或 域名:PORT）: " NEWR
            [ -z "$NEWR" ] && { echo -e "${RED}remote 不能为空。${RESET}"; return; }
            NEWR_ESC="$(escape_toml "$NEWR")"
            sed -i "${START},$((END-1))s|^remote[[:space:]]*=.*|remote = \"${NEWR_ESC}\"|g" "$CONFIG_FILE"
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${RESET}"; return ;;
    esac

    restart_realm_silent
    echo -e "${GREEN}规则已修改并已应用。${RESET}"
}

# ---------------------------
# View
# ---------------------------
view_log() {
    journalctl -u realm --no-pager --since "1 hour ago"
}

view_config() {
    ensure_config_file
    cat "$CONFIG_FILE"
}

# ---------------------------
# Menu
# ---------------------------
main_menu() {
    check_root
    while true; do
        echo -e "${GREEN}===== Realm TCP+UDP 转发脚本 =====${RESET}"
        get_status_line
        echo "----------------------------------"
        echo "1.  安装 Realm"
        echo "2.  卸载 Realm"
        echo "3.  重启 Realm"
        echo "--------------------"
        echo "4.  添加转发规则"
        echo "5.  删除单条规则"
        echo "6.  删除全部规则"
        echo "7.  查看当前规则"
        echo "8.  修改某条规则"
        echo "9.  查看日志"
        echo "10. 查看配置"
        echo "0.  退出"
        read -p "请选择一个操作 [0-10]: " OPT

        case $OPT in
            1) install_realm ;;
            2) uninstall_realm ;;
            0) exit 0 ;;

            3) require_installed && restart_realm_verbose ;;
            4) require_installed && add_rule ;;
            5) require_installed && delete_rule ;;
            6) require_installed && clear_rules ;;
            7) require_installed && list_rules ;;
            8) require_installed && edit_rule ;;
            9) require_installed && view_log ;;
            10) require_installed && view_config ;;

            *) echo -e "${RED}无效选项。${RESET}" ;;
        esac
    done
}

main_menu
