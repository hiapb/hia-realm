#!/bin/bash

# --- 默认配置
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
echo -e "${GREEN}            Realm 面板 快速部署           ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

CURRENT_PORT="$DEFAULT_PORT"
CURRENT_USER="$DEFAULT_USER"
CURRENT_PASS="$DEFAULT_PASS"

if [ -f "$SERVICE_FILE" ]; then
    echo -e ">>> 检测到已安装面板，正在读取旧配置..."
    
    OLD_PORT=$(grep 'Environment="PANEL_PORT=' "$SERVICE_FILE" | awk -F 'PANEL_PORT=' '{print $2}' | tr -d '"')
    if [ -n "$OLD_PORT" ]; then
        CURRENT_PORT="$OLD_PORT"
        echo -e "    保留端口: ${CYAN}$CURRENT_PORT${RESET}"
    fi

    OLD_USER=$(grep 'Environment="PANEL_USER=' "$SERVICE_FILE" | awk -F 'PANEL_USER=' '{print $2}' | tr -d '"')
    if [ -n "$OLD_USER" ]; then
        CURRENT_USER="$OLD_USER"
        echo -e "    保留用户: ${CYAN}$CURRENT_USER${RESET}"
    fi

    OLD_PASS=$(grep 'Environment="PANEL_PASS=' "$SERVICE_FILE" | awk -F 'PANEL_PASS=' '{print $2}' | tr -d '"')
    if [ -n "$OLD_PASS" ]; then
        CURRENT_PASS="$OLD_PASS"
        echo -e "    保留密码: ${CYAN}(已隐藏)${RESET}"
    fi
else
    echo -e ">>> 未检测到旧配置，使用默认设置。"
fi

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

# 6. 配置 Systemd 服务
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


IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Realm 转发面板部署成功!${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${CURRENT_PORT}${RESET}"
echo -e "用户账号 : ${YELLOW}${CURRENT_USER}${RESET}"
echo -e "用户密码 : ${YELLOW}${CURRENT_PASS}${RESET}"
echo -e "------------------------------------------"
