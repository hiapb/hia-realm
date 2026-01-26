#!/bin/bash

# --- 配置 ---
# 填写你上传的成品二进制文件直链
URL_AMD="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel.tar.gz"
URL_ARM=""  # <--- 在这里填入你以后编译好的 ARM 版链接

PANEL_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径 ---
BINARY_PATH="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    Realm 面板 一键部署    ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

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
apt-get update && apt-get install -y curl wget libssl-dev >/dev/null 2>&1
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
echo -n ">>> 正在下载面板..."
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
cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Panel ($ARCH)
After=network.target

[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
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
echo -e "${GREEN}✅ Realm 转发面板部署成功!"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"
