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
echo -e "${GREEN}Realm 面板 (带实时延迟诊断版) 一键部署     ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 环境准备
if [ -f /etc/debian_version ]; then
    run_step "更新系统软件源" "apt-get update -y"
    run_step "安装系统基础依赖" "apt-get install -y curl wget tar build-essential pkg-config libssl-dev"
elif [ -f /etc/redhat-release ]; then
    run_step "安装开发工具包" "yum groupinstall -y 'Development Tools'"
    run_step "安装基础依赖" "yum install -y curl wget tar openssl-devel"
fi

if ! command -v cargo &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Rust 编译器 (约需 1-2 分钟)...${RESET}"
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
    else
        echo -e "${RED}不支持架构: $ARCH${RESET}"
        exit 1
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
version = "3.3.0"
edition = "2021"

[dependencies]
ax_auth = { version = "0.1", package = "axum" } # 适配版本用
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
use std::time::Instant;
use tokio::net::TcpStream;
use tokio::time::{timeout, Duration};

const REALM_CONFIG: &str = "/etc/realm/config.toml";
const DATA_FILE: &str = "/etc/realm/panel_data.json";

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule {
    id: String,
    name: String,
    listen: String,
    remote: String,
    enabled: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig {
    username: String,
    pass_hash: String,
    #[serde(default = "default_bg_pc")]
    bg_pc: String,
    #[serde(default = "default_bg_mobile")]
    bg_mobile: String,
}
fn default_bg_pc() -> String { "https://images.unsplash.com/photo-1451187580459-43490279c0fa?q=80&w=2072&auto=format&fit=crop".to_string() }
fn default_bg_mobile() -> String { "https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=1000&auto=format&fit=crop".to_string() }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData {
    admin: AdminConfig,
    rules: Vec<Rule>,
}

#[derive(Serialize)]
struct RealmEndpoint {
    name: String,
    listen: String,
    remote: String,
    #[serde(rename = "type")]
    r#type: String,
}
#[derive(Serialize)]
struct RealmConfig {
    endpoints: Vec<RealmEndpoint>,
}

struct AppState {
    data: Mutex<AppData>,
}

#[tokio::main]
async fn main() {
    let initial_data = load_or_init_data();
    let state = Arc::new(AppState {
        data: Mutex::new(initial_data),
    });

    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/rules/:id/ping", get(ping_rule))
        .route("/api/admin/account", post(update_account))
        .route("/api/admin/bg", post(update_bg))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new())
        .with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "4794".to_string());
    println!("Listening on 0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn load_or_init_data() -> AppData {
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(data) = serde_json::from_str::<AppData>(&content) {
            save_config_toml(&data); 
            return data;
        }
    }
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: std::env::var("PANEL_PASS").unwrap_or("123456".to_string()),
        bg_pc: default_bg_pc(),
        bg_mobile: default_bg_mobile(),
    };
    let data = AppData { admin, rules: Vec::new() };
    save_config_toml(&data); 
    save_json(&data);
    data
}

fn save_json(data: &AppData) {
    let json_str = serde_json::to_string_pretty(data).unwrap();
    let _ = fs::write(DATA_FILE, json_str);
}

fn save_config_toml(data: &AppData) {
    let mut endpoints: Vec<RealmEndpoint> = data.rules.iter()
        .filter(|r| r.enabled)
        .map(|r| RealmEndpoint {
            name: r.name.clone(),
            listen: r.listen.clone(),
            remote: r.remote.clone(),
            r#type: "tcp+udp".to_string(),
        })
        .collect();
    
    if endpoints.is_empty() {
        endpoints.push(RealmEndpoint {
            name: "keepalive".to_string(),
            listen: "127.0.0.1:65534".to_string(),
            remote: "127.0.0.1:65534".to_string(),
            r#type: "tcp+udp".to_string(),
        });
    }

    let config = RealmConfig { endpoints };
    let toml_str = toml::to_string(&config).unwrap();
    let _ = fs::write(REALM_CONFIG, toml_str);
    let _ = Command::new("systemctl").arg("restart").arg("realm").status();
}

fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") {
        return cookie.value() == state.admin.pass_hash;
    }
    false
}

// API: 延迟诊断
async fn ping_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    let target = data.rules.iter().find(|r| r.id == id).map(|r| r.remote.clone());
    
    if let Some(addr) = target {
        let start = Instant::now();
        match timeout(Duration::from_secs(3), TcpStream::connect(&addr)).await {
            Ok(Ok(_)) => {
                let duration = start.elapsed().as_millis();
                Json(serde_json::json!({"status":"ok", "ms": duration, "addr": addr})).into_response()
            }
            Ok(Err(e)) => {
                Json(serde_json::json!({"status":"error", "msg": format!("连接拒绝: {}", e), "addr": addr})).into_response()
            }
            Err(_) => {
                Json(serde_json::json!({"status":"error", "msg": "连接超时 (3s)", "addr": addr})).into_response()
            }
        }
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return axum::response::Redirect::to("/login").into_response(); }
    let html = DASHBOARD_HTML.replace("{{USER}}", &data.admin.username).replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
    Html(html).into_response()
}

async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    let html = LOGIN_HTML.replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
    Html(html).into_response()
}

#[derive(Deserialize)] struct LoginParams { username: String, password: String }
async fn login_action(cookies: Cookies, State(state): State<Arc<AppState>>, Form(form): Form<LoginParams>) -> Response {
    let data = state.data.lock().unwrap();
    if form.username == data.admin.username && form.password == data.admin.pass_hash {
        let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
        cookie.set_path("/"); cookie.set_http_only(true); cookies.add(cookie);
        axum::response::Redirect::to("/").into_response()
    } else {
        Html("<script>alert('错误');window.location='/login'</script>").into_response()
    }
}

async fn logout_action(cookies: Cookies) -> Response {
    cookies.remove(Cookie::new("auth_session", ""));
    axum::response::Redirect::to("/login").into_response()
}

async fn get_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Json(data.clone()).into_response()
}
#[derive(Deserialize)] struct AddRuleReq { name: String, listen: String, remote: String }
async fn add_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<AddRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, enabled: true });
    save_json(&data); save_config_toml(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn toggle_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) { rule.enabled = !rule.enabled; save_json(&data); save_config_toml(&data); }
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn delete_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.rules.retain(|r| r.id != id); save_json(&data); save_config_toml(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
#[derive(Deserialize)] struct UpdateRuleReq { name: String, listen: String, remote: String }
async fn update_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<UpdateRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) { rule.name = req.name; rule.listen = req.listen; rule.remote = req.remote; save_json(&data); save_config_toml(&data); }
    Json(serde_json::json!({"status":"ok"})).into_response()
}
#[derive(Deserialize)] struct AccountUpdate { username: String, password: String }
async fn update_account(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<AccountUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.admin.username = req.username;
    if !req.password.is_empty() { data.admin.pass_hash = req.password; }
    let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
    cookie.set_path("/"); cookies.add(cookie); save_json(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
#[derive(Deserialize)] struct BgUpdate { bg_pc: String, bg_mobile: String }
async fn update_bg(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<BgUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.admin.bg_pc = req.bg_pc; data.admin.bg_mobile = req.bg_mobile; save_json(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

const LOGIN_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;display:flex;justify-content:center;align-items:center;font-family:sans-serif;background:url('{{BG_PC}}') center/cover}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.box{background:rgba(255,255,255,0.9);padding:2rem;border-radius:12px;box-shadow:0 8px 32px rgba(0,0,0,0.2);width:320px;text-align:center}input{width:100%;padding:10px;margin:10px 0;border:1px solid #ddd;border-radius:6px}button{width:100%;padding:10px;background:#2563eb;color:white;border:none;border-radius:6px;cursor:pointer}</style></head><body><div class="box"><h2>Realm Panel</h2><form action="/login" method="post"><input name="username" placeholder="User"><input type="password" name="password" placeholder="Pass"><button>Login</button></form></div></body></html>
"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>Realm Panel</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>:root{--primary:#2563eb;--danger:#ef4444;--success:#10b981;--bg:#f3f4f6}*{box-sizing:border-box}body{font-family:sans-serif;margin:0;background:url('{{BG_PC}}') center/cover fixed;height:100vh;display:flex;flex-direction:column}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.overlay{position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(243,244,246,0.85);z-index:-1}.navbar{background:white;padding:1rem;display:flex;justify-content:space-between;box-shadow:0 2px 8px rgba(0,0,0,0.1)}.container{max-width:1000px;margin:1rem auto;width:95%;flex:1;overflow-y:auto}.card{background:white;padding:1rem;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,0.05);margin-bottom:1rem}table{width:100%;border-collapse:collapse}th,td{padding:12px;text-align:left;border-bottom:1px solid #eee}.btn{padding:8px 12px;border-radius:6px;border:none;cursor:pointer;color:white;margin-left:4px}.btn-primary{background:var(--primary)}.btn-danger{background:var(--danger)}.btn-gray{background:#6b7280}.btn-bolt{background:#f59e0b}input{padding:8px;border:1px solid #ddd;border-radius:6px}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:100;justify-content:center;align-items:center}.modal-box{background:white;padding:2rem;border-radius:12px;width:90%;max-width:400px;text-align:center}.status-dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px}@media(max-width:768px){thead{display:none}tr{display:block;border:1px solid #eee;margin-bottom:10px;padding:10px}td{display:flex;justify-content:space-between;border:none}}</style></head><body><div class="overlay"></div><div class="navbar"><strong>Realm Panel</strong><div><button class="btn btn-gray" onclick="openSet()"><i class="fas fa-cog"></i></button><form action="/logout" method="post" style="display:inline"><button class="btn btn-danger"><i class="fas fa-sign-out-alt"></i></button></form></div></div><div class="container"><div class="card"><div style="display:grid;grid-template-columns:1fr 1fr 1fr auto;gap:10px"><input id="n" placeholder="备注"><input id="l" placeholder="监听端口"><input id="r" placeholder="目标地址"><button class="btn btn-primary" onclick="add()">添加</button></div></div><div class="card"><table><thead><tr><th>状态</th><th>备注</th><th>监听</th><th>目标</th><th>操作</th></tr></thead><tbody id="list"></tbody></table></div></div>
<div id="pingModal" class="modal"><div class="modal-box"><h3>网络诊断</h3><div id="ping_loading" style="margin:20px 0"><i class="fas fa-spinner fa-spin fa-2x"></i><p>检测中...</p></div><div id="ping_res" style="display:none"><div id="p_icon"></div><h2 id="p_ms"></h2><p id="p_addr" style="font-size:0.8rem;color:#888"></p><p id="p_msg"></p></div><button class="btn btn-primary" style="width:100%;margin-top:20px" onclick="closeModal()">关闭</button></div></div>
<div id="editModal" class="modal"><div class="modal-box"><h3>修改规则</h3><input type="hidden" id="e_id"><input id="e_n" style="width:100%;margin:5px 0"><input id="e_l" style="width:100%;margin:5px 0"><input id="e_r" style="width:100%;margin:5px 0"><button class="btn btn-primary" onclick="saveEdit()">保存</button><button class="btn btn-gray" onclick="closeModal()">取消</button></div></div>
<div id="setModal" class="modal"><div class="modal-box"><h3>面板设置</h3><input id="s_u" placeholder="用户名" style="width:100%;margin:5px 0"><input id="s_p" type="password" placeholder="新密码" style="width:100%;margin:5px 0"><button class="btn btn-primary" onclick="saveSet()">保存</button><button class="btn btn-gray" onclick="closeModal()">取消</button></div></div>
<script>
let rules=[]; const $=id=>document.getElementById(id);
async function load(){ const r=await fetch('/api/rules'); if(r.status===401)location.href='/login'; const d=await r.json(); rules=d.rules; render() }
function render(){ const t=$('list'); t.innerHTML=''; rules.forEach(r=>{ const row=document.createElement('tr'); row.innerHTML=`<td><span class="status-dot" style="background:${r.enabled?'#10b981':'#ccc'}"></span>${r.enabled?'运行':'停止'}</td><td>${r.name}</td><td>${r.listen}</td><td>${r.remote}</td><td><button class="btn btn-bolt" onclick="runPing('${r.id}')"><i class="fas fa-bolt"></i></button><button class="btn btn-primary" onclick="openEdit('${r.id}')"><i class="fas fa-edit"></i></button><button class="btn btn-danger" onclick="del('${r.id}')"><i class="fas fa-trash"></i></button></td>`; t.appendChild(row) })}
async function add(){ let [n,l,r]=['n','l','r'].map(x=>$(x).value); if(!l.includes(':'))l='0.0.0.0:'+l; await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r})}); load() }
async function del(id){ if(confirm('删除?')) await fetch(`/api/rules/${id}`,{method:'DELETE'}); load() }
function openEdit(id){ const r=rules.find(x=>x.id===id); $('e_id').value=id; $('e_n').value=r.name; $('e_l').value=r.listen; $('e_r').value=r.remote; $('editModal').style.display='flex' }
async function saveEdit(){ const b=JSON.stringify({name:$('e_n').value,listen:$('e_l').value,remote:$('e_r').value}); await fetch(`/api/rules/${$('e_id').value}`,{method:'PUT',headers:{'Content-Type':'application/json'},body:b}); closeModal(); load() }
function openSet(){ $('setModal').style.display='flex' }
async function saveSet(){ await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('s_u').value,password:$('s_p').value})}); location.reload() }
function closeModal(){ document.querySelectorAll('.modal').forEach(m=>m.style.display='none') }
async function runPing(id){ 
    $('pingModal').style.display='flex'; $('ping_loading').style.display='block'; $('ping_res').style.display='none';
    try {
        const r=await fetch(`/api/rules/${id}/ping`); const d=await r.json();
        $('ping_loading').style.display='none'; $('ping_res').style.display='block';
        $('p_addr').innerText=d.addr;
        if(d.status==='ok'){
            $('p_icon').innerHTML='<i class="fas fa-check-circle fa-3x" style="color:var(--success)"></i>';
            $('p_ms').innerText=d.ms+' ms'; $('p_msg').innerText='连接正常';
        } else {
            $('p_icon').innerHTML='<i class="fas fa-times-circle fa-3x" style="color:var(--danger)"></i>';
            $('p_ms').innerText='失败'; $('p_msg').innerText=d.msg;
        }
    } catch(e){ alert('请求失败'); closeModal() }
}
load();
</script></body></html>
"#;
EOF

# 4. 编译安装
echo -e -n "${CYAN}>>> 编译面板程序 (约 1-3 分钟)...${RESET}"
cargo build --release >/dev/null 2>&1 &
spinner $!

if [ -f "target/release/realm-panel" ]; then
    echo -e "${GREEN} [完成]${RESET}"
    echo -e -n "${CYAN}>>> 安装与配置服务...${RESET}"
    mv target/release/realm-panel "$BINARY_PATH"
else
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}编译出错，请检查内存是否充足。${RESET}"
    exit 1
fi

rm -rf "$WORK_DIR"

cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Panel
After=network.target

[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
ExecStart=$BINARY_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl start realm >/dev/null 2>&1
systemctl enable realm-panel >/dev/null 2>&1
systemctl restart realm-panel >/dev/null 2>&1
echo -e "${GREEN} [完成]${RESET}"

IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ 部署完成！(已内置实时诊断功能)${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"
echo -e "点击规则旁的 ⚡ 图标即可进行延迟测试。"
