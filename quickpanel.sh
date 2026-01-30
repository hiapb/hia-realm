#!/bin/bash

# ==========================================
# 0. 核心配置与检测逻辑
# ==========================================

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
echo -e "${GREEN}    Realm 面板 快速部署 (强力读取版)      ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# --- 开始智能检测 ---
if [ -f "$SERVICE_FILE" ]; then
    echo -e ">>> 正在读取旧配置文件..."

    # 1. 暴力读取端口
    # 逻辑：找到含 PANEL_PORT= 的行 -> 删掉 PANEL_PORT= 及其左边所有字符 -> 删掉双引号 -> 删掉回车
    CHECK_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | sed 's/.*PANEL_PORT=//' | tr -d '"' | tr -d '\r')
    
    # 2. 暴力读取账号
    CHECK_USER=$(grep "PANEL_USER=" "$SERVICE_FILE" | sed 's/.*PANEL_USER=//' | tr -d '"' | tr -d '\r')
    
    # 3. 暴力读取密码
    CHECK_PASS=$(grep "PANEL_PASS=" "$SERVICE_FILE" | sed 's/.*PANEL_PASS=//' | tr -d '"' | tr -d '\r')

    # --- 判定逻辑 ---
    
    # 端口必须是纯数字且不为空
    if [[ "$CHECK_PORT" =~ ^[0-9]+$ ]]; then
        FINAL_PORT="$CHECK_PORT"
        echo -e "    ✅ 成功提取端口: ${CYAN}$FINAL_PORT${RESET}"
    else
        echo -e "    ⚠️ 提取端口失败 (读取到: '$CHECK_PORT')，将使用默认: $DEFAULT_PORT"
    fi

    # 账号不为空
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

# ==========================================
# 1. 架构检测与下载
# ==========================================
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

# ==========================================
# 2. 安装/更新流程
# ==========================================

# 停止服务防止文件占用
systemctl stop realm-panel >/dev/null 2>&1

# 基础依赖
echo -n ">>> 检查基础依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl wget libssl-dev >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

# 安装核心 Realm (如果不存在)
if [ ! -f "$REALM_BIN" ]; then
    echo -n ">>> 安装 Realm 核心..."
    if [ "$ARCH" == "x86_64" ]; then
        R_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    else
        R_URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    fi
    mkdir -p /tmp/rtmp
    curl -L "$R_URL" -o /tmp/rtmp/r.tar.gz >/dev/null 2>&1
    tar -xzf /tmp/rtmp/r.tar.gz -C /tmp/rtmp
    mv /tmp/rtmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    rm -rf /tmp/rtmp
    echo -e "${GREEN} [完成]${RESET}"
fi

# 更新面板程序
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

# ==========================================
# 3. 写入配置 (使用提取到的 FINAL 变量)
# ==========================================
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

# ==========================================
# 4. 最终展示 (确保正确)
# ==========================================
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Realm 转发面板部署成功!${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${FINAL_PORT}${RESET}"
echo -e "用户账号 : ${YELLOW}${FINAL_USER}${RESET}"
echo -e "用户密码 : ${YELLOW}${FINAL_PASS}${RESET}"
echo -e "------------------------------------------"
