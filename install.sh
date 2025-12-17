#!/bin/bash
set -e

CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
TMP_DIR="/tmp/realm-install"

EXPORT_DIR="/etc/realm"
DEFAULT_EXPORT_FILE="/etc/realm/realm-rules.backup.toml"
DEFAULT_IMPORT_FILE="/etc/realm/realm-rules.backup.toml"

CRON_FILE="/etc/cron.d/realm-rules-export"
EXPORT_HELPER="/usr/local/bin/realm-export-rules.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
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

validate_name() {
  local name="$1"
  [ -z "$name" ] && return 1

  local len
  len="$(printf "%s" "$name" | wc -m | tr -d ' ')"
  [ "$len" -lt 1 ] || [ "$len" -gt 50 ] && return 1

  if command -v iconv >/dev/null 2>&1; then
    printf "%s" "$name" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1
  fi

  if printf "%s" "$name" | LC_ALL=C awk '{
        for(i=1;i<=length($0);i++){
          c=substr($0,i,1)
          if (c ~ /[[:cntrl:]]/) exit 1
        }
        exit 0
      }'; then :; else return 1; fi

  printf "%s" "$name" | awk '
    BEGIN{ok=1}
    { if ($0 ~ /[^0-9A-Za-z_一-龥-]/) ok=0 }
    END{exit ok?0:1}
  ' || return 1

  return 0
}


restart_realm_silent() {
  if ! systemctl restart realm >/dev/null 2>&1; then
    systemctl restart realm || true
  fi
}

restart_realm_verbose() {
  systemctl restart realm
  echo -e "${GREEN}Realm 已重启。${RESET}"
}

get_realm_version_short() {
  local raw ver
  raw="$($REALM_BIN --version 2>/dev/null || true)"
  ver="$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/){print $i; exit}}')"
  [ -z "$ver" ] && echo "未知" || echo "$ver"
}

get_status_line() {
  if ! is_installed; then
    echo -e "状态：${YELLOW}未安装${RESET}"
    return
  fi
  local status ver
  status="$(systemctl is-active realm 2>/dev/null || true)"
  ver="$(get_realm_version_short)"
  if [ "$status" = "active" ]; then
    echo -e "状态：${GREEN}运行中${RESET}  |  版本：${GREEN}${ver}${RESET}"
  else
    echo -e "状态：${RED}未运行${RESET}  |  版本：${GREEN}${ver}${RESET}"
  fi
}


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

install_realm_inner() {
  need_cmd curl
  need_cmd tar
  need_cmd systemctl

  echo -e "${GREEN}正在安装 Realm ...${RESET}"

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
    echo -e "${RED}获取 Realm 最新版本下载地址失败。${RESET}"
    exit 1
  fi

  echo -e "${GREEN}检测到架构：$arch  libc：$libc${RESET}"
  echo -e "${GREEN}将下载：$file${RESET}"

  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR" || exit 1
  rm -f realm.tar.gz realm

  curl -L -o realm.tar.gz "$url"
  tar -xzf realm.tar.gz

  if [ ! -f "realm" ]; then
    echo -e "${RED}解压后未找到 realm 可执行文件。${RESET}"
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

    [ -z "$LISTEN" ] || [ -z "$REMOTE" ] || [ -z "$TYPE" ] && continue

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
    [ "${RULE_ENABLED[$i]}" -eq 1 ] && st="启用" || st="暂停"
    echo -e "$((i+1)). [${st}] [${RULE_NAMES[$i]}] ${RULE_LISTENS[$i]} -> ${RULE_REMOTES[$i]} (${RULE_TYPES[$i]})"
  done
  return 0
}

escape_toml() { printf "%s" "$1" | awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print}'; }

listen_mode_from_value() { [[ "$1" == \[*\]* ]] && echo "v6" || echo "v4"; }
get_port_from_listen() { echo "${1##*:}"; }
replace_listen_port_keep_proto() { echo "${1%:*}:$2"; }

has_ipv6() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 addr show 2>/dev/null | awk '/inet6/ && $2 !~ /^::1/ {ok=1} END{exit ok?0:1}'
}

choose_listen_mode_v4v6() {
  while true; do
    echo "请选择监听协议：" >&2
    echo "1. IPv4【默认】" >&2
    echo "2. IPv6" >&2
    read -p "请选择 [1-2]（默认 1）: " MODE
    MODE="${MODE:-1}"
    case "$MODE" in
      1) echo "v4"; return 0 ;;
      2)
        if has_ipv6; then
          echo "v6"; return 0
        else
          echo -e "${RED}本机无可用 IPv6，请改选 IPv4。${RESET}" >&2
        fi
        ;;
      *) echo -e "${RED}无效选项，请重新选择。${RESET}" >&2 ;;
    esac
  done
}

config_port_conflict() {
  local mode="$1" port="$2" exclude="${3:-}"
  build_rules_index
  local i listen p m
  for ((i=0; i<${#RULE_LISTENS[@]}; i++)); do
    [ -n "$exclude" ] && [ "$i" -eq "$exclude" ] && continue
    listen="${RULE_LISTENS[$i]}"
    m="$(listen_mode_from_value "$listen")"
    p="$(get_port_from_listen "$listen")"
    if [ "$m" = "$mode" ] && [ "$p" = "$port" ]; then
      return 0
    fi
  done
  return 1
}

port_in_use_system() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null | awk '{print $4}' | awk -v p=":$port" '$0 ~ (p"$") {found=1} END{exit found?0:1}'
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | awk -v p=":$port" '$0 ~ (p"$") {found=1} END{exit found?0:1}'
    return $?
  fi
  return 1
}


prompt_listen_port_checked() {
  local mode="$1"
  local exclude="${2:-}"
  local except_port="${3:-}"
  local p=""

  while true; do
    read -p "请输入监听端口: " p
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}监听端口必须是数字。${RESET}" >&2
      continue
    fi
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      echo -e "${RED}端口范围必须是 1-65535。${RESET}" >&2
      continue
    fi

    if [ -n "$except_port" ] && [ "$p" = "$except_port" ]; then
      echo "$p"
      return 0
    fi

    if config_port_conflict "$mode" "$p" "$exclude"; then
      echo -e "${RED}端口 $p 已被其它规则占用（配置冲突），请重新输入。${RESET}" >&2
      continue
    fi

    if port_in_use_system "$p"; then
      echo -e "${YELLOW}提示：系统检测到端口 $p 正在被占用。建议换端口。${RESET}" >&2
      read -p "仍然使用该端口吗？[y/N]: " ANS
      case "$ANS" in
        y|Y) echo "$p"; return 0 ;;
        *) continue ;;
      esac
    fi

    echo "$p"
    return 0
  done
}

prompt_remote_by_mode() {
  local MODE="$1"
  local REMOTE=""
  while true; do
    if [ "$MODE" = "v4" ]; then
      echo -e "${GREEN}远程目标：IPv4/域名:PORT  例：1.2.3.4:443 或 example.com:443${RESET}" >&2
      read -r -p "请输入远程目标: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}远程目标不能为空。${RESET}" >&2; continue; }

      [[ "$REMOTE" == \[*\]:* ]] && { echo -e "${RED}非 IPv4，请重输。${RESET}" >&2; continue; }
      [[ "$REMOTE" == *:* && "$REMOTE" != *"."* ]] && { echo -e "${RED} 非 IPv4，请重输。${RESET}" >&2; continue; }

      echo "$REMOTE"; return 0
    else
      echo -e "${GREEN}远程目标：[IPv6]:PORT  例：[2001:db8::1]:443${RESET}" >&2
      read -r -p "请输入远程目标: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}远程目标不能为空。${RESET}" >&2; continue; }

      echo "$REMOTE" | awk '$0 ~ /^\[[0-9A-Fa-f:]+\]:[0-9]+$/ {ok=1} END{exit ok?0:1}' \
        || { echo -e "${RED}IPv6 格式必须是 [IPv6]:PORT，请重输。${RESET}" >&2; continue; }

      echo "$REMOTE"; return 0
    fi
  done
}

apply_block_key_update() {
  local start="$1" end="$2" enabled="$3" key="$4" value="$5"
  local tmp="${CONFIG_FILE}.tmp.$$"
  local prefix=""
  [ "$enabled" -eq 0 ] && prefix="# "

  awk -v S="$start" -v E="$end" -v K="$key" -v V="$value" -v PFX="$prefix" '
    function is_key_line(line, key) { return line ~ "^[[:space:]]*(#[[:space:]]*)?" key "[[:space:]]*=" }
    BEGIN{found=0}
    {
      if (NR>=S && NR<=E-1) {
        if (!found && is_key_line($0, K)) {
          print PFX K " = \"" V "\""
          found=1
          next
        }
      }
      print $0
      if (NR>=S && NR<=E-1 && $0 ~ "^[[:space:]]*$" && !found) {
        print PFX K " = \"" V "\""
        found=1
      }
    }
  ' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

add_rule() {
  ensure_config_file

  local MODE
  MODE="$(choose_listen_mode_v4v6)"

  local NAME
  while true; do
    read -p "请输入规则名称: " NAME
    if validate_name "$NAME"; then break; fi
    echo -e "${RED}名称不合法：仅允许 中文/字母/数字/_/-，长度 1-50。${RESET}"
  done

  local LISTEN
  LISTEN="$(prompt_listen_port_checked "$MODE" "" "")"

  local REMOTE
  REMOTE="$(prompt_remote_by_mode "$MODE")"

  local NAME_ESC REMOTE_ESC
  NAME_ESC="$(escape_toml "$NAME")"
  REMOTE_ESC="$(escape_toml "$REMOTE")"

  local LISTEN_ADDR
  [ "$MODE" = "v6" ] && LISTEN_ADDR="[::]:$LISTEN" || LISTEN_ADDR="0.0.0.0:$LISTEN"

  cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
name   = "$NAME_ESC"
listen = "$LISTEN_ADDR"
remote = "$REMOTE_ESC"
type   = "tcp+udp"
EOF

  restart_realm_silent
  echo -e "${GREEN}已添加规则 [$NAME] 并已应用。${RESET}"
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

  local START END tmp
  START=${RULE_STARTS[$IDX]}
  END=${RULE_ENDS[$IDX]}
  tmp="${CONFIG_FILE}.tmp.$$"
  awk -v S="$START" -v E="$END" 'NR<S || NR>=E {print}' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"

  restart_realm_silent
  echo -e "${GREEN}规则已删除并已应用。${RESET}"
}

clear_rules() {
  ensure_config_file
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

  local START END ENABLED CUR_LISTEN CUR_MODE CUR_PORT
  START=${RULE_STARTS[$IDX]}
  END=${RULE_ENDS[$IDX]}
  ENABLED=${RULE_ENABLED[$IDX]}
  CUR_LISTEN="${RULE_LISTENS[$IDX]}"
  CUR_MODE="$(listen_mode_from_value "$CUR_LISTEN")"
  CUR_PORT="$(get_port_from_listen "$CUR_LISTEN")"

  echo -e "${GREEN}选中规则：${RESET}$((IDX+1)). [${RULE_NAMES[$IDX]}] ${RULE_LISTENS[$IDX]} -> ${RULE_REMOTES[$IDX]} (${RULE_TYPES[$IDX]})"
  echo "要修改哪个字段？"
  echo "1. 名称"
  echo "2. 监听端口"
  echo "3. 远程目标:端口"
  echo "0. 返回"
  read -p "请选择 [0-3]: " OPT

  case "$OPT" in
    1)
      local NEW
      while true; do
        read -p "请输入新名称: " NEW
        if validate_name "$NEW"; then break; fi
        echo -e "${RED}名称不合法：仅允许 中文/字母/数字/_/-，长度 1-50。${RESET}"
      done
      apply_block_key_update "$START" "$END" "$ENABLED" "name" "$(escape_toml "$NEW")"
      ;;
    2)
      local NEWP
      NEWP="$(prompt_listen_port_checked "$CUR_MODE" "$IDX" "$CUR_PORT")"
      local NEW_LISTEN
      NEW_LISTEN="$(replace_listen_port_keep_proto "$CUR_LISTEN" "$NEWP")"
      apply_block_key_update "$START" "$END" "$ENABLED" "listen" "$NEW_LISTEN"
      ;;
    3)
      local NEWR
      NEWR="$(prompt_remote_by_mode "$CUR_MODE")"
      apply_block_key_update "$START" "$END" "$ENABLED" "remote" "$(escape_toml "$NEWR")"
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

  local START END tmp
  START=${RULE_STARTS[$IDX]}
  END=${RULE_ENDS[$IDX]}
  tmp="${CONFIG_FILE}.tmp.$$"

  if [ "${RULE_ENABLED[$IDX]}" -eq 1 ]; then
    awk -v S="$START" -v E="$END" '
      NR>=S && NR<=E-1 { sub(/^[[:space:]]*#?[[:space:]]*/, "# "); print; next }
      {print}
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}已暂停规则：${RULE_NAMES[$IDX]}${RESET}"
  else
    awk -v S="$START" -v E="$END" '
      NR>=S && NR<=E-1 { sub(/^[[:space:]]*#[[:space:]]*/, ""); print; next }
      {print}
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    restart_realm_silent
    echo -e "${GREEN}已启动规则：${RULE_NAMES[$IDX]}${RESET}"
  fi
}

export_rules() {
  ensure_config_file
  mkdir -p "$EXPORT_DIR"
  read -p "导出文件路径 [${DEFAULT_EXPORT_FILE}]: " OUT
  OUT="${OUT:-$DEFAULT_EXPORT_FILE}"

  awk '
    BEGIN{inblk=0}
    /^[[:space:]]*(# *|)?\[\[endpoints\]\]/{inblk=1}
    { if(inblk) print }
    /^[[:space:]]*$/{ if(inblk){ print ""; inblk=0 } }
  ' "$CONFIG_FILE" > "$OUT"

  if [ ! -s "$OUT" ]; then
    echo -e "${YELLOW}未导出任何规则（可能当前没有 endpoints 块）。${RESET}"
  else
    echo -e "${GREEN}导出完成！${RESET}"
  fi
  echo -e "${GREEN}导出文件路径：$OUT${RESET}"
}

import_rules() {
  ensure_config_file
  read -p "请输入要导入的文件路径（回车默认：${DEFAULT_IMPORT_FILE}）: " IN
  IN="${IN:-$DEFAULT_IMPORT_FILE}"

  if [ -z "$IN" ] || [ ! -f "$IN" ]; then
    echo -e "${RED}导入文件不存在：$IN${RESET}"
    return
  fi
  
  if ! grep -q -E '^[[:space:]]*(#\s*)?\[\[endpoints\]\]' "$IN"; then
    echo -e "${RED}导入文件不包含 [[endpoints]] 块。${RESET}"
    return
  fi

  echo -e "${GREEN}导入文件规则数：$(grep -c -E '^[[:space:]]*(#\s*)?\[\[endpoints\]\]' "$IN")${RESET}"
  echo "导入模式："
  echo "1. 覆盖（清空现有规则后导入）"
  echo "2. 追加（在现有规则后追加导入）"
  read -p "请选择 [1-2]: " MODE

  case "$MODE" in
    1) clear_rules ;;
    2) ;;
    *) echo -e "${RED}无效选项。${RESET}"; return ;;
  esac

  cat >> "$CONFIG_FILE" <<EOF

# ---- Imported rules from: $IN ----
EOF
  cat "$IN" >> "$CONFIG_FILE"

  restart_realm_silent
  echo -e "${GREEN}导入完成并已应用。${RESET}"
}


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
    need_cmd apk
    apk add --no-cache cronie || return 1
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
    return 0
  fi

  if [ -f /etc/debian_version ]; then
    need_cmd apt
    apt update && apt install -y cron || return 1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    return 0
  fi

  if [ -f /etc/redhat-release ]; then
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
    echo "Cron 内容："
    cat "$CRON_FILE"
  else
    echo -e "${YELLOW}定时备份：未启用${RESET}"
  fi
}

normalize_hhmm() {
  local x="$1"
  x="${x#0}"; [ -z "$x" ] && x="0"
  echo "$x"
}

setup_export_cron() {
  ensure_cron_ready || return
  write_export_helper

  echo "定时导出类型："
  echo "1. 每天"
  echo "2. 每周"
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

  echo -e "${GREEN}已添加定时备份任务。${RESET}"
  echo -e "${GREEN}Cron 文件：$CRON_FILE${RESET}"
}

remove_export_cron() {
  local removed=0
  [ -f "$CRON_FILE" ] && rm -f "$CRON_FILE" && removed=1
  [ -f "$EXPORT_HELPER" ] && rm -f "$EXPORT_HELPER" && removed=1
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
  echo "2. 添加定时备份任务"
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

install_ftp(){
    clear
    echo -e "${GREEN}📂 FTP/SFTP 备份工具...${RESET}"
    echo -e "${YELLOW}默认 Realm 规则备份文件：${DEFAULT_EXPORT_FILE}${RESET}"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}


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
    echo "15. 自动备份到FTP/SFTP"
    echo "0.  退出"
    read -p "请选择一个操作 [0-15]: " OPT

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
      10) require_installed && journalctl -u realm --no-pager --since "1 hour ago" ;;
      11) require_installed && cat "$CONFIG_FILE" ;;
      12) require_installed && export_rules ;;
      13) require_installed && import_rules ;;
      14) manage_schedule_backup ;;
      15) install_ftp ;;
      *) echo -e "${RED}无效选项。${RESET}" ;;
    esac
  done
}

main_menu
