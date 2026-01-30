#!/bin/bash

# ==========================================
# Realm 面板 快速部署 (智能保留配置版)
# ==========================================

# --- 1. 定义默认配置 (作为兜底) ---
# 如果是全新安装，或者读取失败，将使用这些值
FINAL_PORT="4794"
FINAL_USER="admin"
FINAL_PASS="123456"

# --- 资源链接 ---
URL_AMD="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-amd.tar.gz"
URL_ARM="https://github.com/hiapb/hia-realm/releases/download/realm/realm-panel-arm.tar.gz" 

# --- 系统路径 ---
BINARY_PATH="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm-panel.service"

# --- 颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    Realm 面板 快速部署 (智能保留配置)    ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# ==========================================
# 2. 智能检测旧配置 (核心逻辑)
# ==========================================
if [ -f "$SERVICE_FILE" ]; then
    echo -e ">>> 检测到已安装面板，正在读取现有配置..."
    
    # 使用 grep -o 精确提取 Environment="KEY=VALUE" 中的 VALUE 部分
    # 逻辑：匹配 KEY=... 直到遇到双引号，然后用 cut 取等号右边
    
    # 1. 提取端口
    OLD_PORT=$(grep -o 'PANEL_PORT=[^"]*' "$SERVICE_FILE" | cut -d'=' -f2)
    # 校验是否为纯数字
    if [[ "$OLD_PORT" =~ ^[0-9]+$ ]]; then
        FINAL_PORT="$OLD_PORT"
        echo -e "    ✅ 保留旧端口: ${CYAN}$FINAL_PORT${RESET}"
    fi

    # 2. 提取用户
    OLD_USER=$(grep -o 'PANEL_USER=[^"]*' "$SERVICE_FILE" | cut -d'=' -f2)
    if [ -n "$OLD_USER" ]; then
        FINAL_USER="$OLD_USER"
        echo -e "    ✅ 保留旧账号: ${CYAN}$FINAL_USER${RESET}"
    fi

    # 3. 提取密码
    OLD_PASS=$(grep -o 'PANEL_PASS=[^"]*' "$SERVICE_FILE" | cut -d'=' -f2)
    if [ -n "$OLD_PASS" ]; then
        FINAL_PASS="$OLD_PASS"
        echo -e "    ✅ 保留旧密码: ${CYAN}(已隐藏)${RESET}"
    fi
else
    echo -e ">>> 未检测到旧配置，将使用默认设置 (端口: $FINAL_PORT)。"
fi
# ==========================================

# 3. 架构检测
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
    echo -e "${RED} [错误] 尚未配置此架构的下载链接。${RESET}"
    exit 1
fi

# 4. 基础环境
echo -n ">>> 正在安装基础依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl wget libssl-dev >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

# 5. 下载 Realm 核心 (适配架构)
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

# 6. 下载并更新面板程序
echo -n ">>> 正在更新面板程序..."
# 先停止服务，防止二进制文件被占用导致写入失败
systemctl stop realm-panel >/dev/null 2>&1

curl -L "$DOWNLOAD_URL" -o /tmp/realm-panel.tar.gz >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED} [失败] 下载失败，请检查网络或链接${RESET}"
    exit 1
fi

tar -xzvf /tmp/realm-panel.tar.gz -C /usr/local/bin/ >/dev/null 2>&1
chmod +x "$BINARY_PATH"
rm -f /tmp/realm-panel.tar.gz
echo -e "${GREEN} [完成]${RESET}"

# 7. 检测 IPv6
if ip -6 addr show scope global | grep -q "inet6"; then
    HAS_IPV6="true"
else
    HAS_IPV6="false"
fi

# 8. 写入 Systemd 服务 (使用 FINAL_ 变量)
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

# 9. 完成提示 (显示最终生效的配置)
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Realm 转发面板部署成功!${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${FINAL_PORT}${RESET}"
echo -e "用户账号 : ${YELLOW}${FINAL_USER}${RESET}"
echo -e "用户密码 : ${YELLOW}${FINAL_PASS}${RESET}"
echo -e "------------------------------------------"
if [ "$FINAL_PORT" != "4794" ]; then
    echo -e "提示：检测到您使用了自定义配置，已自动为您保留。"
fi
