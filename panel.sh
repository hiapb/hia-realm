只需要修改 DASHBOARD_HTML 中 <body> 部分的一行代码即可。为了方便你直接使用，我直接给你 修改好的完整代码。
🔧 修改位置说明
我在 <div class="nav-actions"> 标签中增加了一个内联样式 style="display:flex;gap:15px"。
 * gap:15px：这会给“设置”按钮和“退出”按钮之间增加 15像素 的间距，不再紧挨着。
📋 最终完美版代码 (直接覆盖)
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
echo -e "${GREEN}Realm 面板 一键部署 ${RESET}"
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
version = "3.3.8"
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
        cookie.set_path("/"); cookie.set_http_only(true); 
        cookie.set_same_site(tower_cookies::cookie::SameSite::Strict);
        cookies.add(cookie);
        axum::response::Redirect::to("/").into_response()
    } else {
        StatusCode::UNAUTHORIZED.into_response()
    }
}
async fn logout_action(cookies: Cookies) -> Response {
    let mut cookie = Cookie::new("auth_session", "");
    cookie.set_path("/");
    cookies.remove(cookie);
    Json(serde_json::json!({"status":"ok"})).into_response()
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
    cookie.set_path("/"); cookie.set_http_only(true); cookies.add(cookie); save_json(&data);
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
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>Realm Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;width:100vw;overflow:hidden;display:flex;justify-content:center;align-items:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:url('{{BG_PC}}') no-repeat center center/cover;color:#374151}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.overlay{position:absolute;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.05)}.box{position:relative;z-index:2;background:rgba(255,255,255,0.3);backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px);padding:2.5rem;border-radius:24px;border:1px solid rgba(255,255,255,0.4);box-shadow:0 8px 32px rgba(0,0,0,0.05);width:90%;max-width:380px;text-align:center}h2{margin-bottom:2rem;color:#374151;font-weight:600;letter-spacing:1px}input{width:100%;padding:14px;margin-bottom:1.2rem;border:1px solid rgba(255,255,255,0.5);border-radius:12px;outline:none;background:rgba(255,255,255,0.5);transition:0.3s;color:#374151}input:focus{background:rgba(255,255,255,0.9);border-color:#3b82f6}button{width:100%;padding:14px;background:rgba(59,130,246,0.85);color:white;border:none;border-radius:12px;cursor:pointer;font-weight:600;font-size:1rem;transition:0.3s;backdrop-filter:blur(5px)}button:hover{background:#2563eb;transform:translateY(-1px)}</style></head><body><div class="overlay"></div><div class="box"><h2>Realm Panel</h2><form onsubmit="doLogin(event)"><input type="text" id="u" placeholder="Username" required><input type="password" id="p" placeholder="Password" required><button type="submit" id="btn">登 录</button></form></div><script>async function doLogin(e){e.preventDefault();const b=document.getElementById('btn');b.innerText='登录中...';b.disabled=true;const res=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${encodeURIComponent(document.getElementById('u').value)}&password=${encodeURIComponent(document.getElementById('p').value)}`});if(res.redirected){location.href=res.url}else if(res.ok){location.href='/'}else{alert('用户名或密码错误');b.innerText='登 录';b.disabled=false}}</script></body></html>
"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"><title>Realm Panel</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>:root{--primary:#3b82f6;--danger:#f87171;--success:#34d399;--text-main:#374151}::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-thumb{background:rgba(0,0,0,0.1);border-radius:10px}*{box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;padding:0;height:100vh;height:100dvh;overflow:hidden;background:url('{{BG_PC}}') no-repeat center center/cover;display:flex;flex-direction:column;color:var(--text-main)}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.navbar{flex:0 0 auto;background:rgba(255,255,255,0.3);backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px);border-bottom:1px solid rgba(255,255,255,0.3);padding:0.8rem 2rem;display:flex;justify-content:space-between;align-items:center;z-index:10}.brand{font-weight:700;font-size:1.1rem;color:var(--text-main);display:flex;align-items:center;gap:10px}.container{flex:1;display:flex;flex-direction:column;max-width:1100px;margin:1.5rem auto;width:95%;overflow:hidden}.card-fixed{background:rgba(255,255,255,0.3);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,0.4);border-radius:18px;padding:1.2rem;margin-bottom:1.5rem;box-shadow:0 4px 15px rgba(0,0,0,0.03)}.card-scroll{flex:1;background:rgba(255,255,255,0.25);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,0.4);border-radius:18px;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 4px 15px rgba(0,0,0,0.03)}.table-wrapper{flex:1;overflow-y:auto;padding:0 1.5rem 1.5rem}table{width:100%;border-collapse:separate;border-spacing:0 10px}
/* PC端 Header: 独立圆角条 */
thead th{position:sticky;top:0;background:rgba(255,255,255,0.4);backdrop-filter:blur(15px);z-index:5;padding:14px 12px;text-align:left;font-size:0.85rem;text-transform:uppercase;letter-spacing:1px;color:#6b7280;border-top:1px solid rgba(255,255,255,0.3);border-bottom:1px solid rgba(255,255,255,0.3)}
thead th:first-child{border-top-left-radius:15px;border-bottom-left-radius:15px;border-left:1px solid rgba(255,255,255,0.3)}
thead th:last-child{border-top-right-radius:15px;border-bottom-right-radius:15px;border-right:1px solid rgba(255,255,255,0.3)}
/* PC端 Rule Item: 通过给td加背景实现完美圆角 */
tbody tr{background:transparent;transition:0.3s}
@media(min-width:768px){tbody tr:hover td{background:rgba(255,255,255,0.7);transform:translateY(-1px);box-shadow:0 4px 10px rgba(0,0,0,0.02)}}
td{background:rgba(255,255,255,0.4);padding:14px 12px;font-size:0.92rem;font-weight:500;color:var(--text-main);border-top:1px solid rgba(255,255,255,0.3);border-bottom:1px solid rgba(255,255,255,0.3)}
td:first-child{border-left:1px solid rgba(255,255,255,0.3);border-top-left-radius:15px;border-bottom-left-radius:15px}
td:last-child{border-right:1px solid rgba(255,255,255,0.3);border-top-right-radius:15px;border-bottom-right-radius:15px}

.btn{padding:8px 12px;border-radius:10px;border:none;cursor:pointer;color:white;transition:0.2s;display:inline-flex;align-items:center;justify-content:center;gap:6px;font-weight:500}.btn-primary{background:var(--primary);opacity:0.9}.btn-danger{background:var(--danger);opacity:0.9}.btn-gray{background:rgba(0,0,0,0.05);color:var(--text-main)}.grid-input{display:grid;grid-template-columns:1.5fr 1fr 2fr auto;gap:12px}input{padding:10px 14px;border:1px solid rgba(0,0,0,0.05);background:rgba(255,255,255,0.5);border-radius:10px;outline:none;transition:0.3s;color:var(--text-main);font-weight:500}input:focus{border-color:var(--primary);background:white}.status-dot{height:7px;width:7px;border-radius:50%;display:inline-block;margin-right:8px}.bg-green{background:var(--success);box-shadow:0 0 8px var(--success)}.bg-gray{background:#9ca3af}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.1);z-index:100;justify-content:center;align-items:center;backdrop-filter:blur(8px)}.modal-box{background:rgba(255,255,255,0.9);width:90%;max-width:420px;padding:2rem;border-radius:20px;box-shadow:0 20px 40px rgba(0,0,0,0.1);animation:pop 0.3s ease}@keyframes pop{from{transform:scale(0.9);opacity:0}to{transform:scale(1);opacity:1}}.tab-header{display:flex;gap:20px;margin-bottom:20px;border-bottom:1px solid rgba(0,0,0,0.05)}.tab-btn{padding:10px 5px;cursor:pointer;font-size:0.9rem;color:#9ca3af}.tab-btn.active{color:var(--primary);border-bottom:2px solid var(--primary);font-weight:600}.tab-content{display:none}.tab-content.active{display:block}label{display:block;margin:12px 0 6px;font-size:0.85rem;color:#6b7280}

/* 移动端优化：去白底、美化按钮 */
@media(max-width:768px){.grid-input{grid-template-columns:1fr}.navbar{padding:0.8rem 1rem}.nav-text{display:none}thead{display:none}tbody tr{display:flex;flex-direction:column;border-radius:18px!important;margin-bottom:12px;padding:15px;border:1px solid rgba(255,255,255,0.3);background:rgba(255,255,255,0.4)}td{padding:6px 0;display:flex;justify-content:space-between;border-radius:0!important;align-items:center;border:none;background:transparent}td::before{content:attr(data-label);color:#9ca3af;font-size:0.85rem}td[data-label="操作"]{justify-content:flex-end;gap:10px;margin-top:8px;padding-top:10px;border-top:1px solid rgba(0,0,0,0.05)}
/* 移动端按钮特殊样式：无白底 */
td[data-label="操作"] .btn{flex:none;width:auto;padding:6px 14px;border-radius:8px;font-size:0.85rem}
td[data-label="操作"] .btn-gray{background:transparent;border:1px solid rgba(0,0,0,0.15);color:#555}
td[data-label="操作"] .btn-primary{background:var(--primary);color:white}
td[data-label="操作"] .btn-danger{background:rgba(239,68,68,0.1);color:var(--danger);border:1px solid rgba(239,68,68,0.2)}}</style></head><body><div class="navbar"><div class="brand"><i class="fas fa-layer-group"></i> <span class="nav-text">Realm 转发面板</span></div><div class="nav-actions" style="display:flex;gap:15px"><button class="btn btn-gray" onclick="openSettings()"><i class="fas fa-sliders-h"></i> <span class="nav-text">面板设置</span></button><button class="btn btn-danger" onclick="doLogout()"><i class="fas fa-power-off"></i></button></div></div><div class="container"><div class="card card-fixed"><div class="grid-input"><input id="n" placeholder="备注名称"><input id="l" placeholder="监听端口 (如 10000)"><input id="r" placeholder="目标 (例 1.2.3.4:443 或 [2402::1]:443)"><button class="btn btn-primary" onclick="add()"><i class="fas fa-plus"></i> 添加规则</button></div></div><div class="card card-scroll"><div style="padding:1.2rem 1.5rem;font-weight:700;font-size:1rem;opacity:0.8">转发规则管理</div><div class="table-wrapper"><table id="ruleTable"><thead><tr><th>状态</th><th>备注</th><th>监听</th><th>目标</th><th style="width:130px;text-align:right;padding-right:20px">操作</th></tr></thead><tbody id="list"></tbody></table><div id="emptyView" style="display:none;text-align:center;padding:50px;color:#9ca3af"><i class="fas fa-inbox" style="font-size:2rem;display:block;margin-bottom:10px"></i>暂无规则</div></div></div></div><div id="setModal" class="modal"><div class="modal-box"><div class="tab-header"><div class="tab-btn active" onclick="switchTab(0)">管理账户</div><div class="tab-btn" onclick="switchTab(1)">个性背景</div></div><div class="tab-content active" id="tab0"><label>用户名</label><input id="set_u" value="{{USER}}"><label>重置密码 (留空保持不变)</label><input id="set_p" type="password"><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveAccount()">确认修改</button></div></div><div class="tab-content" id="tab1"><label>PC端壁纸 URL</label><input id="bg_pc" value="{{BG_PC}}"><label>手机端壁纸 URL</label><input id="bg_mob" value="{{BG_MOBILE}}"><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveBg()">应用背景</button></div></div></div></div><div id="editModal" class="modal"><div class="modal-box"><h3>编辑规则</h3><input type="hidden" id="edit_id"><label>备注</label><input id="edit_n"><label>监听端口</label><input id="edit_l"><label>目标地址</label><input id="edit_r"><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveEdit()">保存更改</button></div></div></div><script>let rules=[];const $=id=>document.getElementById(id);async function load(){const r=await fetch('/api/rules');if(r.status===401)location.href='/login';const d=await r.json();rules=d.rules;render()}function render(){const t=$('list');const ev=$('emptyView');const table=$('ruleTable');t.innerHTML='';if(rules.length===0){ev.style.display='block';table.style.display='none'}else{ev.style.display='none';table.style.display='table';rules.forEach(r=>{const row=document.createElement('tr');if(!r.enabled)row.style.opacity='0.6';
        // 移动端/PC端 渲染逻辑
        const isMob=window.innerWidth<768;
        if(isMob){
            row.innerHTML=`<td data-label="状态"><span class="status-dot ${r.enabled?'bg-green':'bg-gray'}"></span>${r.enabled?'在线':'暂停'}</td><td data-label="备注"><strong>${r.name}</strong></td><td data-label="监听">${r.listen}</td><td data-label="目标">${r.remote}</td><td data-label="操作"><button class="btn btn-gray" onclick="tog('${r.id}')"><i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i> ${r.enabled?'暂停':'开启'}</button><button class="btn btn-primary" onclick="openEdit('${r.id}')"><i class="fas fa-edit"></i> 编辑</button><button class="btn btn-danger" onclick="del('${r.id}')"><i class="fas fa-trash-alt"></i> 删除</button></td>`;
        }else{
            row.innerHTML=`<td data-label="状态"><span class="status-dot ${r.enabled?'bg-green':'bg-gray'}"></span>${r.enabled?'在线':'暂停'}</td><td data-label="备注"><strong>${r.name}</strong></td><td data-label="监听">${r.listen}</td><td data-label="目标">${r.remote}</td><td data-label="操作" style="display:flex;gap:6px;justify-content:flex-end;padding-right:15px"><button class="btn btn-gray" style="padding:6px 10px" onclick="tog('${r.id}')"><i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i></button><button class="btn btn-primary" style="padding:6px 10px" onclick="openEdit('${r.id}')"><i class="fas fa-edit"></i></button><button class="btn btn-danger" style="padding:6px 10px;background:#fee2e2;color:#ef4444" onclick="del('${r.id}')"><i class="fas fa-trash-alt"></i></button></td>`;
        }
        t.appendChild(row)})}}async function add(){let [n,l,r]=['n','l','r'].map(x=>$(x).value);if(!n||!l||!r)return;if(!l.includes(':'))l='0.0.0.0:'+l;await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r})});['n','l','r'].forEach(x=>$(x).value='');load()}async function tog(id){await fetch(`/api/rules/${id}/toggle`,{method:'POST'});load()}async function del(id){if(confirm('确定删除此规则吗？'))await fetch(`/api/rules/${id}`,{method:'DELETE'});load()}function openEdit(id){const r=rules.find(x=>x.id===id);$('edit_id').value=id;$('edit_n').value=r.name;
        // 编辑时去掉 0.0.0.0: 前缀
        let listen = r.listen;
        if(listen.startsWith('0.0.0.0:')) listen = listen.replace('0.0.0.0:', '');
        $('edit_l').value=listen;
        $('edit_r').value=r.remote;$('editModal').style.display='flex'}async function saveEdit(){
        // 保存时自动补全 0.0.0.0:
        let l = $('edit_l').value;
        if(!l.includes(':')) l = '0.0.0.0:' + l;
        const body=JSON.stringify({name:$('edit_n').value,listen:l,remote:$('edit_r').value});await fetch(`/api/rules/${$('edit_id').value}`,{method:'PUT',headers:{'Content-Type':'application/json'},body});$('editModal').style.display='none';load()}function openSettings(){$('setModal').style.display='flex';switchTab(0)}function closeModal(){document.querySelectorAll('.modal').forEach(x=>x.style.display='none')}function switchTab(idx){document.querySelectorAll('.tab-btn').forEach((b,i)=>b.classList.toggle('active',i===idx));document.querySelectorAll('.tab-content').forEach((c,i)=>c.classList.toggle('active',i===idx))}async function saveAccount(){await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('set_u').value,password:$('set_p').value})});alert('账户已更新，请重新登录');location.reload()}async function saveBg(){await fetch('/api/admin/bg',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({bg_pc:$('bg_pc').value,bg_mobile:$('bg_mob').value})});location.reload()}async function doLogout(){await fetch('/logout',{method:'POST'});location.href='/login'}load();window.addEventListener('resize',render);</script></body></html>
"#;
EOF

# 4. 编译安装
echo -e -n "${CYAN}>>> 编译面板程序 (请耐心等待！)...${RESET}"
cargo build --release >/dev/null 2>&1 &
spinner $!

if [ -f "target/release/realm-panel" ]; then
    echo -e "${GREEN} [完成]${RESET}"
    echo -e -n "${CYAN}>>> 正在部署服务...${RESET}"
    mv target/release/realm-panel "$BINARY_PATH"
else
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}编译出错，请手动运行 cargo build --release 查看详情。${RESET}"
    exit 1
fi

rm -rf "$WORK_DIR"

cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Panel Custom
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
echo -e "${GREEN}✅ Realm 转发面板部署成功！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"

