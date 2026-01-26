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
echo -e "${GREEN}Realm 面板 (完美重构版: 全功能+新UI)   ${RESET}"
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
    echo -e -n "${CYAN}>>> 安装 Rust 编译器...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
    spinner $!
    echo -e "${GREEN} [完成]${RESET}"
    source "$HOME/.cargo/env"
fi

# 2. Realm 主程序 (保留你的所有逻辑)
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

# 3. 生成代码 (逻辑完全恢复)
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
fn default_bg_pc() -> String { "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string() }
fn default_bg_mobile() -> String { "https://img.inim.im/file/1764296937373_bg_m_2.png".to_string() }

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
        .route("/api/admin/account", post(update_account))
        .route("/api/admin/bg", post(update_bg))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new())
        .with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "4794".to_string());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

// 核心逻辑：恢复了导入 config.toml 的功能
fn load_or_init_data() -> AppData {
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(data) = serde_json::from_str::<AppData>(&content) {
            save_config_toml(&data); // 启动时强制同步一次
            return data;
        }
    }
    // 如果没有 JSON，尝试从 REALM_CONFIG 导入 (逻辑一个不少)
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: std::env::var("PANEL_PASS").unwrap_or("123456".to_string()),
        bg_pc: default_bg_pc(),
        bg_mobile: default_bg_mobile(),
    };
    let mut rules = Vec::new();
    if FilePath::new(REALM_CONFIG).exists() {
        if let Ok(content) = fs::read_to_string(REALM_CONFIG) {
            if let Ok(toml_val) = content.parse::<toml::Value>() {
                 if let Some(endpoints) = toml_val.get("endpoints").and_then(|v| v.as_array()) {
                     for ep in endpoints {
                         let name = ep.get("name").and_then(|v| v.as_str()).unwrap_or("Imported").to_string();
                         let listen = ep.get("listen").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         let remote = ep.get("remote").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         if !listen.is_empty() && !remote.is_empty() && name != "system-keepalive" {
                             rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name, listen, remote, enabled: true });
                         }
                     }
                 }
            }
        }
    }
    let data = AppData { admin, rules };
    save_config_toml(&data); 
    save_json(&data);
    data
}

fn save_json(data: &AppData) {
    let json_str = serde_json::to_string_pretty(data).unwrap();
    let _ = fs::write(DATA_FILE, json_str);
}

// 核心逻辑：恢复了 system-keepalive 和自动重启 realm
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
    
    // 防止 realm 空配置报错，增加保活规则
    if endpoints.is_empty() {
        endpoints.push(RealmEndpoint {
            name: "system-keepalive".to_string(),
            listen: "127.0.0.1:65534".to_string(),
            remote: "127.0.0.1:65534".to_string(),
            r#type: "tcp+udp".to_string(),
        });
    }

    let config = RealmConfig { endpoints };
    let toml_str = toml::to_string(&config).unwrap();
    let _ = fs::write(REALM_CONFIG, toml_str);
    // 重启服务逻辑
    let _ = Command::new("systemctl").arg("restart").arg("realm").status();
}

fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") {
        return cookie.value() == state.admin.pass_hash;
    }
    false
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return axum::response::Redirect::to("/login").into_response(); }
    let html = DASHBOARD_HTML
        .replace("{{USER}}", &data.admin.username)
        .replace("{{BG_PC}}", &data.admin.bg_pc)
        .replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
    Html(html).into_response()
}

async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    let html = LOGIN_HTML
        .replace("{{BG_PC}}", &data.admin.bg_pc)
        .replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
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
        Html("<script>alert('用户名或密码错误');window.location='/login'</script>").into_response()
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
    save_json(&data);
    let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
    cookie.set_path("/"); cookies.add(cookie);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
#[derive(Deserialize)] struct BgUpdate { bg_pc: String, bg_mobile: String }
async fn update_bg(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<BgUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.admin.bg_pc = req.bg_pc; data.admin.bg_mobile = req.bg_mobile; save_json(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

const LOGIN_HTML: &str = r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:sans-serif;background:url('{{BG_PC}}') center/cover}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.box{background:rgba(255,255,255,0.4);backdrop-filter:blur(20px);padding:2.5rem;border-radius:24px;width:300px;text-align:center;box-shadow:0 8px 32px rgba(0,0,0,0.1)}input{width:100%;padding:12px;margin:10px 0;border-radius:12px;border:none;outline:none;background:rgba(255,255,255,0.5)}button{width:100%;padding:12px;border-radius:12px;border:none;background:#3b82f6;color:white;cursor:pointer;margin-top:10px}</style></head><body><div class="box"><h3>Realm Panel</h3><form action="/login" method="post"><input name="username" placeholder="User"><input name="password" type="password" placeholder="Pass"><button>Login</button></form></div></body></html>"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Realm</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>
:root{--text:#374151;--bg-card:rgba(255,255,255,0.35)}
body{margin:0;font-family:-apple-system,sans-serif;background:url('{{BG_PC}}') no-repeat center center/cover;height:100vh;overflow:hidden;color:var(--text)}
@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}
.navbar{display:flex;justify-content:space-between;align-items:center;padding:15px 25px;background:rgba(255,255,255,0.25);backdrop-filter:blur(20px);border-bottom:1px solid rgba(255,255,255,0.3)}
.container{max-width:1100px;margin:20px auto;height:calc(100vh - 120px);display:flex;flex-direction:column;padding:0 15px}
.card{background:var(--bg-card);backdrop-filter:blur(25px);border:1px solid rgba(255,255,255,0.4);border-radius:24px;padding:20px;margin-bottom:20px;box-shadow:0 4px 15px rgba(0,0,0,0.03)}
.rules-container{flex:1;overflow-y:auto;padding-bottom:20px}
/* 核心修改：div 布局实现真正的四方圆角 */
.rule-item{background:rgba(255,255,255,0.45);border-radius:20px;margin-bottom:12px;padding:16px;border:1px solid rgba(255,255,255,0.3);transition:0.3s;display:grid;grid-template-columns:1fr 1.5fr 1.5fr 2fr auto;align-items:center;gap:15px;box-shadow:0 2px 8px rgba(0,0,0,0.02)}
.rule-item:hover{transform:translateY(-2px);background:rgba(255,255,255,0.6);box-shadow:0 6px 15px rgba(0,0,0,0.05)}
.status-tag{display:inline-flex;align-items:center;gap:8px;font-size:0.9rem;font-weight:600}
.dot{width:8px;height:8px;border-radius:50%}
.dot-online{background:#10b981;box-shadow:0 0 8px #10b981}
.dot-offline{background:#9ca3af}
.actions{display:flex;gap:8px}
.btn{border:none;padding:8px 12px;border-radius:12px;cursor:pointer;transition:0.2s;display:flex;align-items:center;gap:5px;font-size:0.9rem;font-weight:500}
.btn-p{background:#3b82f6;color:white}.btn-d{background:#fee2e2;color:#ef4444}.btn-g{background:rgba(255,255,255,0.5);color:var(--text);border:1px solid rgba(0,0,0,0.05)}
.grid-add{display:grid;grid-template-columns:1fr 1fr 1.5fr auto;gap:12px}
input{padding:12px 16px;border-radius:14px;border:1px solid rgba(0,0,0,0.05);background:rgba(255,255,255,0.5);outline:none;color:var(--text);font-weight:500;transition:0.3s}
input:focus{background:white;border-color:#3b82f6}
@media(max-width:768px){
    .grid-add{grid-template-columns:1fr}
    .rule-item{grid-template-columns:1fr;gap:12px;padding:20px;border-radius:24px}
    .mobile-row{display:flex;justify-content:space-between;align-items:center;font-size:0.95rem}
    .mobile-label{color:#9ca3af;font-size:0.85rem;font-weight:normal}
    /* 移动端操作按钮重组：横向撑满整齐排列 */
    .rule-item .actions{justify-content:center;margin-top:10px;padding-top:15px;border-top:1px solid rgba(0,0,0,0.05);width:100%;gap:10px}
    .rule-item .actions .btn{flex:1;justify-content:center;padding:12px;border-radius:14px}
}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.1);backdrop-filter:blur(15px);z-index:100;align-items:center;justify-content:center}
.modal-content{background:rgba(255,255,255,0.9);padding:30px;border-radius:28px;width:90%;max-width:400px;box-shadow:0 20px 50px rgba(0,0,0,0.1)}
</style></head><body>
<div class="navbar"><strong><i class="fa fa-paper-plane"></i> Realm Panel</strong><div class="actions"><button class="btn btn-g" onclick="openSet()"><i class="fa fa-cog"></i></button><button class="btn btn-d" onclick="location.href='/logout'"><i class="fa fa-power-off"></i></button></div></div>
<div class="container">
    <div class="card grid-add"><input id="n" placeholder="备注名称"><input id="l" placeholder="监听端口"><input id="r" placeholder="落地地址"><button class="btn btn-p" onclick="add()"><i class="fa fa-plus"></i> 添加规则</button></div>
    <div class="rules-container" id="list"></div>
</div>
<div id="mSet" class="modal"><div class="modal-content"><h3><i class="fa fa-user-shield"></i> 面板设置</h3><label>管理账户</label><input id="su" placeholder="用户名" style="width:100%;margin-bottom:10px"><br><label>面板密码</label><input id="sp" type="password" placeholder="不改请留空" style="width:100%"><br><br><div class="actions"><button class="btn btn-g" style="flex:1" onclick="closeModal()">取消</button><button class="btn btn-p" style="flex:1" onclick="saveAcc()">保存更改</button></div></div></div>
<div id="mEdit" class="modal"><div class="modal-content"><h3><i class="fa fa-edit"></i> 修改规则</h3><label>备注</label><input id="en" style="width:100%;margin-bottom:10px"><label>监听</label><input id="el" style="width:100%;margin-bottom:10px"><label>落地</label><input id="er" style="width:100%"><br><br><div class="actions"><button class="btn btn-g" style="flex:1" onclick="closeModal()">取消</button><button class="btn btn-p" style="flex:1" onclick="saveEdit()">保存更新</button></div></div></div>
<script>
let rules=[]; let editId='';
const $=i=>document.getElementById(i);
async function load(){
    const r=await fetch('/api/rules'); if(r.status===401){location.href='/login';return;}
    const d=await r.json(); rules=d.rules;
    const list=$('list'); list.innerHTML='';
    rules.forEach(x=>{
        const div=document.createElement('div'); div.className='rule-item';
        if(!x.enabled) div.style.opacity='0.6';
        const isMob=window.innerWidth<768;
        if(isMob){
            div.innerHTML=`
                <div class="mobile-row"><span class="mobile-label">备注</span><strong>${x.name}</strong></div>
                <div class="mobile-row"><span class="mobile-label">状态</span><span class="status-tag"><div class="dot ${x.enabled?'dot-online':'dot-offline'}"></div>${x.enabled?'在线运行':'暂停服务'}</span></div>
                <div class="mobile-row"><span class="mobile-label">监听</span>${x.listen}</div>
                <div class="mobile-row"><span class="mobile-label">落地</span>${x.remote}</div>
                <div class="actions">
                    <button class="btn btn-g" onclick="tog('${x.id}')"><i class="fa ${x.enabled?'fa-pause':'fa-play'}"></i> ${x.enabled?'暂停':'开启'}</button>
                    <button class="btn btn-p" onclick="openEdit('${x.id}')"><i class="fa fa-pen"></i> 编辑</button>
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
                    <button class="btn btn-d" onclick="del('${x.id}')"><i class="fa fa-trash-alt"></i></button>
                </div>`;
        }
        list.appendChild(div);
    });
}
async function add(){ 
    let n=$('n').value, l=$('l').value, r=$('r').value; if(!n||!l||!r)return;
    if(!l.includes(':')) l='0.0.0.0:'+l;
    await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:'',name:n,listen:l,remote:r,enabled:true})});
    $('n').value='';$('l').value='';$('r').value=''; load();
}
async function tog(id){ await fetch(`/api/rules/${id}/toggle`,{method:'POST'}); load();}
async function del(id){ if(confirm('确定删除?')){await fetch(`/api/rules/${id}`,{method:'DELETE'}); load();}}
function openEdit(id){ const x=rules.find(i=>i.id===id); editId=id; $('en').value=x.name; $('el').value=x.listen; $('er').value=x.remote; $('mEdit').style.display='flex'; }
async function saveEdit(){ await fetch(`/api/rules/${editId}`,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:editId,name:$('en').value,listen:$('el').value,remote:$('er').value,enabled:true})}); closeModal(); load(); }
function openSet(){ $('mSet').style.display='flex'; }
function closeModal(){ document.querySelectorAll('.modal').forEach(m=>m.style.display='none'); }
async function saveAcc(){ await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('su').value,password:$('sp').value})}); alert('账号已更新'); location.reload(); }
window.onclick=e=>{if(e.target.className==='modal')closeModal();};
load();
</script></body></html>
"#;
EOF

# 4. 编译与服务启动
echo -e -n "${CYAN}>>> 编译面板程序 (请耐心等待！)...${RESET}"
cargo build --release >/dev/null 2>&1 &
spinner $!

if [ -f "target/release/realm-panel" ]; then
    echo -e "${GREEN} [完成]${RESET}"
    echo -e -n "${CYAN}>>> 安装与配置服务...${RESET}"
    mv target/release/realm-panel "$BINARY_PATH"
else
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}编译出错，请手动运行 cargo build --release 查看详情。${RESET}"
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
echo -e "${GREEN}✅ Realm 转发面板 (完美重构版) 部署完成！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"
