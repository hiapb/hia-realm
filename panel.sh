#!/bin/bash

# ==========================================
# Realm 转发面板
# ==========================================

# --- 默认配置 ---
PANEL_PORT="19794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径定义 ---
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG="/etc/realm/config.toml"
WORK_DIR="/opt/realm_panel_pro"
BINARY_PATH="/usr/local/bin/realm-panel"
DATA_FILE="/etc/realm/panel_data.json" 

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

echo -e "${GREEN}>>> 正在部署 Realm 转发面板...${RESET}"

# 2. 安装编译环境
echo -e "${YELLOW}正在检查编译环境...${RESET}"
if [ -f /etc/debian_version ]; then
    apt-get update -y
    apt-get install -y curl wget tar build-essential pkg-config libssl-dev
elif [ -f /etc/redhat-release ]; then
    yum groupinstall -y "Development Tools"
    yum install -y curl wget tar openssl-devel
fi

# 3. 安装 Rust
if ! command -v cargo &> /dev/null; then
    echo -e "${YELLOW}正在安装 Rust 编译器...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    echo -e "${GREEN}Rust 已安装。${RESET}"
fi

# 4. 确保 Realm 存在
if [ ! -f "$REALM_BIN" ]; then
    echo -e "${YELLOW}正在安装 Realm...${RESET}"
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
fi
mkdir -p "$(dirname "$REALM_CONFIG")"

# 5. 创建 Rust 项目
echo -e "${YELLOW}正在生成代码...${RESET}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/src"
cd "$WORK_DIR"

# Cargo.toml
cat > Cargo.toml <<EOF
[package]
name = "realm-panel-pro"
version = "1.0.0"
edition = "2021"

[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
tower-cookies = "0.10"
anyhow = "1.0"
EOF

# src/main.rs (核心代码)
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

// --- 配置路径 ---
const REALM_CONFIG: &str = "/etc/realm/config.toml";
const DATA_FILE: &str = "/etc/realm/panel_data.json";

// --- 数据结构 ---
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule {
    id: String, // 唯一ID
    name: String,
    listen: String,
    remote: String,
    enabled: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig {
    username: String,
    pass_hash: String, // 简单明文存储，方便修改
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData {
    admin: AdminConfig,
    rules: Vec<Rule>,
}

// 内存状态
struct AppState {
    data: Mutex<AppData>,
}

#[tokio::main]
async fn main() {
    // 1. 初始化数据
    let initial_data = load_or_init_data();
    let state = Arc::new(AppState {
        data: Mutex::new(initial_data),
    });

    // 2. 路由
    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/admin", post(update_admin))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new())
        .with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "8080".to_string());
    println!("Listening on 0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

// --- 逻辑处理 ---

fn load_or_init_data() -> AppData {
    // 尝试读取 json
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(data) = serde_json::from_str::<AppData>(&content) {
            return data;
        }
    }

    // 初始化默认值
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: std::env::var("PANEL_PASS").unwrap_or("123456".to_string()),
    };

    // 尝试从旧的 config.toml 导入
    let mut rules = Vec::new();
    if FilePath::new(REALM_CONFIG).exists() {
        if let Ok(content) = fs::read_to_string(REALM_CONFIG) {
            if let Ok(toml_val) = content.parse::<toml::Value>() {
                 if let Some(endpoints) = toml_val.get("endpoints").and_then(|v| v.as_array()) {
                     for ep in endpoints {
                         let name = ep.get("name").and_then(|v| v.as_str()).unwrap_or("导入规则").to_string();
                         let listen = ep.get("listen").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         let remote = ep.get("remote").and_then(|v| v.as_str()).unwrap_or("").to_string();
                         if !listen.is_empty() && !remote.is_empty() {
                             rules.push(Rule {
                                 id: uuid::Uuid::new_v4().to_string(),
                                 name, listen, remote, enabled: true
                             });
                         }
                     }
                 }
            }
        }
    }
    
    let data = AppData { admin, rules };
    save_data(&data);
    data
}

fn save_data(data: &AppData) {
    // 1. 保存 JSON (Source of Truth)
    let json_str = serde_json::to_string_pretty(data).unwrap();
    let _ = fs::write(DATA_FILE, json_str);

    // 2. 生成 config.toml (只包含启用的规则)
    let mut toml_str = String::from("# Generated by Realm Panel\n\n");
    for rule in &data.rules {
        if rule.enabled {
            toml_str.push_str("[[endpoints]]\n");
            toml_str.push_str(&format!("name = \"{}\"\n", rule.name));
            toml_str.push_str(&format!("listen = \"{}\"\n", rule.listen));
            toml_str.push_str(&format!("remote = \"{}\"\n", rule.remote));
            toml_str.push_str("type = \"tcp+udp\"\n\n");
        }
    }
    let _ = fs::write(REALM_CONFIG, toml_str);

    // 3. 重启 Realm
    let _ = Command::new("systemctl").arg("restart").arg("realm").status();
}

// --- 鉴权 ---
fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") {
        return cookie.value() == state.admin.pass_hash; // 简化验证
    }
    false
}

// --- Handlers ---

// 1. 页面
async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) {
        return axum::response::Redirect::to("/login").into_response();
    }
    Html(DASHBOARD_HTML.replace("{{USER}}", &data.admin.username)).into_response()
}

async fn login_page() -> Html<&'static str> {
    Html(LOGIN_HTML)
}

#[derive(Deserialize)]
struct LoginParams { username: String, password: String }
async fn login_action(cookies: Cookies, State(state): State<Arc<AppState>>, Form(form): Form<LoginParams>) -> Response {
    let data = state.data.lock().unwrap();
    if form.username == data.admin.username && form.password == data.admin.pass_hash {
        let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
        cookie.set_path("/");
        cookie.set_http_only(true);
        cookies.add(cookie);
        axum::response::Redirect::to("/").into_response()
    } else {
        Html("<script>alert('用户名或密码错误');window.location='/login'</script>").into_response()
    }
}

async fn logout_action(cookies: Cookies) -> Response {
    cookies.remove(Cookie::new("auth_session", ""));
    axum::response::Redirect::to("/login").into_response()
}

// 2. API
async fn get_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Json(data.clone()).into_response()
}

#[derive(Deserialize)]
struct AddRuleReq { name: String, listen: String, remote: String }
async fn add_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<AddRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    data.rules.push(Rule {
        id: uuid::Uuid::new_v4().to_string(),
        name: req.name,
        listen: req.listen,
        remote: req.remote,
        enabled: true,
    });
    save_data(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

async fn delete_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    data.rules.retain(|r| r.id != id);
    save_data(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

async fn toggle_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) {
        rule.enabled = !rule.enabled;
        save_data(&data);
    }
    Json(serde_json::json!({"status":"ok"})).into_response()
}

#[derive(Deserialize)]
struct UpdateRuleReq { name: String, listen: String, remote: String }
async fn update_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<UpdateRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) {
        rule.name = req.name;
        rule.listen = req.listen;
        rule.remote = req.remote;
        save_data(&data);
    }
    Json(serde_json::json!({"status":"ok"})).into_response()
}

#[derive(Deserialize)]
struct AdminUpdate { username: String, password: String }
async fn update_admin(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<AdminUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    data.admin.username = req.username;
    if !req.password.is_empty() {
        data.admin.pass_hash = req.password;
    }
    
    // 更新后需重置 Cookie
    let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
    cookie.set_path("/");
    cookies.add(cookie);
    
    save_data(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}


const LOGIN_HTML: &str = r#"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Realm Login</title>
<style>
body { background: #f3f4f6; display: flex; justify-content: center; align-items: center; height: 100vh; font-family: sans-serif; }
.box { background: white; padding: 2rem; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); width: 100%; max-width: 320px; }
h2 { text-align: center; color: #374151; margin-bottom: 1.5rem; }
input { width: 100%; padding: 10px; margin-bottom: 1rem; border: 1px solid #d1d5db; border-radius: 6px; box-sizing: border-box; }
button { width: 100%; padding: 10px; background: #2563eb; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
button:hover { background: #1d4ed8; }
</style>
</head>
<body>
<div class="box">
    <h2>Realm 面板登录</h2>
    <form action="/login" method="post">
        <input type="text" name="username" placeholder="用户名" required>
        <input type="password" name="password" placeholder="密码" required>
        <button type="submit">登 录</button>
    </form>
</div>
</body>
</html>
"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Realm Dashboard</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
<style>
:root { --primary: #2563eb; --danger: #ef4444; --success: #10b981; --warn: #f59e0b; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f3f4f6; margin: 0; padding: 0; color: #1f2937; }
.navbar { background: white; padding: 1rem 2rem; box-shadow: 0 1px 2px rgba(0,0,0,0.05); display: flex; justify-content: space-between; align-items: center; }
.logo { font-weight: bold; font-size: 1.25rem; color: var(--primary); }
.container { max-width: 1000px; margin: 2rem auto; padding: 0 1rem; }
.card { background: white; border-radius: 10px; padding: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 2rem; }
.btn { padding: 8px 16px; border-radius: 6px; border: none; cursor: pointer; font-size: 0.9rem; transition: 0.2s; color: white; }
.btn-primary { background: var(--primary); }
.btn-danger { background: var(--danger); }
.btn-sm { padding: 4px 10px; font-size: 0.8rem; }
input { padding: 10px; border: 1px solid #e5e7eb; border-radius: 6px; width: 100%; box-sizing: border-box; }
.grid-form { display: grid; grid-template-columns: 1fr 1fr 1fr auto; gap: 10px; margin-top: 10px; }
table { width: 100%; border-collapse: collapse; margin-top: 1rem; }
th { text-align: left; padding: 12px; background: #f9fafb; color: #6b7280; font-size: 0.85rem; }
td { padding: 14px 12px; border-bottom: 1px solid #e5e7eb; vertical-align: middle; }
.status-dot { height: 8px; width: 8px; border-radius: 50%; display: inline-block; margin-right: 5px; }
.running { background: var(--success); }
.stopped { background: #d1d5db; }
.modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); justify-content: center; align-items: center; }
.modal-content { background: white; padding: 2rem; border-radius: 10px; width: 400px; }
.actions { display: flex; gap: 5px; }
.paused-row { opacity: 0.6; background: #f9fafb; }
@media(max-width: 700px) { .grid-form { grid-template-columns: 1fr; } .actions { flex-direction: column; } }
</style>
</head>
<body>
<div class="navbar">
    <div class="logo"><i class="fas fa-network-wired"></i> Realm 转发面板</div>
    <div style="display:flex; gap:10px; align-items:center">
        <span><i class="fas fa-user"></i> {{USER}}</span>
        <button class="btn" style="background:#e5e7eb; color:#374151" onclick="openAdmin()">设置</button>
        <form action="/logout" method="post" style="margin:0"><button class="btn btn-danger">退出</button></form>
    </div>
</div>

<div class="container">
    <div class="card">
        <h3><i class="fas fa-plus-circle"></i> 添加新规则</h3>
        <div class="grid-form">
            <input id="new_name" placeholder="备注 (Name)">
            <input id="new_listen" placeholder="本地监听 (例如 10000)">
            <input id="new_remote" placeholder="目标地址 (例如 1.1.1.1:443)">
            <button class="btn btn-primary" onclick="addRule()">添加</button>
        </div>
    </div>

    <div class="card">
        <h3><i class="fas fa-list"></i> 转发列表</h3>
        <table>
            <thead><tr><th>状态</th><th>备注</th><th>本地端口</th><th>远程目标</th><th style="text-align:right">操作</th></tr></thead>
            <tbody id="ruleList"></tbody>
        </table>
    </div>
</div>

<div id="editModal" class="modal">
    <div class="modal-content">
        <h3>修改规则</h3>
        <input type="hidden" id="edit_id">
        <label>备注</label><input id="edit_name" style="margin-bottom:10px">
        <label>监听</label><input id="edit_listen" style="margin-bottom:10px">
        <label>目标</label><input id="edit_remote" style="margin-bottom:20px">
        <div style="text-align:right">
            <button class="btn" style="background:#ccc;color:#333" onclick="closeModal('editModal')">取消</button>
            <button class="btn btn-primary" onclick="saveEdit()">保存</button>
        </div>
    </div>
</div>

<div id="adminModal" class="modal">
    <div class="modal-content">
        <h3>修改账户设置</h3>
        <label>用户名</label><input id="admin_user" value="{{USER}}" style="margin-bottom:10px">
        <label>新密码 (留空不修改)</label><input id="admin_pass" type="password" style="margin-bottom:20px">
        <div style="text-align:right">
            <button class="btn" style="background:#ccc;color:#333" onclick="closeModal('adminModal')">取消</button>
            <button class="btn btn-primary" onclick="saveAdmin()">保存设置</button>
        </div>
    </div>
</div>

<script>
let rules = [];

async function loadRules() {
    const res = await fetch('/api/rules');
    if (res.status === 401) window.location.href = '/login';
    const data = await res.json();
    rules = data.rules;
    render();
}

function render() {
    const tbody = document.getElementById('ruleList');
    tbody.innerHTML = '';
    rules.forEach(r => {
        const tr = document.createElement('tr');
        if(!r.enabled) tr.className = 'paused-row';
        tr.innerHTML = `
            <td><span class="status-dot ${r.enabled?'running':'stopped'}"></span>${r.enabled?'运行中':'已暂停'}</td>
            <td><strong>${r.name}</strong></td>
            <td>${r.listen}</td>
            <td>${r.remote}</td>
            <td class="actions" style="text-align:right">
                <button class="btn btn-sm ${r.enabled?'btn-danger':'btn-primary'}" style="background:${r.enabled?'#f59e0b':'#10b981'}" onclick="toggle('${r.id}')">
                    <i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i>
                </button>
                <button class="btn btn-sm btn-primary" onclick="openEdit('${r.id}')"><i class="fas fa-edit"></i></button>
                <button class="btn btn-sm btn-danger" onclick="del('${r.id}')"><i class="fas fa-trash"></i></button>
            </td>
        `;
        tbody.appendChild(tr);
    });
}

async function addRule() {
    const name = document.getElementById('new_name').value;
    let listen = document.getElementById('new_listen').value;
    const remote = document.getElementById('new_remote').value;
    if(!listen || !remote) return alert('请填写监听和目标地址');
    if(!listen.includes(':')) listen = '0.0.0.0:' + listen;

    await fetch('/api/rules', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({name, listen, remote}) });
    ['new_name','new_listen','new_remote'].forEach(id=>document.getElementById(id).value='');
    loadRules();
}

async function toggle(id) {
    await fetch(`/api/rules/${id}/toggle`, { method: 'POST' });
    loadRules();
}

async function del(id) {
    if(!confirm('确定删除?')) return;
    await fetch(`/api/rules/${id}`, { method: 'DELETE' });
    loadRules();
}

function openEdit(id) {
    const r = rules.find(x => x.id === id);
    document.getElementById('edit_id').value = r.id;
    document.getElementById('edit_name').value = r.name;
    document.getElementById('edit_listen').value = r.listen;
    document.getElementById('edit_remote').value = r.remote;
    document.getElementById('editModal').style.display = 'flex';
}
async function saveEdit() {
    const id = document.getElementById('edit_id').value;
    const name = document.getElementById('edit_name').value;
    const listen = document.getElementById('edit_listen').value;
    const remote = document.getElementById('edit_remote').value;
    await fetch(`/api/rules/${id}`, { method: 'PUT', headers: {'Content-Type':'application/json'}, body: JSON.stringify({name, listen, remote}) });
    closeModal('editModal');
    loadRules();
}


function openAdmin() { document.getElementById('adminModal').style.display = 'flex'; }
async function saveAdmin() {
    const u = document.getElementById('admin_user').value;
    const p = document.getElementById('admin_pass').value;
    if(!u) return alert('用户名不能为空');
    await fetch('/api/admin', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({username:u, password:p}) });
    alert('设置已保存，请重新登录');
    location.reload();
}

function closeModal(id) { document.getElementById(id).style.display = 'none'; }
loadRules();
</script>
</body>
</html>
"#;
EOF

# 6. 添加 UUID 依赖 (为了唯一ID)
sed -i '/\[dependencies\]/a uuid = { version = "1", features = ["v4"] }' Cargo.toml

# 7. 编译
echo -e "${GREEN}>>> 开始编译 (Pro版功能较多，需等待约 3-5 分钟)...${RESET}"
cargo build --release

# 8. 安装
if [ -f "target/release/realm-panel-pro" ]; then
    echo -e "${GREEN}编译成功，正在安装...${RESET}"
    mv target/release/realm-panel-pro "$BINARY_PATH"
else
    echo -e "${RED}编译失败，请检查上方日志。${RESET}"
    exit 1
fi

# 9. 清理
cd /
rm -rf "$WORK_DIR"

# 10. 服务配置
cat > /etc/systemd/system/realm-panel.service <<EOF
[Unit]
Description=Realm Pro Panel
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

# 11. 启动
systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl start realm >/dev/null 2>&1
systemctl enable realm-panel >/dev/null 2>&1
systemctl restart realm-panel

# 12. 完成
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}🎉 Realm 转发面板 (Rust) 部署成功！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"
echo -e "💡 提示: 首次登录后，请在右上角【设置】中修改密码。"
