#!/bin/bash

# --- 配置 (可按需修改) ---
PANEL_PORT="4794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径 ---
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG="/etc/realm/config.toml"
WORK_DIR="/opt/realm_panel"
BINARY_PATH="/usr/local/bin/realm-panel"
DATA_FILE="/etc/realm/panel_data.json"

# --- 颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"
YELLOW="\033[33m"

# --- 辅助函数 ---
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
echo -e "${GREEN}Realm 面板 (截图高仿还原版)${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 依赖检查与安装
if [ -f /etc/debian_version ]; then
    run_step "更新源与依赖" "apt-get update -y && apt-get install -y curl wget tar build-essential pkg-config libssl-dev"
elif [ -f /etc/redhat-release ]; then
    run_step "更新源与依赖" "yum groupinstall -y 'Development Tools' && yum install -y curl wget tar openssl-devel"
fi

if ! command -v cargo &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Rust 环境...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
    spinner $!
    source "$HOME/.cargo/env"
    echo -e "${GREEN} [完成]${RESET}"
fi

# 2. Realm 核心安装
if [ ! -f "$REALM_BIN" ]; then
    echo -e -n "${CYAN}>>> 下载 Realm 核心...${RESET}"
    ARCH=$(uname -m)
    [ "$ARCH" == "x86_64" ] && URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    [ "$ARCH" == "aarch64" ] && URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    mkdir -p /tmp/realm_tmp
    wget -O /tmp/realm_tmp/realm.tar.gz "$URL" -q && tar -xvf /tmp/realm_tmp/realm.tar.gz -C /tmp/realm_tmp >/dev/null 2>&1
    mv /tmp/realm_tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    rm -rf /tmp/realm_tmp
    echo -e "${GREEN} [完成]${RESET}"
fi
mkdir -p "$(dirname "$REALM_CONFIG")"

# 3. 构建面板代码
run_step "准备源代码目录" "rm -rf '$WORK_DIR' && mkdir -p '$WORK_DIR/src'"
cd "$WORK_DIR"

cat > Cargo.toml <<EOF
[package]
name = "realm-panel"
version = "3.5.0"
edition = "2021"

[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
tower-cookies = "0.10"
uuid = { version = "1", features = ["v4"] }
EOF

# 写入 Rust 主逻辑
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

// 默认背景图 (截图中的森林风格)
fn default_bg_pc() -> String { "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string() }
fn default_bg_mobile() -> String { "https://img.inim.im/file/1764296937373_bg_m_2.png".to_string() }

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
    
    // 防止配置文件为空导致报错，添加保活规则
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
        Html("<script>alert('Error');window.location='/login'</script>").into_response()
    }
}
async fn logout_action(cookies: Cookies) -> Response {
    cookies.remove(Cookie::new("auth_session", ""));
    axum::response::Redirect::to("/login").into_response()
}

// API Routes
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

// --- HTML 模板 ---

const LOGIN_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1"><title>Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;display:flex;justify-content:center;align-items:center;background:url('{{BG_PC}}') center/cover;font-family:sans-serif}.box{background:rgba(255,255,255,0.7);backdrop-filter:blur(20px);padding:30px;border-radius:12px;width:320px;box-shadow:0 8px 32px rgba(0,0,0,0.1)}input{width:100%;padding:12px;margin:10px 0;border:none;border-radius:6px;background:rgba(255,255,255,0.6)}button{width:100%;padding:12px;background:#3b82f6;color:#fff;border:none;border-radius:6px;cursor:pointer}</style></head><body><div class="box"><h2 style="text-align:center;margin-bottom:20px;color:#333">Realm 面板</h2><form action="/login" method="post"><input name="username" placeholder="用户" required><input type="password" name="password" placeholder="密码" required><button type="submit">登录</button></form></div></body></html>
"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>转发规则管理</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
:root { --glass-bg: rgba(255, 255, 255, 0.65); --glass-border: rgba(255, 255, 255, 0.4); --text: #1f2937; --blue: #3b82f6; }
* { margin: 0; padding: 0; box-sizing: border-box; outline: none; }
body { font-family: -apple-system, "Microsoft YaHei", sans-serif; height: 100vh; background: url('{{BG_PC}}') no-repeat center center fixed; background-size: cover; color: var(--text); overflow: hidden; display: flex; flex-direction: column; }
@media(max-width: 768px) { body { background-image: url('{{BG_MOBILE}}'); } }

/* 顶部导航 */
.navbar { display: flex; justify-content: space-between; align-items: center; padding: 15px 30px; background: rgba(255, 255, 255, 0.3); backdrop-filter: blur(10px); border-bottom: 1px solid rgba(255,255,255,0.2); }
.brand { font-size: 18px; font-weight: bold; color: #111; display: flex; align-items: center; gap: 8px; }
.btn-nav { background: rgba(255,255,255,0.5); border: 1px solid rgba(255,255,255,0.5); padding: 8px 15px; border-radius: 6px; cursor: pointer; transition: 0.2s; font-size: 14px; display: flex; align-items: center; gap: 5px; color: #333; }
.btn-nav:hover { background: #fff; }

/* 主容器 */
.container { max-width: 1200px; margin: 20px auto; width: 95%; flex: 1; display: flex; flex-direction: column; overflow: hidden; }

/* 顶部输入栏 - 仿截图样式 */
.input-bar { display: flex; gap: 10px; background: var(--glass-bg); backdrop-filter: blur(15px); padding: 15px; border-radius: 12px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.02); align-items: center; }
.input-group { flex: 1; }
.input-field { width: 100%; padding: 12px 15px; border-radius: 8px; border: 1px solid transparent; background: rgba(255,255,255,0.5); font-size: 14px; color: #333; transition: 0.2s; }
.input-field:focus { background: #fff; box-shadow: 0 0 0 2px var(--blue); }
.btn-add { background: var(--blue); color: white; border: none; padding: 12px 20px; border-radius: 8px; cursor: pointer; font-weight: bold; white-space: nowrap; transition: 0.2s; display: flex; align-items: center; gap: 5px; }
.btn-add:hover { background: #2563eb; }

/* 标题 */
.section-title { font-size: 16px; font-weight: 600; margin-bottom: 15px; color: #374151; padding-left: 5px; }

/* 列表区域 - 核心修改：条状分离 */
.list-container { flex: 1; overflow-y: auto; padding-right: 5px; }
table { width: 100%; border-collapse: separate; border-spacing: 0 10px; } /* 关键：行间距 */

thead th { text-align: left; padding: 0 15px 5px 15px; font-size: 13px; color: #6b7280; font-weight: normal; }
tbody tr { background: rgba(255, 255, 255, 0.75); backdrop-filter: blur(10px); transition: transform 0.2s; box-shadow: 0 2px 4px rgba(0,0,0,0.01); }
tbody tr:hover { transform: scale(1.002); background: rgba(255, 255, 255, 0.9); }

/* 圆角处理 */
td { padding: 18px 15px; vertical-align: middle; color: #333; font-size: 14px; border: none; }
td:first-child { border-top-left-radius: 10px; border-bottom-left-radius: 10px; width: 100px; }
td:last-child { border-top-right-radius: 10px; border-bottom-right-radius: 10px; text-align: right; }

/* 状态点 */
.status-badge { display: inline-flex; align-items: center; gap: 6px; font-weight: 500; font-size: 14px; }
.dot { width: 8px; height: 8px; border-radius: 50%; }
.dot.green { background: #10b981; box-shadow: 0 0 4px #10b981; }
.dot.gray { background: #9ca3af; }

/* 操作按钮 */
.action-btn { width: 32px; height: 32px; border-radius: 6px; border: none; cursor: pointer; margin-left: 5px; display: inline-flex; align-items: center; justify-content: center; transition: 0.2s; }
.btn-toggle { background: #e5e7eb; color: #374151; }
.btn-toggle.active { background: #fee2e2; color: #ef4444; } 
.btn-edit { background: #3b82f6; color: white; }
.btn-del { background: #ef4444; color: white; }
.action-btn:hover { opacity: 0.8; transform: translateY(-1px); }

/* 模态框 */
.modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.3); z-index: 100; justify-content: center; align-items: center; backdrop-filter: blur(5px); }
.modal-box { background: rgba(255,255,255,0.95); width: 90%; max-width: 400px; padding: 25px; border-radius: 12px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.1); }
.modal h3 { margin-bottom: 15px; }
.modal input { width: 100%; padding: 10px; margin: 8px 0; border: 1px solid #ddd; border-radius: 6px; }
.modal-footer { margin-top: 20px; display: flex; justify-content: flex-end; gap: 10px; }

/* 移动端适配 */
@media(max-width: 768px) {
    .input-bar { flex-direction: column; }
    thead { display: none; }
    table { border-spacing: 0 15px; }
    tbody tr { display: flex; flex-direction: column; padding: 10px; height: auto; }
    td { padding: 5px 10px; width: 100% !important; border-radius: 0 !important; display: flex; justify-content: space-between; align-items: center; }
    td::before { content: attr(data-label); color: #666; font-size: 12px; }
    td:last-child { justify-content: flex-end; margin-top: 10px; border-top: 1px solid rgba(0,0,0,0.05); padding-top: 10px; }
}
</style>
</head>
<body>

<div class="navbar">
    <div class="brand"><i class="fas fa-cube"></i> Realm 面板</div>
    <div style="display:flex;gap:10px">
        <button class="btn-nav" onclick="openSet()"><i class="fas fa-cog"></i> 面板设置</button>
        <form action="/logout" method="post" style="margin:0"><button class="btn-nav" style="background:#fee2e2;color:#ef4444"><i class="fas fa-sign-out-alt"></i></button></form>
    </div>
</div>

<div class="container">
    <div class="input-bar">
        <div class="input-group"><input id="n" class="input-field" placeholder="备注名称"></div>
        <div class="input-group"><input id="l" class="input-field" placeholder="监听端口 (如 10000)"></div>
        <div class="input-group"><input id="r" class="input-field" placeholder="落地地址 (ip:port)"></div>
        <button class="btn-add" onclick="add()"><i class="fas fa-plus"></i> 添加规则</button>
    </div>

    <div class="section-title">转发规则管理</div>

    <div class="list-container">
        <table id="ruleTable">
            <thead>
                <tr>
                    <th width="10%">状态</th>
                    <th width="20%">备注</th>
                    <th width="25%">监听</th>
                    <th width="25%">落地</th>
                    <th width="20%" style="text-align:right">操作</th>
                </tr>
            </thead>
            <tbody id="list"></tbody>
        </table>
        <div id="empty" style="text-align:center;padding:40px;color:#666;display:none">暂无规则，请在上方添加</div>
    </div>
</div>

<div id="setModal" class="modal">
    <div class="modal-box">
        <h3>面板设置</h3>
        <label style="font-size:12px;color:#666">修改账户</label>
        <input id="su" placeholder="用户名" value="{{USER}}">
        <input id="sp" type="password" placeholder="新密码 (留空不改)">
        <div style="height:15px"></div>
        <label style="font-size:12px;color:#666">背景图片 URL</label>
        <input id="bpc" placeholder="PC端背景" value="{{BG_PC}}">
        <input id="bmb" placeholder="移动端背景" value="{{BG_MOBILE}}">
        <div class="modal-footer">
            <button class="btn-nav" onclick="closeModal()">取消</button>
            <button class="btn-add" onclick="saveSet()">保存</button>
        </div>
    </div>
</div>

<div id="editModal" class="modal">
    <div class="modal-box">
        <h3>修改规则</h3>
        <input type="hidden" id="eid">
        <input id="en" placeholder="备注">
        <input id="el" placeholder="监听端口">
        <input id="er" placeholder="落地地址">
        <div class="modal-footer">
            <button class="btn-nav" onclick="closeModal()">取消</button>
            <button class="btn-add" onclick="saveEdit()">保存</button>
        </div>
    </div>
</div>

<script>
let rules = [];
const $ = id => document.getElementById(id);

async function load() {
    const res = await fetch('/api/rules');
    if(res.status === 401) return location.href = '/login';
    const data = await res.json();
    rules = data.rules;
    render();
}

function render() {
    const list = $('list');
    list.innerHTML = '';
    if(rules.length === 0) {
        $('empty').style.display = 'block';
        $('ruleTable').style.display = 'none';
        return;
    }
    $('empty').style.display = 'none';
    $('ruleTable').style.display = 'table'; // 或者是 block，但在 flex 下 table 更好

    rules.forEach(r => {
        const tr = document.createElement('tr');
        if(!r.enabled) tr.style.opacity = '0.6';
        tr.innerHTML = `
            <td data-label="状态">
                <div class="status-badge">
                    <div class="dot ${r.enabled ? 'green' : 'gray'}"></div>
                    ${r.enabled ? '在线' : '已停用'}
                </div>
            </td>
            <td data-label="备注"><strong>${r.name}</strong></td>
            <td data-label="监听" style="font-family:monospace">${r.listen}</td>
            <td data-label="落地" style="font-family:monospace">${r.remote}</td>
            <td data-label="操作">
                <button class="action-btn btn-toggle" onclick="tog('${r.id}')" title="开关">
                    <i class="fas ${r.enabled ? 'fa-pause' : 'fa-play'}"></i>
                </button>
                <button class="action-btn btn-edit" onclick="openEdit('${r.id}')" title="编辑">
                    <i class="fas fa-pen"></i>
                </button>
                <button class="action-btn btn-del" onclick="del('${r.id}')" title="删除">
                    <i class="fas fa-trash"></i>
                </button>
            </td>
        `;
        list.appendChild(tr);
    });
}

async function add() {
    let [n, l, r] = ['n', 'l', 'r'].map(x => $(x).value);
    if(!n || !l || !r) return alert('请填写完整');
    if(!l.includes(':')) l = '0.0.0.0:' + l;
    await fetch('/api/rules', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({name: n, listen: l, remote: r}) });
    ['n', 'l', 'r'].forEach(x => $(x).value = '');
    load();
}

async function tog(id) { await fetch(`/api/rules/${id}/toggle`, {method: 'POST'}); load(); }
async function del(id) { if(confirm('确定删除?')) { await fetch(`/api/rules/${id}`, {method: 'DELETE'}); load(); } }

function openEdit(id) {
    const r = rules.find(x => x.id === id);
    $('eid').value = id; $('en').value = r.name; $('el').value = r.listen; $('er').value = r.remote;
    $('editModal').style.display = 'flex';
}

async function saveEdit() {
    const body = JSON.stringify({ name: $('en').value, listen: $('el').value, remote: $('er').value });
    await fetch(`/api/rules/${$('eid').value}`, { method: 'PUT', headers: {'Content-Type':'application/json'}, body });
    closeModal(); load();
}

function openSet() { $('setModal').style.display = 'flex'; }
function closeModal() { document.querySelectorAll('.modal').forEach(x => x.style.display = 'none'); }

async function saveSet() {
    await fetch('/api/admin/account', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({username:$('su').value, password:$('sp').value}) });
    await fetch('/api/admin/bg', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({bg_pc:$('bpc').value, bg_mobile:$('bmb').value}) });
    alert('保存成功，若修改了密码请重新登录');
    location.reload();
}

window.onload = load;
</script>
</body>
</html>
"#;
EOF

# 4. 编译与服务安装
echo -e -n "${CYAN}>>> 编译面板程序 (Release模式，请耐心等待)...${RESET}"
cargo build --release >/dev/null 2>&1 &
spinner $!
if [ ! -f "target/release/realm-panel" ]; then
    echo -e "${RED} 编译失败！请检查上方报错。${RESET}"
    exit 1
fi
echo -e "${GREEN} [完成]${RESET}"

mv target/release/realm-panel "$BINARY_PATH"
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

IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Realm 面板 (UI高仿版) 部署完成！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
