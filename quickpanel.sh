#!/bin/bash

# --- 默认兜底配置 ---
DEFAULT_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径 ---
SERVICE_FILE="/etc/systemd/system/realm-panel.service"
BINARY_PATH="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"

# --- 颜色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- 初始化最终变量 ---
FINAL_PORT="$DEFAULT_PORT"
FINAL_USER="$DEFAULT_USER"
FINAL_PASS="$DEFAULT_PASS"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}             Realm 面板 快速部署          ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# --- 开始智能检测 ---
if [ -f "$SERVICE_FILE" ]; then
    echo -e ">>> 正在读取旧配置文件..."

    CHECK_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | sed 's/.*PANEL_PORT=//' | tr -d '"' | tr -d '\r')
    
    CHECK_USER=$(grep "PANEL_USER=" "$SERVICE_FILE" | sed 's/.*PANEL_USER=//' | tr -d '"' | tr -d '\r')

    CHECK_PASS=$(grep "PANEL_PASS=" "$SERVICE_FILE" | sed 's/.*PANEL_PASS=//' | tr -d '"' | tr -d '\r')


    if [[ "$CHECK_PORT" =~ ^[0-9]+$ ]]; then
        FINAL_PORT="$CHECK_PORT"
        echo -e "    ✅ 成功提取端口: ${CYAN}$FINAL_PORT${RESET}"
    else
        echo -e "    ⚠️ 提取端口失败 (读取到: '$CHECK_PORT')，将使用默认: $DEFAULT_PORT"
    fi

    if [ -n "$CHECK_USER" ]; then
        FINAL_USER="$CHECK_USER"
        echo -e "    ✅ 成功提取账号: ${CYAN}$FINAL_USER${RESET}"
    fi

    # 密码不为空
    if [ -n "$CHECK_PASS" ]; then
        FINAL_PASS="$CHECK_PASS"
        echo -e "    ✅ 成功提取密码: (已隐藏)"
    fi
else
    echo -e ">>> 未找到旧配置文件，将使用默认设置。"
fi

ARCH=$(uname -m)
URL_AMD="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-amd.tar.gz"
URL_ARM="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-arm.tar.gz" 

if [ "$ARCH" == "x86_64" ]; then
    DOWNLOAD_URL=$URL_AMD
elif [ "$ARCH" == "aarch64" ]; then
    DOWNLOAD_URL=$URL_ARM
else
    echo -e "${RED} [错误] 不支持的架构: $ARCH${RESET}"
    exit 1
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED} [错误] 下载链接配置错误。${RESET}"
    exit 1
fi

systemctl stop realm-panel >/dev/null 2>&1

echo -n ">>> 检查基础依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl wget libssl-dev >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

echo -n ">>> 更新面板程序..."
curl -L "$DOWNLOAD_URL" -o /tmp/panel.tar.gz >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED} [失败] 下载失败!${RESET}"
    exit 1
fi
tar -xzf /tmp/panel.tar.gz -C /usr/local/bin/ >/dev/null 2>&1
chmod +x "$BINARY_PATH"
rm -f /tmp/panel.tar.gz
echo -e "${GREEN} [完成]${RESET}"

HAS_IPV6="false"
if ip -6 addr show scope global | grep -q "inet6"; then HAS_IPV6="true"; fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Panel ($ARCH)
After=network.target

[Service]
User=root
Environment="PANEL_USER=$FINAL_USER"
Environment="PANEL_PASS=$FINAL_PASS"
Environment="PANEL_PORT=$FINAL_PORT"
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
echo -e "访问地址 : ${YELLOW}http://${IP}:${FINAL_PORT}${RESET}"
echo -e "用户账号 : ${YELLOW}${FINAL_USER}${RESET}"
echo -e "用户密码 : ${YELLOW}${FINAL_PASS}${RESET}"
echo -e "------------------------------------------"
