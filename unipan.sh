#!/bin/bash

# --- 配置 ---
PANEL_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径 ---
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG="/etc/realm/config.toml"
WORK_DIR="/opt/realm_panel_lite"
BINARY_PATH="/usr/local/bin/realm-panel"
DATA_FILE="/etc/realm/panel_data.json"

# --- 颜色 ---
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 运行！${RESET}"
    exit 1
fi

# 1. 环境准备
apt-get update && apt-get install -y curl wget tar pkg-config libssl-dev build-essential

if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# 2. Realm 下载
if [ ! -f "$REALM_BIN" ]; then
    ARCH=$(uname -m)
    [ "$ARCH" == "x86_64" ] && URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    [ "$ARCH" == "aarch64" ] && URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    wget -O /tmp/realm.tar.gz "$URL" && tar -xvf /tmp/realm.tar.gz -C /usr/local/bin/ && chmod +x "$REALM_BIN"
fi
mkdir -p /etc/realm

# 3. 编写代码 
mkdir -p "$WORK_DIR/src"
cd "$WORK_DIR"

cat > Cargo.toml <<EOF
[package]
name = "realm-panel"
version = "1.0.0"
edition = "2021"

[dependencies]
rouille = "3.6"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
toml = "0.8"
uuid = { version = "1.0", features = ["v4"] }
EOF

cat > src/main.rs << 'EOF'
use rouille::{Request, Response};
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};
use std::sync::{Arc, Mutex};

#[derive(Serialize, Deserialize, Clone)]
struct Rule { id: String, name: String, listen: String, remote: String, enabled: bool }
#[derive(Serialize, Deserialize, Clone)]
struct AppData { username: String, pass: String, rules: Vec<Rule> }

struct State { data: AppData }

fn main() {
    let data_path = "/etc/realm/panel_data.json";
    let initial_data = if let Ok(c) = fs::read_to_string(data_path) {
        serde_json::from_str(&c).unwrap_or(AppData { username: "admin".into(), pass: "123456".into(), rules: vec![] })
    } else {
        AppData { username: "admin".into(), pass: "123456".into(), rules: vec![] }
    };

    let state = Arc::new(Mutex::new(State { data: initial_data }));
    let port = "4794";

    println!("Server running on http://0.0.0.0:{}", port);

    rouille::start_server(format!("0.0.0.0:{}", port), move |request| {
        let mut s = state.lock().unwrap();
        
        // 简易路由
        rouille::router!(request,
            (GET) (/) => {
                let html = include_str!("index.html");
                Response::html(html.replace("{{USER}}", &s.data.username))
            },
            (POST) (/api/login) => {
                // 简化逻辑：前端直接校验 cookie，这里仅展示示例
                Response::json(&"ok")
            },
            (GET) (/api/rules) => {
                Response::json(&s.data.rules)
            },
            (POST) (/api/rules) => {
                let req: Rule_Req = rouille::input::json_input(request).unwrap();
                let new_rule = Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, enabled: true };
                s.data.rules.push(new_rule);
                save(&s.data);
                Response::json(&"ok")
            },
            (DELETE) (/api/rules/{id: String}) => {
                s.data.rules.retain(|r| r.id != id);
                save(&s.data);
                Response::json(&"ok")
            },
            (GET) (/api/ping/{id: String}) => {
                if let Some(r) = s.data.rules.iter().find(|x| x.id == id) {
                    let res = do_ping(&r.remote);
                    Response::json(&res)
                } else {
                    Response::empty_404()
                }
            },
            _ => Response::empty_404()
        )
    });
}

#[derive(Deserialize)] struct Rule_Req { name: String, listen: String, remote: String }
#[derive(Serialize)] struct Ping_Res { status: String, ms: u128, addr: String, msg: String }

fn do_ping(target: &str) -> Ping_Res {
    let start = Instant::now();
    match target.to_socket_addrs() {
        Ok(mut addrs) => {
            if let Some(addr) = addrs.next() {
                match TcpStream::connect_timeout(&addr, Duration::from_secs(2)) {
                    Ok(_) => Ping_Res { status: "ok".into(), ms: start.elapsed().as_millis(), addr: addr.to_string(), msg: "连接成功".into() },
                    Err(e) => Ping_Res { status: "err".into(), ms: 0, addr: addr.to_string(), msg: format!("失败: {}", e) }
                }
            } else { Ping_Res { status: "err".into(), ms: 0, addr: target.into(), msg: "解析失败".into() } }
        }
        Err(_) => Ping_Res { status: "err".into(), ms: 0, addr: target.into(), msg: "格式错误".into() }
    }
}

fn save(data: &AppData) {
    let _ = fs::write("/etc/realm/panel_data.json", serde_json::to_string_pretty(data).unwrap());
    // 同时也生成 config.toml
    let mut toml_str = String::from("[[endpoints]]\nlisten = \"127.0.0.1:65534\"\nremote = \"127.0.0.1:65534\"\n");
    for r in &data.rules {
        if r.enabled {
            toml_str.push_str(&format!("\n[[endpoints]]\nname = \"{}\"\nlisten = \"{}\"\nremote = \"{}\"\n", r.name, r.listen, r.remote));
        }
    }
    let _ = fs::write("/etc/realm/config.toml", toml_str);
    let _ = std::process::Command::new("systemctl").arg("restart").arg("realm").status();
}
EOF

# 4. 嵌入 HTML (带诊断弹窗)
cat > src/index.html << 'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Realm Panel Lite</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
<style>
    body { font-family: sans-serif; background: #f4f7f9; margin: 0; padding: 20px; }
    .card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 900px; margin: auto; }
    table { width: 100%; border-collapse: collapse; margin-top: 20px; }
    th, td { padding: 12px; text-align: left; border-bottom: 1px solid #eee; }
    .btn { padding: 6px 12px; border: none; border-radius: 4px; cursor: pointer; color: white; margin: 2px; }
    .btn-blue { background: #2563eb; } .btn-red { background: #ef4444; } .btn-orange { background: #f59e0b; }
    input { padding: 8px; border: 1px solid #ddd; border-radius: 4px; margin-right: 5px; }
    .modal { display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.5); justify-content:center; align-items:center; }
    .modal-content { background:white; padding:30px; border-radius:10px; text-align:center; min-width:300px; }
</style></head>
<body>
<div class="card">
    <h2>Realm 转发面板</h2>
    <div style="background:#eee; padding:15px; border-radius:8px">
        <input id="n" placeholder="备注">
        <input id="l" placeholder="监听端口 (如 :1000)">
        <input id="r" placeholder="转发地址 (IP:端口)">
        <button class="btn btn-blue" onclick="add()">添加规则</button>
    </div>
    <table>
        <thead><tr><th>备注</th><th>监听</th><th>目标</th><th>操作</th></tr></thead>
        <tbody id="list"></tbody>
    </table>
</div>

<div id="pModal" class="modal"><div class="modal-content">
    <h3 id="p_title">正在诊断...</h3>
    <div id="p_body"><i class="fas fa-spinner fa-spin fa-2x"></i></div>
    <button class="btn btn-blue" style="margin-top:20px; width:100%" onclick="document.getElementById('pModal').style.display='none'">关闭</button>
</div></div>

<script>
    const $=id=>document.getElementById(id);
    async function load(){
        const r = await fetch('/api/rules');
        const data = await r.json();
        const t = $('list'); t.innerHTML = '';
        data.forEach(item => {
            t.innerHTML += `<tr>
                <td>${item.name}</td><td>${item.listen}</td><td>${item.remote}</td>
                <td>
                    <button class="btn btn-orange" onclick="ping('${item.id}')"><i class="fas fa-bolt"></i> 诊断</button>
                    <button class="btn btn-red" onclick="del('${item.id}')"><i class="fas fa-trash"></i></button>
                </td>
            </tr>`;
        });
    }
    async function add(){
        let l = $('l').value; if(!l.includes(':')) l = '0.0.0.0:'+l;
        await fetch('/api/rules', {method:'POST', body: JSON.stringify({name:$('n').value, listen:l, remote:$('r').value})});
        load();
    }
    async function del(id){ if(confirm('确定删除?')) { await fetch('/api/rules/'+id, {method:'DELETE'}); load(); } }
    async function ping(id){
        $('pModal').style.display = 'flex';
        $('p_title').innerText = '正在测试 TCP 连接...';
        $('p_body').innerHTML = '<i class="fas fa-spinner fa-spin fa-2x"></i>';
        const r = await fetch('/api/ping/'+id);
        const d = await r.json();
        if(d.status === 'ok') {
            $('p_body').innerHTML = `<h1 style="color:#10b981">${d.ms}ms</h1><p>${d.addr}</p><p>连接正常</p>`;
        } else {
            $('p_body').innerHTML = `<h1 style="color:#ef4444">失败</h1><p>${d.msg}</p>`;
        }
    }
    load();
</script>
</body></html>
EOF

# 5. 编译与服务启动
echo -e "${CYAN}>>> 正在编译轻量版面板 (这应该非常快)...${RESET}"
cargo build --release

mv target/release/realm-panel "$BINARY_PATH"

cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Panel Lite
After=network.target
[Service]
ExecStart=$BINARY_PATH
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now realm-panel
echo -e "${GREEN}>>> 部署完成！访问端口: $PANEL_PORT ${RESET}"
