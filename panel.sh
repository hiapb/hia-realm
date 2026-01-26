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
echo -e "${GREEN}Realm 面板 一键部署 (透明主题版)   ${RESET}"
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
version = "3.2.1"
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
fn default_bg_pc() -> String { "https://images.unsplash.com/photo-1451187580459-43490279c0fa?q=80&w=2072&auto=format&fit=crop".to_string() }
// 修改点：更新了默认手机背景图
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
    let mut rules = Vec::new();
    if FilePath::new(REALM_CONFIG).exists() {
        if let Ok(content) = fs::read_to_string(REALM_CONFIG) {
            if let Ok(toml_val) = content.parse::<toml::Value>() {
                 if let Some(endpoints) = toml_val.get("endpoints").and_then(|v| v.as_array()) {
                     for ep in endpoints {
                         let name = ep.get("name").and_then(|v| v.as_str()).unwrap_or("Imported").to_string();
                         let listen = ep.get("listen").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         let remote = ep.get("remote").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         if !listen.is_empty() && !remote.is_empty() {
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
            name: "system-keepalive".to_string(),
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

// 修改点：Login HTML 增加了半透明效果 (rgba) 和毛玻璃 (backdrop-filter)
const LOGIN_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>Realm Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;width:100vw;overflow:hidden;display:flex;justify-content:center;align-items:center;font-family:-apple-system,sans-serif;background:url('{{BG_PC}}') no-repeat center center/cover}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.overlay{position:absolute;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.1)}.box{position:relative;z-index:2;background:rgba(255,255,255,0.45);backdrop-filter:blur(15px);-webkit-backdrop-filter:blur(15px);padding:2rem;border-radius:16px;border:1px solid rgba(255,255,255,0.3);box-shadow:0 8px 32px rgba(0,0,0,0.1);width:90%;max-width:350px;text-align:center}h2{margin-bottom:1.5rem;color:#222;text-shadow:0 1px 1px rgba(255,255,255,0.5)}input{width:100%;padding:12px;margin-bottom:1rem;border:1px solid rgba(255,255,255,0.5);border-radius:8px;outline:none;background:rgba(255,255,255,0.7);transition:0.2s}input:focus{background:rgba(255,255,255,0.9);border-color:#2563eb}button{width:100%;padding:12px;background:rgba(37,99,235,0.9);color:white;border:none;border-radius:8px;cursor:pointer;font-weight:bold;font-size:1rem;transition:0.2s;backdrop-filter:blur(5px)}button:hover{background:#1d4ed8;transform:scale(1.02)}</style></head><body><div class="overlay"></div><div class="box"><h2>Realm 转发面板</h2><form action="/login" method="post"><input type="text" name="username" placeholder="Username" required><input type="password" name="password" placeholder="Password" required><button type="submit">登录</button></form></div></body></html>
"#;

// 修改点：Dashboard HTML 增加了大量的透明和毛玻璃样式
const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"><title>Realm Panel</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>:root{--primary:#2563eb;--danger:#ef4444;--success:#10b981}::-webkit-scrollbar{width:6px;height:6px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:rgba(0,0,0,0.2);border-radius:10px}::-webkit-scrollbar-thumb:hover{background:rgba(0,0,0,0.4)}*{box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;padding:0;height:100vh;height:100dvh;overflow:hidden;background:url('{{BG_PC}}') no-repeat center center/cover;display:flex;flex-direction:column}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.05);z-index:-1}.navbar{flex:0 0 auto;background:rgba(255,255,255,0.65);backdrop-filter:blur(15px);-webkit-backdrop-filter:blur(15px);border-bottom:1px solid rgba(255,255,255,0.3);padding:1rem 1.5rem;box-shadow:0 2px 10px rgba(0,0,0,0.05);display:flex;justify-content:space-between;align-items:center;z-index:10}.brand{font-weight:800;font-size:1.2rem;color:var(--primary);display:flex;align-items:center;gap:10px}.nav-actions{display:flex;gap:10px}.container{flex:1 1 auto;display:flex;flex-direction:column;max-width:1200px;margin:1rem auto;width:100%;padding:0 1rem;overflow:hidden}.card{background:rgba(255,255,255,0.55);backdrop-filter:blur(15px);-webkit-backdrop-filter:blur(15px);border:1px solid rgba(255,255,255,0.3);border-radius:12px;padding:1.2rem;box-shadow:0 4px 6px rgba(0,0,0,0.05);margin-bottom:1rem}.card-fixed{flex:0 0 auto}.card-scroll{flex:1 1 auto;overflow:hidden;display:flex;flex-direction:column;padding:0}.table-wrapper{flex:1;overflow-y:auto;padding:0 1.2rem}table{width:100%;border-collapse:collapse}thead th{position:sticky;top:0;background:rgba(255,255,255,0.4);backdrop-filter:blur(10px);z-index:5;padding:15px 5px;text-align:left;color:#4b5563;border-bottom:2px solid rgba(0,0,0,0.05)}td{padding:15px 5px;border-bottom:1px solid rgba(0,0,0,0.05);color:#1f2937;font-size:0.95rem;font-weight:500}.btn{padding:8px 14px;border-radius:6px;border:none;cursor:pointer;color:white;transition:0.2s;display:inline-flex;align-items:center;gap:5px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}.btn-primary{background:var(--primary)}.btn-danger{background:var(--danger)}.btn-gray{background:rgba(229,231,235,0.8);color:#374151}.grid-input{display:grid;grid-template-columns:1fr 1fr 1fr auto;gap:10px}input{padding:10px;border:1px solid rgba(255,255,255,0.5);background:rgba(255,255,255,0.6);border-radius:6px;outline:none;transition:0.2s}input:focus{border-color:var(--primary);background:rgba(255,255,255,0.9)}.status-dot{height:8px;width:8px;border-radius:50%;display:inline-block;margin-right:6px}.bg-green{background:var(--success)}.bg-gray{background:#9ca3af}.row-paused{opacity:0.6;background:rgba(249,250,251,0.5)}.empty-state{padding:40px;text-align:center;color:#4b5563;font-style:italic}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.4);z-index:100;justify-content:center;align-items:center;backdrop-filter:blur(3px)}.modal-box{background:rgba(255,255,255,0.85);backdrop-filter:blur(20px);width:90%;max-width:450px;padding:2rem;border-radius:12px;box-shadow:0 10px 25px rgba(0,0,0,0.1);animation:popIn 0.2s ease}.modal-footer{margin-top:20px;display:flex;justify-content:flex-end;gap:15px}@keyframes popIn{from{transform:scale(0.95);opacity:0}to{transform:scale(1);opacity:1}}.tab-header{display:flex;border-bottom:1px solid rgba(0,0,0,0.1);margin-bottom:15px}.tab-btn{flex:1;padding:10px;text-align:center;cursor:pointer;color:#6b7280}.tab-btn.active{color:var(--primary);border-bottom:2px solid var(--primary);font-weight:bold}.tab-content{display:none}.tab-content.active{display:block}label{display:block;margin:10px 0 5px;font-size:0.9rem;color:#4b5563}@media(max-width:768px){.grid-input{grid-template-columns:1fr}.container{padding:0.5rem;margin:0}.nav-text{display:none}thead{display:none}tr{display:flex;flex-direction:column;border:1px solid rgba(255,255,255,0.3);margin-bottom:10px;border-radius:8px;padding:10px;background:rgba(255,255,255,0.5);backdrop-filter:blur(10px)}td{border:none;padding:5px 0;display:flex;justify-content:space-between;align-items:center}td::before{content:attr(data-label);font-weight:bold;color:#4b5563;font-size:0.85rem}.table-wrapper{padding:0 5px}}</style></head><body><div class="overlay"></div><div class="navbar"><div class="brand"><i class="fas fa-network-wired"></i> <span class="nav-text">Realm 转发面板</span></div><div class="nav-actions"><button class="btn btn-gray" onclick="openSettings()"><i class="fas fa-cog"></i> <span class="nav-text">设置</span></button><form action="/logout" method="post" style="margin:0"><button class="btn btn-danger"><i class="fas fa-sign-out-alt"></i></button></form></div></div><div class="container"><div class="card card-fixed"><div class="grid-input"><input id="n" placeholder="备注"><input id="l" placeholder="监听端口 (如 10000)"><input id="r" placeholder="目标 (例 1.1.1.1:443 或 [2402::1]:443)"><button class="btn btn-primary" onclick="add()"><i class="fas fa-plus"></i> 添加</button></div></div><div class="card card-scroll"><div style="padding:10px 1.2rem;border-bottom:1px solid rgba(0,0,0,0.05);font-weight:bold;color:#1f2937">规则列表</div><div class="table-wrapper"><table id="ruleTable"><thead><tr><th>状态</th><th>备注</th><th>监听</th><th>目标</th><th style="text-align:right">操作</th></tr></thead><tbody id="list"></tbody></table><div id="emptyView" class="empty-state" style="display:none"><i class="fas fa-ghost" style="display:block;font-size:2rem;margin-bottom:10px"></i>暂无转发规则</div></div></div></div><div id="setModal" class="modal"><div class="modal-box"><div class="tab-header"><div class="tab-btn active" onclick="switchTab(0)">账号安全</div><div class="tab-btn" onclick="switchTab(1)">界面背景</div></div><div class="tab-content active" id="tab0"><label>用户名</label><input id="set_u" value="{{USER}}"><label>新密码 (留空不改)</label><input id="set_p" type="password"><div class="modal-footer"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveAccount()">保存账号</button></div></div><div class="tab-content" id="tab1"><label>PC端背景图 URL</label><input id="bg_pc" value="{{BG_PC}}"><label>移动端背景图 URL</label><input id="bg_mob" value="{{BG_MOBILE}}"><div class="modal-footer"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveBg()">保存背景</button></div></div></div></div><div id="editModal" class="modal"><div class="modal-box"><h3>修改规则</h3><input type="hidden" id="edit_id"><label>备注</label><input id="edit_n"><label>监听端口</label><input id="edit_l"><label>目标地址</label><input id="edit_r" placeholder="1.1.1.1:443 或 [2402::1]:443"><div class="modal-footer"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveEdit()">保存修改</button></div></div></div><script>let rules=[];const $=id=>document.getElementById(id);async function load(){const r=await fetch('/api/rules');if(r.status===401)location.href='/login';const d=await r.json();rules=d.rules;render();window.dispatchEvent(new Event('resize'))}function render(){const t=$('list');const ev=$('emptyView');const table=$('ruleTable');t.innerHTML='';if(rules.length===0){ev.style.display='block';table.style.display=window.innerWidth<768?'none':'table'}else{ev.style.display='none';table.style.display='table';rules.forEach(r=>{const row=document.createElement('tr');if(!r.enabled)row.className='row-paused';row.innerHTML=`<td data-label="状态"><span class="status-dot ${r.enabled?'bg-green':'bg-gray'}"></span>${r.enabled?'运行':'暂停'}</td><td data-label="备注"><strong>${r.name}</strong></td><td data-label="监听">${r.listen}</td><td data-label="目标">${r.remote}</td><td data-label="操作" style="text-align:right;gap:5px;display:flex;justify-content:flex-end"><button class="btn btn-sm ${r.enabled?'btn-gray':'btn-primary'}" onclick="tog('${r.id}')"><i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i></button><button class="btn btn-sm btn-primary" onclick="openEdit('${r.id}')"><i class="fas fa-pen"></i></button><button class="btn btn-sm btn-danger" onclick="del('${r.id}')"><i class="fas fa-trash"></i></button></td>`;t.appendChild(row)})}}async function add(){let [n,l,r]=['n','l','r'].map(x=>$(x).value);if(!l||!r)return alert('必填');if(!l.includes(':'))l='0.0.0.0:'+l;await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r})});['n','l','r'].forEach(x=>$(x).value='');load()}async function tog(id){await fetch(`/api/rules/${id}/toggle`,{method:'POST'});load()}async function del(id){if(confirm('删除?'))await fetch(`/api/rules/${id}`,{method:'DELETE'});load()}function openEdit(id){const r=rules.find(x=>x.id===id);$('edit_id').value=id;$('edit_n').value=r.name;$('edit_l').value=r.listen;$('edit_r').value=r.remote;$('editModal').style.display='flex'}async function saveEdit(){const body=JSON.stringify({name:$('edit_n').value,listen:$('edit_l').value,remote:$('edit_r').value});await fetch(`/api/rules/${$('edit_id').value}`,{method:'PUT',headers:{'Content-Type':'application/json'},body});$('editModal').style.display='none';load()}function openSettings(){$('setModal').style.display='flex';switchTab(0)}function closeModal(){document.querySelectorAll('.modal').forEach(x=>x.style.display='none')}function switchTab(idx){document.querySelectorAll('.tab-btn').forEach((b,i)=>b.classList.toggle('active',i===idx));document.querySelectorAll('.tab-content').forEach((c,i)=>c.classList.toggle('active',i===idx))}async function saveAccount(){await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('set_u').value,password:$('set_p').value})});alert('账号更新，请重新登录');location.reload()}async function saveBg(){await fetch('/api/admin/bg',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({bg_pc:$('bg_pc').value,bg_mobile:$('bg_mob').value})});alert('背景已更新');location.reload()}window.addEventListener('load',()=>{load();setTimeout(()=>window.dispatchEvent(new Event('resize')),500)});</script></body></html>
"#;
EOF

# 4. 编译安装
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
echo -e "${GREEN}✅ Realm 转发面板 (透明版) 部署完成！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"
