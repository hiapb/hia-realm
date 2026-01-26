#!/bin/bash

# --- 配置 ---
PANEL_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径 ---
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG="/etc/realm/config.toml"
WORK_DIR="/opt/realm_panel"
BINARY_PATH="/usr/local/bin/realm-panel"
DATA_FILE="/etc/realm/panel_data.json"

# --- 颜色与动画 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    echo -n " "
    while [ -d /proc/$pid ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_step() {
    echo -e -n "${CYAN}>>> $1...${RESET}"
    eval "$2" >/dev/null 2>&1 &
    spinner $!
    echo -e "${GREEN} [完成]${RESET}"
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行！${RESET}"
    exit 1
fi

clear
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}Realm 面板 (移动端 UI 极致优化版)   ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 环境准备
if [ -f /etc/debian_version ]; then
    run_step "更新系统软件源" "apt-get update -y"
    run_step "安装系统基础依赖" "apt-get install -y curl wget tar build-essential pkg-config libssl-dev"
fi

if ! command -v cargo &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Rust 编译器...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
    spinner $!
    echo -e "${GREEN} [完成]${RESET}"
    source "$HOME/.cargo/env"
fi

# 2. Realm 主程序
if [ ! -f "$REALM_BIN" ]; then
    echo -e -n "${CYAN}>>> 下载并安装 Realm 主程序...${RESET}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    fi
    mkdir -p /tmp/realm_tmp
    (
        wget -O /tmp/realm_tmp/realm.tar.gz "$URL" -q
        tar -xvf /tmp/realm_tmp/realm.tar.gz -C /tmp/realm_tmp
        mv /tmp/realm_tmp/realm "$REALM_BIN"
        chmod +x "$REALM_BIN"
    ) >/dev/null 2>&1 &
    spinner $!
    rm -rf /tmp/realm_tmp
    echo -e "${GREEN} [完成]${RESET}"
fi
mkdir -p "$(dirname "$REALM_CONFIG")"

# 3. 生成代码
run_step "生成 Rust 源代码" "
rm -rf '$WORK_DIR'
mkdir -p '$WORK_DIR/src'
"
cd "$WORK_DIR"

cat > Cargo.toml <<EOF
[package]
name = "realm-panel"
version = "3.2.5"
edition = "2021"

[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
tower-cookies = "0.10"
anyhow = "1.0"
uuid = { version = "1", features = ["v4"] }
EOF

cat > src/main.rs << 'EOF'
use axum::{
    extract::{State, Path},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router, Form,
};
use serde::{Deserialize, Serialize};
use std::{fs, process::Command, sync::{Arc, Mutex}, path::Path as FilePath};
use tower_cookies::{Cookie, Cookies, CookieManagerLayer};

const DATA_FILE: &str = "/etc/realm/panel_data.json";
const REALM_CONFIG: &str = "/etc/realm/config.toml";

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule { id: String, name: String, listen: String, remote: String, enabled: bool }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig {
    username: String, pass_hash: String,
    #[serde(default = "default_bg_pc")] bg_pc: String,
    #[serde(default = "default_bg_mobile")] bg_mobile: String,
}
fn default_bg_pc() -> String { "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string() }
fn default_bg_mobile() -> String { "https://img.inim.im/file/1764296937373_bg_m_2.png".to_string() }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData { admin: AdminConfig, rules: Vec<Rule> }

struct AppState { data: Mutex<AppData> }

#[tokio::main]
async fn main() {
    let initial_data = load_or_init_data();
    let state = Arc::new(AppState { data: Mutex::new(initial_data) });
    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/admin/account", post(update_account))
        .route("/api/admin/bg", post(update_bg))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new()).with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or("4794".into());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn load_or_init_data() -> AppData {
    if let Ok(c) = fs::read_to_string(DATA_FILE) {
        if let Ok(d) = serde_json::from_str::<AppData>(&c) { return d; }
    }
    AppData {
        admin: AdminConfig { username: "admin".into(), pass_hash: "123456".into(), bg_pc: default_bg_pc(), bg_mobile: default_bg_mobile() },
        rules: vec![]
    }
}

fn save_all(data: &AppData) {
    let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(data).unwrap());
    let mut endpoints = String::from("[[endpoints]]\nlisten = \"127.0.0.1:65534\"\nremote = \"127.0.0.1:65534\"\n");
    for r in data.rules.iter().filter(|r| r.enabled) {
        endpoints.push_str(&format!("\n[[endpoints]]\nlisten = \"{}\"\nremote = \"{}\"\n", r.listen, r.remote));
    }
    let _ = fs::write(REALM_CONFIG, endpoints);
    let _ = Command::new("systemctl").arg("restart").arg("realm").status();
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if cookies.get("auth_session").map(|c| c.value() == data.admin.pass_hash).unwrap_or(false) {
        let html = DASHBOARD_HTML.replace("{{USER}}", &data.admin.username).replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
        Html(html).into_response()
    } else { axum::response::Redirect::to("/login").into_response() }
}
async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    Html(LOGIN_HTML.replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile)).into_response()
}
#[derive(Deserialize)] struct LoginParams { username: String, password: String }
async fn login_action(cookies: Cookies, State(state): State<Arc<AppState>>, Form(f): Form<LoginParams>) -> Response {
    let data = state.data.lock().unwrap();
    if f.username == data.admin.username && f.password == data.admin.pass_hash {
        let mut c = Cookie::new("auth_session", data.admin.pass_hash.clone()); c.set_path("/"); cookies.add(c);
        axum::response::Redirect::to("/").into_response()
    } else { Html("<script>alert('Error');location.href='/login'</script>").into_response() }
}
async fn logout_action(cookies: Cookies) -> Response { cookies.remove(Cookie::new("auth_session", "")); axum::response::Redirect::to("/login").into_response() }
async fn get_rules(State(state): State<Arc<AppState>>) -> Json<AppData> { Json(state.data.lock().unwrap().clone()) }
async fn add_rule(State(state): State<Arc<AppState>>, Json(r): Json<Rule>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    let mut new_r = r; new_r.id = uuid::Uuid::new_v4().to_string(); new_r.enabled = true;
    data.rules.push(new_r); save_all(&data); StatusCode::OK
}
async fn toggle_rule(State(state): State<Arc<AppState>>, Path(id): Path<String>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    if let Some(r) = data.rules.iter_mut().find(|x| x.id == id) { r.enabled = !r.enabled; save_all(&data); }
    StatusCode::OK
}
async fn delete_rule(State(state): State<Arc<AppState>>, Path(id): Path<String>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    data.rules.retain(|x| x.id != id); save_all(&data); StatusCode::OK
}
async fn update_rule(State(state): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<Rule>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    if let Some(r) = data.rules.iter_mut().find(|x| x.id == id) { r.name = req.name; r.listen = req.listen; r.remote = req.remote; save_all(&data); }
    StatusCode::OK
}
#[derive(Deserialize)] struct AccReq { username: String, password: String }
async fn update_account(State(state): State<Arc<AppState>>, Json(r): Json<AccReq>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    data.admin.username = r.username; if !r.password.is_empty() { data.admin.pass_hash = r.password; }
    let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(&*data).unwrap()); StatusCode::OK
}
#[derive(Deserialize)] struct BgReq { bg_pc: String, bg_mobile: String }
async fn update_bg(State(state): State<Arc<AppState>>, Json(r): Json<BgReq>) -> StatusCode {
    let mut data = state.data.lock().unwrap();
    data.admin.bg_pc = r.bg_pc; data.admin.bg_mobile = r.bg_mobile;
    let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(&*data).unwrap()); StatusCode::OK
}

const LOGIN_HTML: &str = r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:sans-serif;background:url('{{BG_PC}}') center/cover}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.box{background:rgba(255,255,255,0.4);backdrop-filter:blur(20px);padding:2.5rem;border-radius:24px;width:300px;text-align:center;box-shadow:0 8px 32px rgba(0,0,0,0.1)}input{width:100%;padding:12px;margin:10px 0;border-radius:12px;border:none;outline:none;background:rgba(255,255,255,0.5)}button{width:100%;padding:12px;border-radius:12px;border:none;background:#3b82f6;color:white;cursor:pointer;margin-top:10px}</style></head><body><div class="box"><h3>Realm Panel</h3><form action="/login" method="post"><input name="username" placeholder="User"><input name="password" type="password" placeholder="Pass"><button>Login</button></form></div></body></html>"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Realm</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>
:root{--text:#374151;--bg-card:rgba(255,255,255,0.35)}
body{margin:0;font-family:-apple-system,sans-serif;background:url('{{BG_PC}}') no-repeat center center/cover;height:100vh;overflow:hidden;color:var(--text)}
@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}
.navbar{display:flex;justify-content:space-between;align-items:center;padding:15px 25px;background:rgba(255,255,255,0.2);backdrop-filter:blur(20px);border-bottom:1px solid rgba(255,255,255,0.3)}
.container{max-width:1000px;margin:20px auto;height:calc(100vh - 100px);display:flex;flex-direction:column;padding:0 15px}
.card{background:var(--bg-card);backdrop-filter:blur(25px);border:1px solid rgba(255,255,255,0.4);border-radius:20px;padding:20px;margin-bottom:20px;box-shadow:0 4px 15px rgba(0,0,0,0.03)}
.rules-container{flex:1;overflow-y:auto;padding-bottom:20px}
.rule-item{background:rgba(255,255,255,0.45);border-radius:18px;margin-bottom:12px;padding:16px;border:1px solid rgba(255,255,255,0.3);transition:0.3s;display:grid;grid-template-columns:1fr 1.5fr 1.5fr auto;align-items:center;gap:15px}
.rule-item:hover{transform:translateY(-2px);background:rgba(255,255,255,0.6)}
.status-tag{display:inline-flex;align-items:center;gap:6px;font-size:0.85rem;font-weight:600}
.dot{width:8px;height:8px;border-radius:50%}
.dot-online{background:#10b981;box-shadow:0 0 8px #10b981}
.dot-offline{background:#9ca3af}
.actions{display:flex;gap:8px}
.btn{border:none;padding:8px 12px;border-radius:10px;cursor:pointer;transition:0.2s;display:flex;align-items:center;gap:5px;font-size:0.9rem}
.btn-p{background:#3b82f6;color:white}.btn-d{background:#fee2e2;color:#ef4444}.btn-g{background:rgba(0,0,0,0.05);color:var(--text)}
.grid-add{display:grid;grid-template-columns:1fr 1fr 1.5fr auto;gap:12px}
input{padding:10px 14px;border-radius:12px;border:1px solid rgba(0,0,0,0.05);background:rgba(255,255,255,0.5);outline:none;color:var(--text);font-weight:500}
@media(max-width:768px){
    .grid-add{grid-template-columns:1fr}
    .rule-item{grid-template-columns:1fr;gap:10px;padding:18px;border-radius:22px}
    .mobile-row{display:flex;justify-content:space-between;align-items:center;font-size:0.9rem}
    .mobile-label{color:#9ca3af;font-size:0.8rem}
    .rule-item .actions{justify-content:center;margin-top:10px;padding-top:12px;border-top:1px solid rgba(0,0,0,0.03);width:100%}
    .rule-item .actions .btn{flex:1;justify-content:center;padding:10px}
}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.1);backdrop-filter:blur(10px);z-index:100;align-items:center;justify-content:center}
.modal-content{background:rgba(255,255,255,0.9);padding:30px;border-radius:24px;width:90%;max-width:400px}
</style></head><body>
<div class="navbar"><strong>Realm Panel</strong><div class="actions"><button class="btn btn-g" onclick="openSet()"><i class="fa fa-cog"></i></button><button class="btn btn-d" onclick="location.href='/logout'"><i class="fa fa-power-off"></i></button></div></div>
<div class="container">
    <div class="card grid-add"><input id="n" placeholder="备注"><input id="l" placeholder="监听端口"><input id="r" placeholder="落地地址"><button class="btn btn-p" onclick="add()"><i class="fa fa-plus"></i> 添加</button></div>
    <div class="rules-container" id="list"></div>
</div>
<div id="mSet" class="modal"><div class="modal-content"><h4>设置</h4><label>用户</label><input id="su" style="width:100%"><br><label>密码</label><input id="sp" type="password" style="width:100%"><br><br><button class="btn btn-p" style="width:100%" onclick="saveAcc()">保存</button><br><button class="btn btn-g" style="width:100%" onclick="closeModal()">取消</button></div></div>
<div id="mEdit" class="modal"><div class="modal-content"><h4>编辑</h4><input id="en"><input id="el"><input id="er"><br><br><button class="btn btn-p" style="width:100%" onclick="saveEdit()">更新</button></div></div>
<script>
let rules=[]; let editId='';
async function load(){
    const r=await fetch('/api/rules'); const d=await r.json(); rules=d.rules;
    const list=$('list'); list.innerHTML='';
    rules.forEach(x=>{
        const div=document.createElement('div'); div.className='rule-item';
        const isMob=window.innerWidth<768;
        if(isMob){
            div.innerHTML=`
                <div class="mobile-row"><span class="mobile-label">备注</span><strong>${x.name}</strong></div>
                <div class="mobile-row"><span class="mobile-label">状态</span><span class="status-tag"><div class="dot ${x.enabled?'dot-online':'dot-offline'}"></div>${x.enabled?'在线':'暂停'}</span></div>
                <div class="mobile-row"><span class="mobile-label">监听</span>${x.listen}</div>
                <div class="mobile-row"><span class="mobile-label">落地</span>${x.remote}</div>
                <div class="actions">
                    <button class="btn btn-g" onclick="tog('${x.id}')"><i class="fa ${x.enabled?'fa-pause':'fa-play'}"></i> 切换</button>
                    <button class="btn btn-p" onclick="openEdit('${x.id}')"><i class="fa fa-edit"></i> 编辑</button>
                    <button class="btn btn-d" onclick="del('${x.id}')"><i class="fa fa-trash"></i></button>
                </div>`;
        }else{
            div.innerHTML=`
                <span class="status-tag"><div class="dot ${x.enabled?'dot-online':'dot-offline'}"></div>${x.enabled?'在线':'暂停'}</span>
                <span><strong>${x.name}</strong></span>
                <span>${x.listen}</span>
                <span>${x.remote}</span>
                <div class="actions">
                    <button class="btn btn-g" onclick="tog('${x.id}')"><i class="fa ${x.enabled?'fa-pause':'fa-play'}"></i></button>
                    <button class="btn btn-p" onclick="openEdit('${x.id}')"><i class="fa fa-edit"></i></button>
                    <button class="btn btn-d" onclick="del('${x.id}')"><i class="fa fa-trash"></i></button>
                </div>`;
        }
        list.appendChild(div);
    });
}
const $=i=>document.getElementById(i);
async function add(){ 
    const l=$('l').value;
    await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:$('n').value,listen:l.includes(':')?l:'0.0.0.0:'+l,remote:$('r').value})});
    load();
}
async function tog(id){ await fetch(`/api/rules/${id}/toggle`,{method:'POST'}); load();}
async function del(id){ if(confirm('Del?')){await fetch(`/api/rules/${id}`,{method:'DELETE'}); load();}}
function openEdit(id){ const x=rules.find(i=>i.id===id); editId=id; $('en').value=x.name; $('el').value=x.listen; $('er').value=x.remote; $('mEdit').style.display='flex'; }
async function saveEdit(){ await fetch(`/api/rules/${editId}`,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:$('en').value,listen:$('el').value,remote:$('er').value})}); closeModal(); load(); }
function openSet(){ $('mSet').style.display='flex'; }
function closeModal(){ document.querySelectorAll('.modal').forEach(m=>m.style.display='none'); }
async function saveAcc(){ await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('su').value,password:$('sp').value})}); alert('OK'); location.reload(); }
window.onclick=e=>{if(e.target.className==='modal')closeModal();};
load();
</script></body></html>
"#;
EOF

# 4. 编译与服务启动
run_step "编译程序" "cargo build --release"
mv target/release/realm-panel "$BINARY_PATH"
rm -rf "$WORK_DIR"

cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Panel
After=network.target

[Service]
Environment="PANEL_PORT=$PANEL_PORT"
ExecStart=$BINARY_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm-panel >/dev/null 2>&1
systemctl restart realm-panel >/dev/null 2>&1

IP=$(curl -s4 ifconfig.me)
echo -e "\n${GREEN}✅ 部署完成！访问地址: http://${IP}:${PANEL_PORT}${RESET}"
