#!/bin/bash

# ==========================================
# Realm Web 面板一键部署脚本
# ==========================================

# --- 配置区域 ---
PANEL_PORT="8080"
PANEL_USER="admin"
PANEL_PASS="123456"

# --- 路径定义 ---
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG="/etc/realm/config.toml"
PANEL_DIR="/usr/local/realm_panel"
PANEL_FILE="$PANEL_DIR/panel.py"

# --- 颜色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 1. 检查权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行！${RESET}"
    exit 1
fi

echo -e "${GREEN}>>> 开始部署 Realm + Web 面板...${RESET}"

# 2. 安装系统依赖
echo -e "${YELLOW}正在安装系统环境...${RESET}"
if [ -f /etc/debian_version ]; then
    apt-get update -y
    apt-get install -y curl wget tar python3 python3-pip
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar python3 python3-pip
fi

# 3. 安装 Realm (如果不存在)
if [ ! -f "$REALM_BIN" ]; then
    echo -e "${YELLOW}正在安装 Realm 主程序...${RESET}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    else
        echo -e "${RED}不支持的架构: $ARCH${RESET}"
        exit 1
    fi

    mkdir -p /tmp/realm_tmp
    wget -O /tmp/realm_tmp/realm.tar.gz "$URL"
    tar -xvf /tmp/realm_tmp/realm.tar.gz -C /tmp/realm_tmp >/dev/null 2>&1
    mv /tmp/realm_tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -rf /tmp/realm_tmp
else
    echo -e "${GREEN}Realm 已安装。${RESET}"
fi

# 确保配置和 Realm 服务存在
mkdir -p "$(dirname "$REALM_CONFIG")"
touch "$REALM_CONFIG"

cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Proxy
After=network.target

[Service]
ExecStart=$REALM_BIN -c $REALM_CONFIG
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 4. 安装 Python 库 (核心修复点)
echo -e "${YELLOW}正在安装面板依赖库...${RESET}"
# 尝试标准安装，如果失败尝试 break-system-packages (针对新版 Debian/Ubuntu)
pip3 install fastapi uvicorn toml >/dev/null 2>&1 || pip3 install fastapi uvicorn toml --break-system-packages

# 5. 写入面板代码
echo -e "${YELLOW}正在写入面板代码...${RESET}"
mkdir -p "$PANEL_DIR"
cat > "$PANEL_FILE" << 'EOF'
import toml, subprocess, secrets, os
from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

CONFIG_FILE = "/etc/realm/config.toml"
PANEL_USER = os.getenv("PANEL_USER", "admin")
PANEL_PASS = os.getenv("PANEL_PASS", "123456")

app = FastAPI()
security = HTTPBasic()

def check_auth(credentials: HTTPBasicCredentials = Depends(security)):
    if not (secrets.compare_digest(credentials.username, PANEL_USER) and secrets.compare_digest(credentials.password, PANEL_PASS)):
        raise HTTPException(status_code=401, detail="Auth Failed", headers={"WWW-Authenticate": "Basic"})
    return credentials.username

def rw_config(data=None):
    if data is None: 
        if not os.path.exists(CONFIG_FILE): return {"endpoints": []}
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f: return toml.load(f)
        except: return {"endpoints": []}
    else:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, "w", encoding="utf-8") as f: toml.dump(data, f)
        try: subprocess.run(["systemctl", "restart", "realm"], check=False)
        except: pass

class Rule(BaseModel):
    name: str
    listen: str
    remote: str

@app.get("/", response_class=HTMLResponse)
async def page(u: str = Depends(check_auth)):
    return """
    <!DOCTYPE html><html lang="zh"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Realm Panel</title>
    <style>body{font-family:sans-serif;max-width:800px;margin:2rem auto;padding:1rem;background:#f8fafc;color:#334155}.card{background:#fff;padding:1.5rem;border-radius:10px;box-shadow:0 1px 3px rgba(0,0,0,.1);margin-bottom:1.5rem}input{padding:10px;border:1px solid #cbd5e1;border-radius:6px;width:100%;margin:5px 0;box-sizing:border-box}button{background:#3b82f6;color:#fff;border:none;padding:10px 20px;border-radius:6px;cursor:pointer;width:100%}button.del{background:#ef4444;width:auto;padding:5px 10px;font-size:12px}table{width:100%;border-collapse:collapse;margin-top:10px}th,td{text-align:left;padding:10px;border-bottom:1px solid #e2e8f0}.badge{background:#dbeafe;color:#1e40af;padding:2px 6px;border-radius:4px;font-size:12px}</style></head><body>
    <div class="card"><h2>🚀 添加规则</h2><input id="n" placeholder="备注"><input id="l" placeholder="监听端口 (如 10000)"><input id="r" placeholder="目标地址 (如 1.1.1.1:443)"><br><br><button onclick="add()">添加</button></div>
    <div class="card"><h3>规则列表</h3><table id="t"><tbody></tbody></table></div>
    <script>
    const api='/api/rules';
    async function load(){const d=await(await fetch(api)).json();document.querySelector('#t tbody').innerHTML=d.endpoints.map((r,i)=>`<tr><td><span class="badge">${r.name||'-'}</span></td><td>${r.listen}</td><td>${r.remote}</td><td><button class="del" onclick="del(${i})">删除</button></td></tr>`).join('')}
    async function add(){const [n,l,r]=['n','l','r'].map(i=>document.getElementById(i).value);if(!l||!r)return alert('必填');await fetch(api,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l.includes(':')?l:'0.0.0.0:'+l,remote:r})});load();document.getElementById('n').value='';}
    async function del(i){if(confirm('删?'))await fetch(`${api}/${i}`,{method:'DELETE'});load()}
    load();
    </script></body></html>
    """
@app.get("/api/rules")
async def get(u: str = Depends(check_auth)): return rw_config()
@app.post("/api/rules")
async def add(r: Rule, u: str = Depends(check_auth)): c=rw_config(); c.setdefault("endpoints",[]).append(r.dict()); rw_config(c); return {"ok":1}
@app.delete("/api/rules/{i}")
async def delete(i: int, u: str = Depends(check_auth)): c=rw_config(); c["endpoints"].pop(i); rw_config(c); return {"ok":1}
EOF

# 6. 配置服务 (使用 python3 -m uvicorn 避免路径问题)
echo -e "${YELLOW}正在配置系统服务...${RESET}"
cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Web Panel
After=network.target

[Service]
User=root
WorkingDirectory=$PANEL_DIR
Environment="PANEL_USER=$PANEL_USER"
Environment="PANEL_PASS=$PANEL_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
# 关键修改：直接调用 python 模块，不依赖 uvicorn 二进制路径
ExecStart=/usr/bin/python3 -m uvicorn panel:app --host 0.0.0.0 --port $PANEL_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl start realm >/dev/null 2>&1
systemctl enable realm-panel >/dev/null 2>&1
systemctl restart realm-panel

# 8. 验证与输出
sleep 2
if systemctl is-active --quiet realm-panel; then
    IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
    echo -e ""
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}✅ Realm 面板部署成功！${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "管理地址: ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
    echo -e "用户名  : ${YELLOW}${PANEL_USER}${RESET}"
    echo -e "密码    : ${YELLOW}${PANEL_PASS}${RESET}"
else
    echo -e "${RED}========================================${RESET}"
    echo -e "${RED}❌ 面板启动失败，请运行以下命令查看日志：${RESET}"
    echo -e "${YELLOW}journalctl -u realm-panel -n 20 --no-pager${RESET}"
fi
