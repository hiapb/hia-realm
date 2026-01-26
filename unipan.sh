#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行！${RESET}"
    exit 1
fi

echo -e "${YELLOW}>>> 正在卸载 Realm 转发面板及 Rust 环境...${RESET}"

# 2. 停止并禁用面板服务
if systemctl is-active --quiet realm-panel; then
    systemctl stop realm-panel
    systemctl disable realm-panel >/dev/null 2>&1
fi

# 3. 删除面板相关文件
echo -e "${YELLOW}正在清理文件...${RESET}"
rm -f /usr/local/bin/realm-panel      
rm -f /etc/systemd/system/realm-panel.service # 服务文件
rm -f /etc/realm/panel_data.json     
rm -rf /opt/realm_panel_pro           
# 4. 卸载 Rust 编译环境 (清理依赖)
if command -v rustup &> /dev/null; then
    echo -e "${YELLOW}正在卸载 Rust 编译环境 (释放磁盘空间)...${RESET}"
    # 自动确认卸载
    rustup self uninstall -y >/dev/null 2>&1
    echo -e "${GREEN}Rust 环境已卸载。${RESET}"
else
    echo -e "${YELLOW}未检测到 Rust 环境，跳过卸载。${RESET}"
fi

# 5. 重载系统服务
systemctl daemon-reload
systemctl reset-failed

echo -e ""
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}✅ 卸载完毕！${RESET}"
echo -e "1. Web 面板已移除。"
echo -e "2. Rust 编译环境已清理。"
echo -e "----------------------------------------"
echo -e "🛡️  Realm 核心状态："
# 检查 Realm 是否还活着
if systemctl is-active --quiet realm; then
    echo -e "   [${GREEN}运行中${RESET}] 你的转发规则依然生效。"
else
    echo -e "   [${RED}停止${RESET}] Realm 当前未运行 (如需启动请运行 systemctl start realm)。"
fi
echo -e "${GREEN}========================================${RESET}"
