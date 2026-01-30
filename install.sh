#!/bin/bash

# --- 默认配置 ---
DEFAULT_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 下载链接 ---
URL_AMD="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-amd.tar.gz"
URL_ARM="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-arm.tar.gz" 

# --- 路径 ---
BINARY_PATH="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm-panel.service"

# --- 颜色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    Realm 面板 快速部署 (智能校验版)      ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# ==========================================
# 0. 智能读取与校验 (修复核心)
# ==========================================
CURRENT_PORT=""
CURRENT_USER=""
CURRENT_PASS=""

if [ -f "$SERVICE_FILE" ]; then
    echo -e ">>> 正在读取旧配置..."
    
    # 使用 sed 正则提取，兼容有无引号的情况
    # 逻辑：匹配 Environment=...PANEL_PORT= 之后的内容，直到遇到引号或行尾
    READ_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | head -n 1 | sed -n 's/.*PANEL_PORT=\([^"[:space:]]*\).*/\1/p')
    READ_USER=$(grep "PANEL_USER=" "$SERVICE_FILE" | head -n 1 | sed -n 's/.*PANEL_USER=\([^"[:space:]]*\).*/\1/p')
    READ_PASS=$(grep "PANEL_PASS=" "$SERVICE_FILE" | head -n 1 | sed -n 's/.*PANEL_PASS=\([^"[:space:]]*\).*/\1/p')

    # --- 校验端口 (关键步骤) ---
    # 如果提取到的端口是纯数字，且不为空，则保留
    if [[ "$READ_PORT" =~ ^[0-9]+$ ]]; then
        CURRENT_PORT="$READ_PORT"
        echo -e "    ✅ 识别到有效端口: ${CYAN}$CURRENT_PORT${RESET}"
    else
        echo -e "    ⚠️ 旧配置端口异常 ($READ_PORT)，将重置为默认值。"
        CURRENT_PORT="$DEFAULT_PORT"
    fi

    # --- 校验用户 ---
    if [ -n "$READ_USER" ] && [ "$READ_USER" != "PANEL_USER" ]; then
        CURRENT_USER="$READ_USER"
        echo -e "    ✅ 识别到有效用户: ${CYAN}$CURRENT_USER${RESET}"
    else
        CURRENT_USER="$DEFAULT_USER"
    fi

    # --- 校验密码 ---
    if [ -n "$READ_PASS" ] && [ "$READ_PASS" != "PANEL_PASS" ]; then
        CURRENT_PASS="$READ_PASS"
        echo -e "    ✅ 识别到有效密码: (已保留)"
    else
        CURRENT_PASS="$DEFAULT_PASS"
    fi
else
    echo -e ">>> 未检测到旧配置，使用默认设置。"
    CURRENT_PORT="$DEFAULT_PORT"
    CURRENT_USER="$DEFAULT_USER"
    CURRENT_PASS="$DEFAULT_PASS"
fi
# ==========================================

# 1. 架构检测
ARCH=$(uname -m)
DOWNLOAD_URL=""

if [ "$ARCH" == "x86_64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}AMD64 (x86_64)${RESET}"
    DOWNLOAD_URL=$URL_AMD
elif [ "$ARCH" == "aarch64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}ARM64 (aarch64)${RESET}"
    DOWNLOAD_URL=$URL_ARM
else
    echo -e "${RED} [错误] 不支持的系统架构: $ARCH${RESET}"
    exit 1
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED} [错误] 尚未配置此架构的下载链接，请检查脚本配置。${RESET}"
    exit 1
fi

# 2. 基础环境
echo -n ">>> 正在安装基础依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl wget libssl-dev >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

# 3. 下载 Realm 核心 (适配架构)
if [ ! -f "$REALM_BIN" ]; then
    echo -n ">>> 下载 Realm 核心程序 ($ARCH)..."
    if [ "$ARCH" == "x86_64" ]; then
        REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    else
        REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    fi
    
    mkdir -p /tmp/realm_tmp
    curl -L "$REALM_URL" -o /tmp/realm_tmp/realm.tar.gz >/dev/null 2>&1
    tar -xzvf /tmp/realm_tmp/realm.tar.gz -C /tmp/realm_tmp >/dev/null 2>&1
    mv /tmp/realm_tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    rm -rf /tmp/realm_tmp
    echo -e "${GREEN} [完成]${RESET}"
fi

# 4. 下载并解压面板二进制
echo -n ">>> 正在更新面板程序..."
# 先停止服务，防止文件被占用
systemctl stop realm-panel >/dev/null 2>&1

curl -L "$DOWNLOAD_URL" -o /tmp/realm-panel.tar.gz >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED} [失败] 下载失败，请检查 Release 链接是否有效${RESET}"
    exit 1
fi

tar -xzvf /tmp/realm-panel.tar.gz -C /usr/local/bin/ >/dev/null 2>&1
chmod +x "$BINARY_PATH"
rm -f /tmp/realm-panel.tar.gz
echo -e "${GREEN} [完成]${RESET}"

# 5. 检测 IPv6
if ip -6 addr show scope global | grep -q "inet6"; then
    HAS_IPV6="true"
else
    HAS_IPV6="false"
fi

# 6. 配置 Systemd 服务 (使用校验后的 CURRENT 变量)
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Realm Panel ($ARCH)
After=network.target

[Service]
User=root
Environment="PANEL_USER=$CURRENT_USER"
Environment="PANEL_PASS=$CURRENT_PASS"
Environment="PANEL_PORT=$CURRENT_PORT"
Environment="ENABLE_IPV6=$HAS_IPV6"
ExecStart=$BINARY_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm-panel >/dev/null 2>&1
systemctl restart realm-panel >/dev/null 2>&1

# 7. 完成提示
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}          ✅ Realm 转发面板部署成功!      ${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${CURRENT_PORT}${RESET}"
echo -e "用户账号 : ${YELLOW}${CURRENT_USER}${RESET}"
echo -e "用户密码 : ${YELLOW}${CURRENT_PASS}${RESET}"
echo -e "------------------------------------------"
