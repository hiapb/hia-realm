#!/bin/bash
set -e

CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
TMP_DIR="/tmp/realm-install"

EXPORT_DIR="/etc/realm"
DEFAULT_EXPORT_FILE="/etc/realm/realm-rules.backup.toml"

CRON_FILE="/etc/cron.d/realm-rules-export"
EXPORT_HELPER="/usr/local/bin/realm-export-rules.sh"

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
# 暂停规则：脚本会把整段 endpoints 用 # 注释
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
# Install / update / uninstall
# ---------------------------
install_realm_inner() {
  need_cmd curl
  need_cmd tar
  need_cmd systemctl

  echo -e "${GREEN}正在安装/更新 Realm（自动最新）...${RESET}"

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

  echo -e "${GREEN}完成。当前版本：$(get_realm_version_short)${RESET}"
}

install_realm() {
  if is_installed; then
    echo -e "${YELLOW}Realm 已安装（版本：$(get_realm_version_short)）。是否更新到最新版本？[y/N]${RESET}"
    read -r ANS
    case "$ANS" in
      y|Y) install_realm_inner ;;
      *) echo -e "${YELLOW}已取消更新。${RESET}" ;;
    esac
  else
    install_realm_inner
  fi
}

uninstall_realm() {
  systemctl stop realm >/dev/null 2>&1 || true
  systemctl disable realm >/dev/null 2>&1 || true
  rm -f "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_FILE"
  systemctl daemon-reexec
  echo -e "${GREEN}Realm 已卸载。${RESET}"
}

# ---------------------------
# Rules indexing (including paused blocks)
# ---------------------------
RULE_STARTS=()
RULE_ENDS=()
RULE_ENABLED=()
RULE_NAMES=()
RULE_LISTENS=()
RULE_REMOTES=()
RULE_TYPES=()

get_endpoint_line_numbers_all() {
  [ -f "$CONFIG_FILE" ] || return 0
  grep -n -E '^[[:space:]]*(#\s*)?\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d: -f1
}

build_rules_index() {
  RULE_STARTS=()
  RULE_ENDS=()
  RULE_ENABLED=()
  RULE_NAMES=()
  RULE_LISTENS=()
  RULE_REMOTES=()
  RULE_TYPES=()

  ensure_config_file

  mapfile -t LINES < <(get_endpoint_line_numbers_all)
  local n=${#LINES[@]}
  [ "$n" -eq 0 ] && return 0

  for ((i=0; i<n; i++)); do
    local START END BLOCK FIRST ENABLED NAME LISTEN REMOTE TYPE
    START=${LINES[$i]}
    END=${LINES[$((i+1))]:-999999}

    BLOCK="$(sed -n "$START,$((END-1))p" "$CONFIG_FILE")"
    FIRST="$(echo "$BLOCK" | head -n1)"

    if echo "$FIRST" | grep -q -E '^[[:space:]]*#'; then
      ENABLED=0
    else
      ENABLED=1
    fi

    LISTEN="$(echo "$BLOCK" | grep -m1 -E '^[[:space:]]*(#\s*)?listen' | cut -d'"' -f2)"
    REMOTE="$(echo "$BLOCK" | grep -m1 -E '^[[:space:]]*(#\s*)?remote' | cut -d'"' -f2)"
    TYPE="$(echo "$BLOCK"   | grep -m1 -E '^[[:space:]]*(#\s*)?type'   | cut -d'"' -f2)"
    NAME="$(echo "$BLOCK"   | grep -m1 -E '^[[:space:]]*(#\s*)?name'   | cut -d'"' -f2)"

    # 不完整就跳过
    if [ -z "$LISTEN" ] || [ -z "$REMOTE" ] || [ -z "$TYPE" ]; then
      continue
    fi

    RULE_STARTS+=("$START")
    RULE_ENDS+=("$END")
    RULE_ENABLED+=("$ENABLED")
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
    local st
    if [ "${RULE_ENABLED[$i]}" -eq 1 ]; then
      st="启用"
    else
      st="暂停"
    fi
    echo -e "$((i+1)). [${st}] [${RULE_NAMES[$i]}] ${RULE_LISTENS[$i]} -> ${RULE_REMOTES[$i]} (${RULE_TYPES[$i]})"
  done
  return 0
}

# ---------------------------
# Safe file edit (NO sed -i)
# ---------------------------
apply_block_key_update() {
  # args: start end enabled key new_value(without quotes) align_name(optional)
  local start="$1" end="$2" enabled="$3" key="$4" value="$5" align="$6"
  local tmp="${CONFIG_FILE}.tmp.$$"
  local prefix=""

  # 如果整段是暂停块，保持每行 # 前缀
  if [ "$enabled" -eq 0 ]; then
    prefix="# "
  fi

  # name 对齐一下更好看
  local kfmt="$key"
  if [ "$key" = "name" ] && [ -n "$align" ]; then
    kfmt="name   "
  elif [ "$key" = "type" ] && [ -n "$align" ]; then
    kfmt="type   "
  fi

  awk -v S="$start" -v E="$end" -v K="$key" -v V="$value" -v PFX="$prefix" -v KF="$kfmt" '
    function is_key_line(line, key) {
      # match:  [spaces] (# optional) key [spaces]*=
      return line ~ "^[[:space:]]*(#[[:space:]]*)?" key "[[:space:]]*="
    }
    BEGIN{found=0}
    {
      if (NR>=S && NR<=E-1) {
        if (!found && is_key_line($0, K)) {
          print PFX KF " = \"" V "\""
          found=1
          next
        }
      }
      print $0
      # 如果在块内，遇到空行结束块且还没 found，就在空行前补一行
      if (NR>=S && NR<=E-1 && $0 ~ "^[[:space:]]*$" && !found) {
        print PFX KF " = \"" V "\""
        found=1
      }
    }
    END{
      # 如果块到末尾都没空行，也没找到 key，就不处理（通常不会发生）
    }
  ' "$CONFIG_FILE" > "$tmp"

  mv "$tmp" "$CONFIG_FILE"
}

# ---------------------------
# Rule operations
# ---------------------------
escape_toml() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

has_ipv6() {
  need_cmd ip
  if command -v sysctl >/dev/null 2>&1; then
    local v
    v="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    [ "$v" = "1" ] && return 1
  fi
  ip -6 addr show 2>/dev/null | grep -qv 'inet6 ::1' && ip -6 addr show 2>/dev/null | grep -q 'inet6'
}

choose_listen_mode_v4v6() {
  while true; do
    echo "请选择监听协议："
    echo "1. IPv4（0.0.0.0:PORT）【默认】"
    echo "2. IPv6（[::]:PORT）"
    read -p "请选择 [1-2]（默认 1）: " MODE
    MODE="${MODE:-1}"
    case "$MODE" in
      1) echo "v4"; return 0 ;;
      2)
        if has_ipv6; then
          echo "v6"; return 0
        else
          echo -e "${RED}检测到本机没有可用 IPv6（可能未开通或被禁用）。请改选 IPv4。${RESET}"
        fi
        ;;
      *) echo -e "${RED}无效选项，请重新选择。${RESET}" ;;
    esac
  done
}

listen_mode_from_value() {
  local v="$1"
  if [[ "$v" == \[*\]* ]]; then
    echo "v6"
  else
    echo "v4"
  fi
}

replace_listen_port_keep_proto() {
  local listen="$1" newp="$2"
  echo "$listen" | sed -E "s/:[0-9]+$/:$newp/"
}

prompt_remote_by_mode() {
  local MODE="$1"
  local REMOTE=""
  while true; do
    if [ "$MODE" = "v4" ]; then
      echo -e "${GREEN}请输入远程目标（v4 格式）：IPv4/域名:PORT  例如：1.2.3.4:443 或 example.com:443${RESET}"
      read -r -p "remote: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}remote 不能为空。${RESET}"; continue; }
      if [[ "$REMOTE" == \[*\]:* ]]; then
        echo -e "${RED}你选择的是 IPv4，但输入看起来是 IPv6（带 []）。请按 IPv4/域名:PORT 重输。${RESET}"
        continue
      fi
      if [[ "$REMOTE" == *:* && "$REMOTE" != *"."* ]]; then
        echo -e "${RED}你选择的是 IPv4，但输入看起来是裸 IPv6。请按 IPv4/域名:PORT 重输。${RESET}"
        continue
      fi
      echo "$REMOTE"; return 0
    else
      echo -e "${GREEN}请输入远程目标（v6 格式）：[IPv6]:PORT  例如：[2001:db8::1]:443${RESET}"
      read -r -p "remote: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}remote 不能为空。${RESET}"; continue; }
      if [[ "$REMOTE" =~ ^\[[0-9a-fA-F:]+\]:[0-9]+$ ]]; then
        echo "$REMOTE"; return 0
      else
        echo -e "${RED}IPv6 格式不正确，必须是 [IPv6]:PORT（带方括号）。请重输。${RESET}"
      fi
    fi
  done
}

add_rule() {
  ensure_config_file

  local MODE
  MODE="$(choose_listen_mode_v4v6)"

  read -p "请输入规则名称: " NAME
  [ -z "$NAME" ] && { echo -e "${RED}规则名称不能为空。${RESET}"; return; }

  read -p "请输入监听端口: " LISTEN
  ! [[ "$LISTEN" =~ ^[0-9]+$ ]] && { echo -e "${RED}监听端口必须是数字。${RESET}"; return; }

  local REMOTE
  REMOTE="$(prompt_remote_by_mode "$MODE")"

  local NAME_ESC REMOTE_ESC
  NAME_ESC="$(escape_toml "$NAME")"
  REMOTE_ESC="$(escape_toml "$REMOTE")"

  local LISTEN_ADDR
  if [ "$MODE" = "v6" ]; then
    LISTEN_ADDR="[::]:$LISTEN"
  else
    LISTEN_ADDR="0.0.0.0:$LISTEN"
  fi

  cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
name   = "$NAME_ESC"
listen = "$LISTEN_ADDR"
remote = "$REMOTE_ESC"
type   = "tcp+udp"
EOF

  restart_realm_silent
  echo -e "${GREEN}已添加规则 [$NAME]（$MODE）并已应用。${RESET}"
}

delete_rule() {
  if ! print_rules_pretty; then return; fi
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

  # 用 awk 删除范围（避免 sed -i）
  local tmp="${CONFIG_FILE}.tmp.$$"
  awk -v S="$START" -v E="$END" 'NR<S || NR>=E {print}' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"

  restart_realm_silent
  echo -e "${GREEN}规则已删除并已应用。${RESET}"
}

clear_rules() {
  ensure_config_file
  # 粗暴清理：把所有 endpoints 块删掉（含注释块）
  local tmp="${CONFIG_FILE}.tmp.$$"
  awk '
    BEGIN{drop=0}
    /^[[:space:]]*(# *|)?\[\[endpoints\]\]/{drop=1; next}
    drop==1 && /^[[:space:]]*$/{drop=0; next}
    drop==0{print}
  ' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"

  restart_realm_silent
  echo -e "${GREEN}已清空所有规则并已应用。${RESET}"
}

list_rules() { print_rules_pretty || true; }

edit_rule() {
  if ! print_rules_pretty; then return; fi

  local COUNT=${#RULE_STARTS[@]}
  read -p "请输入要修改的规则编号: " IDX
  IDX=$((IDX-1))
  if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "$COUNT" ]; then
    echo -e "${RED}编号无效。${RESET}"
    return
  fi

  local START END ENABLED CUR_LISTEN CUR_MODE
  START=${RULE_STARTS[$IDX]}
  END=${RULE_ENDS[$IDX]}
  ENABLED=${RULE_ENABLED[$IDX]}
  CUR_LISTEN="${RULE_LISTENS[$IDX]}"
  CUR_MODE="$(listen_mode_from_value "$CUR_LISTEN")"

  echo -e "${GREEN}选中规则：${RESET}$((IDX+1)). [${RULE_NAMES[$IDX]}] ${RULE_LISTENS[$IDX]} -> ${RULE_REMOTES[$IDX]} (${RULE_TYPES[$IDX]})"
  echo "要修改哪个字段？"
  echo "1. 名称 name"
  echo "2. 监听 listen（仅修改端口，不修改协议：当前 $CUR_MODE）"
  echo "3. 远程 remote（按当前协议 $CUR_MODE 重新输入校验）"
  echo "0. 返回"
  read -p "请选择 [0-3]: " OPT

  case "$OPT" in
    1)
      read -p "请输入新名称: " NEW
      [ -z "$NEW" ] && { echo -e "${RED}名称不能为空。${RESET}"; return; }
      NEW_ESC="$(escape_toml "$NEW")"
      apply_block_key_update "$START" "$END" "$ENABLED" "name" "$NEW_ESC" "align"
      ;;
    2)
      read -p "请输入新监听端口: " NEWP
      ! [[ "$NEWP" =~ ^[0-9]+$ ]] && { echo -e "${RED}端口必须是数字。${RESET}"; return; }
      local NEW_LISTEN
      NEW_LISTEN="$(replace_listen_port_keep_proto "$CUR_LISTEN" "$NEWP")"
      apply_block_key_update "$START" "$END" "$ENABLED" "listen" "$NEW_LISTEN" ""
      ;;
    3)
      local NEWR
      NEWR="$(prompt_remote_by_mode "$CUR_MODE")"
      NEWR_ESC="$(escape_toml "$NEWR")"
      apply_block_key_update "$START" "$END" "$ENABLED" "remote" "$NEWR_ESC" ""
      ;;
    0) return ;;
    *) echo -e "${RED}无效选项。${RESET}"; return ;;
  esac

  restart_realm_silent
  echo -e "${GREEN}规则已修改并已应用。${RESET}"
}

toggle_rule() {
  if ! print_rules_pretty; then return; fi
  local COUNT=${#RULE_STARTS[@]}
  read -p "请输入要启动/暂停的规则编号: " IDX
  IDX=$((IDX-1))
  if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "$COUNT" ]; then
    echo -e "${RED}编号无效。${RESET}"
    return
  fi

  local START END
  START=${RULE_STARTS[$IDX]}
  END=${RULE_ENDS[$IDX]}

  local tmp="${CONFIG_FILE}.tmp.$$"
  if [ "${RULE_ENABLED[$IDX]}" -eq 1 ]; then
    # 启用 -> 暂停：每行加 # 
    awk -v S="$START" -v E="$END" '
      NR>=S && NR<=E-1 { sub(/^[[:space:]]*#?[[:space:]]*/, "# "); print; next }
      {print}
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}已暂停规则：${RULE_NAMES[$IDX]}${RESET}"
  else
    # 暂停 -> 启用：去掉行首 # 
    awk -v S="$START" -v E="$END" '
      NR>=S && NR<=E-1 { sub(/^[[:space:]]*#[[:space:]]*/, ""); print; next }
      {print}
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}已启动规则：${RULE_NAMES[$IDX]}${RESET}"
  fi
}

# ---------------------------
# Export / Import
# ---------------------------
export_rules_core() {
  local OUT="$1"
  ensure_config_file
  mkdir -p "$EXPORT_DIR"
  need_cmd awk
  awk '
    BEGIN{inblk=0}
    /^[[:space:]]*(# *|)?\[\[endpoints\]\]/{inblk=1}
    { if(inblk) print }
    /^[[:space:]]*$/{ if(inblk){ print ""; inblk=0 } }
  ' "$CONFIG_FILE" > "$OUT"
}

export_rules() {
  ensure_config_file
  mkdir -p "$EXPORT_DIR"

  read -p "导出文件路径 [${DEFAULT_EXPORT_FILE}]: " OUT
  OUT="${OUT:-$DEFAULT_EXPORT_FILE}"

  export_rules_core "$OUT"

  if [ ! -s "$OUT" ]; then
    echo -e "${YELLOW}未导出任何规则（可能当前没有 endpoints 块）。${RESET}"
  else
    echo -e "${GREEN}导出完成！${RESET}"
  fi
  echo -e "${GREEN}导出文件路径：$OUT${RESET}"
}

import_rules() {
  ensure_config_file
  read -p "请输入要导入的文件路径: " IN
  if [ -z "$IN" ] || [ ! -f "$IN" ]; then
    echo -e "${RED}导入文件不存在。${RESET}"
    return
  fi
  if ! grep -q -E '^[[:space:]]*(#\s*)?\[\[endpoints\]\]' "$IN"; then
    echo -e "${RED}导入文件不包含 [[endpoints]] 块，疑似不是规则备份文件。${RESET}"
    return
  fi

  echo -e "${GREEN}导入文件规则数：$(grep -c -E '^[[:space:]]*(#\s*)?\[\[endpoints\]\]' "$IN")${RESET}"
  echo "导入模式："
  echo "1. 覆盖：清空现有规则后导入"
  echo "2. 追加：在现有规则后追加导入"
  read -p "请选择 [1-2]: " MODE

  case "$MODE" in
    1)
      clear_rules
      cat >> "$CONFIG_FILE" <<EOF

# ---- Imported rules from: $IN ----
EOF
      cat "$IN" >> "$CONFIG_FILE"
      ;;
    2)
      cat >> "$CONFIG_FILE" <<EOF

# ---- Imported rules from: $IN ----
EOF
      cat "$IN" >> "$CONFIG_FILE"
      ;;
    *)
      echo -e "${RED}无效选项。${RESET}"
      return
      ;;
  esac

  restart_realm_silent
  echo -e "${GREEN}导入完成并已应用。${RESET}"
}

# ---------------------------
# Cron schedule (14)
# ---------------------------
has_cron() {
  command -v crontab >/dev/null 2>&1 && return 0
  command -v cron >/dev/null 2>&1 && return 0
  command -v crond >/dev/null 2>&1 && return 0
  return 1
}

install_cron() {
  echo -e "${YELLOW}系统未检测到 cron/crond。${RESET}"
  read -p "是否尝试自动安装 cron？[y/N]: " ANS
  case "$ANS" in y|Y) ;; *) return 1 ;; esac

  if [ -f /etc/alpine-release ]; then
    echo -e "${GREEN}检测到 Alpine Linux，安装 cronie...${RESET}"
    need_cmd apk
    apk add --no-cache cronie || return 1
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
    return 0
  fi

  if [ -f /etc/debian_version ]; then
    echo -e "${GREEN}检测到 Debian/Ubuntu，安装 cron...${RESET}"
    need_cmd apt
    apt update && apt install -y cron || return 1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    return 0
  fi

  if [ -f /etc/redhat-release ]; then
    echo -e "${GREEN}检测到 RHEL/CentOS，安装 cronie...${RESET}"
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y cronie || return 1
    else
      need_cmd yum
      yum install -y cronie || return 1
    fi
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true
    return 0
  fi

  echo -e "${RED}无法识别发行版，请手动安装 cron/cronie。${RESET}"
  return 1
}

ensure_cron_ready() {
  if has_cron; then return 0; fi
  install_cron || { echo -e "${RED}cron 不可用，无法创建定时任务。${RESET}"; return 1; }
  has_cron || { echo -e "${RED}cron 安装/启动失败，无法创建定时任务。${RESET}"; return 1; }
  return 0
}

write_export_helper() {
  mkdir -p "$EXPORT_DIR"
  cat > "$EXPORT_HELPER" <<'EOF'
#!/bin/bash
set -e
CONFIG_FILE="/etc/realm/config.toml"
EXPORT_DIR="/etc/realm"
mkdir -p "$EXPORT_DIR"
ts="$(date +%F_%H%M%S)"
OUT="$EXPORT_DIR/realm-rules.${ts}.toml"

awk '
  BEGIN{inblk=0}
  /^[[:space:]]*(# *|)?\[\[endpoints\]\]/{inblk=1}
  { if(inblk) print }
  /^[[:space:]]*$/{ if(inblk){ print ""; inblk=0 } }
' "$CONFIG_FILE" > "$OUT"
EOF
  chmod +x "$EXPORT_HELPER"
}

schedule_status() {
  if [ -f "$CRON_FILE" ] && [ -x "$EXPORT_HELPER" ]; then
    echo -e "${GREEN}定时备份：已启用${RESET}"
    echo -e "${GREEN}Cron 文件：$CRON_FILE${RESET}"
    echo -e "${GREEN}导出脚本：$EXPORT_HELPER${RESET}"
    echo "当前 Cron 内容："
    cat "$CRON_FILE"
  else
    echo -e "${YELLOW}定时备份：未启用${RESET}"
  fi
}

normalize_hhmm() {
  local x="$1"
  x="$(echo "$x" | sed 's/^0*//')"
  [ -z "$x" ] && x="0"
  echo "$x"
}

setup_export_cron() {
  ensure_cron_ready || return
  write_export_helper

  echo "定时导出类型："
  echo "1. 每天"
  echo "2. 每周（指定周几）"
  read -p "请选择 [1-2]: " T

  local D="*"
  if [ "$T" = "2" ]; then
    echo "请选择周几：1=周一 ... 6=周六 7=周日"
    read -p "周几 [1-7]: " WD
    case "$WD" in
      1) D="1" ;;
      2) D="2" ;;
      3) D="3" ;;
      4) D="4" ;;
      5) D="5" ;;
      6) D="6" ;;
      7) D="0" ;;
      *) echo -e "${RED}周几输入无效。${RESET}"; return ;;
    esac
  elif [ "$T" != "1" ]; then
    echo -e "${RED}无效选项。${RESET}"
    return
  fi

  read -p "请输入小时（0-23，可输入 05）: " HH
  read -p "请输入分钟（0-59，可输入 00）: " MM

  HH="$(normalize_hhmm "$HH")"
  MM="$(normalize_hhmm "$MM")"

  if ! [[ "$HH" =~ ^[0-9]+$ ]] || [ "$HH" -lt 0 ] || [ "$HH" -gt 23 ]; then
    echo -e "${RED}小时无效。${RESET}"
    return
  fi
  if ! [[ "$MM" =~ ^[0-9]+$ ]] || [ "$MM" -lt 0 ] || [ "$MM" -gt 59 ]; then
    echo -e "${RED}分钟无效。${RESET}"
    return
  fi

  cat > "$CRON_FILE" <<EOF
# Auto export realm rules (generated)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$MM $HH * * $D root $EXPORT_HELPER >/dev/null 2>&1
EOF

  echo -e "${GREEN}已添加/更新定时备份任务。${RESET}"
  echo -e "${GREEN}Cron 文件：$CRON_FILE${RESET}"
}

remove_export_cron() {
  local removed=0
  if [ -f "$CRON_FILE" ]; then rm -f "$CRON_FILE"; removed=1; fi
  if [ -f "$EXPORT_HELPER" ]; then rm -f "$EXPORT_HELPER"; removed=1; fi

  if [ "$removed" -eq 1 ]; then
    echo -e "${GREEN}已删除定时备份任务（及导出脚本）。${RESET}"
  else
    echo -e "${YELLOW}未发现定时备份任务，无需删除。${RESET}"
  fi
}

manage_schedule_backup() {
  echo "--------------------"
  echo "定时备份任务管理："
  echo "1. 查看当前状态"
  echo "2. 添加/更新定时备份任务"
  echo "3. 删除定时备份任务"
  echo "0. 返回"
  read -p "请选择 [0-3]: " X

  case "$X" in
    1) schedule_status ;;
    2) setup_export_cron ;;
    3) remove_export_cron ;;
    0) return ;;
    *) echo -e "${RED}无效选项。${RESET}" ;;
  esac
}

# ---------------------------
# View
# ---------------------------
view_log() { journalctl -u realm --no-pager --since "1 hour ago"; }
view_config() { ensure_config_file; cat "$CONFIG_FILE"; }

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
    echo "9.  启动/暂停某条规则"
    echo "--------------------"
    echo "10. 查看日志"
    echo "11. 查看配置"
    echo "12. 一键导出所有规则"
    echo "13. 一键导入所有规则"
    echo "14. 添加/删除定时备份任务"
    echo "0.  退出"
    read -p "请选择一个操作 [0-14]: " OPT

    case "$OPT" in
      1) install_realm ;;
      2) uninstall_realm ;;
      0) exit 0 ;;
      3) require_installed && restart_realm_verbose ;;
      4) require_installed && add_rule ;;
      5) require_installed && delete_rule ;;
      6) require_installed && clear_rules ;;
      7) require_installed && list_rules ;;
      8) require_installed && edit_rule ;;
      9) require_installed && toggle_rule ;;
      10) require_installed && view_log ;;
      11) require_installed && view_config ;;
      12) require_installed && export_rules ;;
      13) require_installed && import_rules ;;
      14) manage_schedule_backup ;;
      *) echo -e "${RED}无效选项。${RESET}" ;;
    esac
  done
}

main_menu
