use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use axum::extract::ws::{Message as AxumMessage, WebSocket, WebSocketUpgrade};
use axum::extract::ConnectInfo;
use axum::extract::{Path as AxumPath, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::{broadcast, mpsc, Mutex};
use tracing::{info, warn};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

#[derive(Clone)]
enum BroadcastMsg {
    Text(String),
    Binary(Vec<u8>),
}

struct AppState {
    sessions: Arc<Mutex<HashMap<String, Arc<PtySession>>>>,
    lan_broadcast: broadcast::Sender<BroadcastMsg>,
    wormhole_broadcast: broadcast::Sender<BroadcastMsg>,
    config_id: Option<String>,
    host_name: String,
    shell: String,
    dev_mode: bool,
    bind: IpAddr,
    port: u16,
    wormhole_url: Option<String>,
    wormhole_requested_session: Option<String>,
    wormhole_has_token: bool,
    lan_client_count: AtomicUsize,
    wormhole_state: Mutex<WormholeState>,
    data_dir: PathBuf,
    paired_devices: Mutex<Vec<PairedDevice>>,
    pending_pairing: Mutex<Option<PendingPairing>>,
    wormhole_sender: Mutex<Option<mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>>>,
    groups: Mutex<Vec<TerminalGroup>>,
    session_names: Mutex<HashMap<String, String>>,
}

#[derive(Default, Clone)]
struct WormholeState {
    connected: bool,
    session_id: Option<String>,
    last_error_kind: Option<String>,
    last_error: Option<String>,
    last_error_at: Option<String>,
}

#[cfg(unix)]
struct PtySession {
    session_id: String,
    master_fd: std::os::fd::RawFd,
    child_pid: i32,
    history: std::sync::Mutex<Vec<u8>>,
    closed: std::sync::atomic::AtomicBool,
}

#[cfg(windows)]
struct PtySession {
    session_id: String,
    conpty: winconpty::ConPty,
    history: std::sync::Mutex<Vec<u8>>,
    closed: std::sync::atomic::AtomicBool,
}

#[cfg(not(any(unix, windows)))]
struct PtySession {
    session_id: String,
    history: std::sync::Mutex<Vec<u8>>,
}

const MAX_HISTORY_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PendingPairing {
    device_key: Option<String>,
    device_name: String,
    requested_at: String,
    device_type: Option<String>,
    public_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairedDevice {
    device_key: String,
    device_name: String,
    first_paired_at: String,
    last_seen_at: String,
    device_type: Option<String>,
    public_key: Option<String>,
    shared_secret: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct PairedDevicesFile {
    #[serde(default)]
    devices: Vec<PairedDevice>,
    #[serde(default)]
    settings: serde_json::Value,
}

// ============ Group Management ============

const DEFAULT_GROUP_ID: &str = "default";
const DEFAULT_GROUP_NAME: &str = "Default";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TerminalGroup {
    id: String,
    name: String,
    session_ids: Vec<String>,
    created_at: String,
    sort_order: i32,
}

impl TerminalGroup {
    fn new_default() -> Self {
        Self {
            id: DEFAULT_GROUP_ID.to_string(),
            name: DEFAULT_GROUP_NAME.to_string(),
            session_ids: Vec::new(),
            created_at: now_iso8601(),
            sort_order: 0,
        }
    }

    fn is_default(&self) -> bool {
        self.id == DEFAULT_GROUP_ID
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GroupStorage {
    #[serde(default)]
    version: i32,
    #[serde(default)]
    groups: Vec<TerminalGroup>,
    #[serde(default)]
    session_names: HashMap<String, String>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let config = match parse_args(std::env::args().skip(1).collect()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };

    let (lan_tx, _) = broadcast::channel::<BroadcastMsg>(512);
    let (wormhole_tx, _) = broadcast::channel::<BroadcastMsg>(512);
    let data_dir = resolve_data_dir();
    let paired_devices = load_paired_devices(&data_dir).unwrap_or_default();
    let (groups, session_names) = load_groups(&data_dir);
    let state = Arc::new(AppState {
        sessions: Arc::new(Mutex::new(HashMap::new())),
        lan_broadcast: lan_tx,
        wormhole_broadcast: wormhole_tx,
        config_id: config.config_id.clone(),
        host_name: config.host_name.clone(),
        shell: config.shell.clone(),
        dev_mode: config.dev_mode,
        bind: config.bind,
        port: config.port,
        wormhole_url: config.wormhole_url.clone(),
        wormhole_requested_session: config.custom_session.clone(),
        wormhole_has_token: config
            .wormhole_token
            .as_ref()
            .is_some_and(|v| !v.trim().is_empty()),
        lan_client_count: AtomicUsize::new(0),
        wormhole_state: Mutex::new(WormholeState::default()),
        data_dir,
        paired_devices: Mutex::new(paired_devices),
        pending_pairing: Mutex::new(None),
        wormhole_sender: Mutex::new(None),
        groups: Mutex::new(groups),
        session_names: Mutex::new(session_names),
    });

    let pid_path = daemon_pid_path(&state.data_dir);
    if let Err(err) = write_pid_file_exclusive(&pid_path) {
        if err.kind() == std::io::ErrorKind::AlreadyExists {
            eprintln!("{err}");
            std::process::exit(0);
        }
        warn!("failed to write pidfile {pid_path:?}: {err}");
    }

    if !config.no_initial_session {
        match create_session(&state).await {
            Ok(session_id) => info!("started initial session: {session_id}"),
            Err(err) => warn!("failed to start initial session: {err}"),
        }
    }

    if let Some(wormhole_url) = config.wormhole_url.clone() {
        let state_for_wormhole = state.clone();
        tokio::spawn(async move {
            run_wormhole(
                state_for_wormhole,
                wormhole_url,
                config.wormhole_token,
                config.custom_session,
            )
            .await;
        });
    }

    #[cfg(unix)]
    install_signal_handlers();

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/status", get(status_handler))
        .route("/shutdown", post(shutdown_handler))
        .route("/pairing/pending", get(pairing_pending))
        .route("/pairing/approve", post(pairing_approve))
        .route("/pairing/reject", post(pairing_reject))
        .route("/paired-devices", get(paired_devices_list))
        .route("/paired-devices/:key", delete(paired_devices_delete))
        .route("/ws", get(ws_handler))
        .with_state(state.clone());

    let addr = SocketAddr::new(config.bind, config.port);
    info!("horizon-daemon listening on {addr}");
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(err) => {
            warn!("failed to bind {addr}: {err}");
            let _ = fs::remove_file(&pid_path);
            std::process::exit(1);
        }
    };
    let result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await;

    if let Err(err) = result {
        warn!("server ended with error: {err}");
    }

    let _ = fs::remove_file(&pid_path);
}

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<Arc<AppState>>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_lan_socket(state, socket))
}

async fn handle_lan_socket(state: Arc<AppState>, socket: WebSocket) {
    state.lan_client_count.fetch_add(1, Ordering::SeqCst);
    let (mut sink, mut stream) = socket.split();
    let mut broadcast_rx = state.lan_broadcast.subscribe();

    // Initial info.
    let host_info = encode_json(json!({"type": "host_info", "hostName": state.host_name}));
    if sink.send(AxumMessage::Text(host_info)).await.is_err() {
        return;
    }
    if send_session_list(&state, &mut sink).await.is_err() {
        return;
    }

    loop {
        tokio::select! {
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { break };
                if handle_lan_incoming(&state, msg, &mut sink).await.is_err() {
                    break;
                }
            }
            out = broadcast_rx.recv() => {
                let Ok(out) = out else { break };
                let msg = match out {
                    BroadcastMsg::Text(text) => AxumMessage::Text(text),
                    BroadcastMsg::Binary(bytes) => AxumMessage::Binary(bytes),
                };
                if sink.send(msg).await.is_err() {
                    break;
                }
            }
        }
    }

    state.lan_client_count.fetch_sub(1, Ordering::SeqCst);
}

async fn status_handler(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let sessions = state.sessions.lock().await;
    let session_count = sessions.len();
    drop(sessions);

    let wormhole = state.wormhole_state.lock().await.clone();
    let pending = state.pending_pairing.lock().await.clone();

    axum::Json(json!({
        "configId": state.config_id,
        "hostName": state.host_name,
        "lan": {
            "bind": state.bind.to_string(),
            "port": state.port,
            "ws": format!("ws://{}:{}/ws", state.bind, state.port),
            "clients": state.lan_client_count.load(Ordering::SeqCst),
        },
        "wormhole": {
            "url": state.wormhole_url,
            "connected": wormhole.connected,
            "sessionId": wormhole.session_id,
            "requestedSession": state.wormhole_requested_session,
            "hasToken": state.wormhole_has_token,
            "lastErrorKind": wormhole.last_error_kind,
            "lastError": wormhole.last_error,
            "lastErrorAt": wormhole.last_error_at,
        },
        "devMode": state.dev_mode,
        "sessions": session_count,
        "pairing": {
            "pending": pending.is_some(),
        }
    }))
    .into_response()
}

async fn shutdown_handler(ConnectInfo(addr): ConnectInfo<SocketAddr>) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
    (StatusCode::ACCEPTED, "shutting down").into_response()
}

async fn pairing_pending(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let pending = state.pending_pairing.lock().await.clone();
    axum::Json(json!({ "pending": pending })).into_response()
}

#[derive(Debug, Deserialize)]
struct PairingApproveBody {
    remember: Option<bool>,
}

async fn pairing_approve(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
    axum::Json(body): axum::Json<PairingApproveBody>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let remember = body.remember.unwrap_or(false);

    let pending = { state.pending_pairing.lock().await.take() };
    let Some(pending) = pending else {
        return (StatusCode::NO_CONTENT, "").into_response();
    };

    let original_device_key = pending.device_key.clone();
    let assigned_key = pending
        .device_key
        .clone()
        .unwrap_or_else(generate_device_key);

    if remember {
        let now = now_iso8601();
        let mut devices = state.paired_devices.lock().await;
        let existing = devices.iter_mut().find(|d| d.device_key == assigned_key);
        if let Some(existing) = existing {
            existing.device_name = pending.device_name.clone();
            existing.last_seen_at = now.clone();
            existing.device_type = pending.device_type.clone();
            existing.public_key = pending.public_key.clone();
        } else {
            devices.push(PairedDevice {
                device_key: assigned_key.clone(),
                device_name: pending.device_name.clone(),
                first_paired_at: now.clone(),
                last_seen_at: now,
                device_type: pending.device_type.clone(),
                public_key: pending.public_key.clone(),
                shared_secret: None,
            });
        }
        let _ = save_paired_devices(&state.data_dir, &devices);
    }

    send_pairing_response(
        &state,
        original_device_key.as_deref(),
        true,
        Some(&assigned_key),
    )
    .await;

    (StatusCode::OK, "ok").into_response()
}

async fn pairing_reject(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let pending = { state.pending_pairing.lock().await.take() };
    let Some(pending) = pending else {
        return (StatusCode::NO_CONTENT, "").into_response();
    };

    send_pairing_response(&state, pending.device_key.as_deref(), false, None).await;
    (StatusCode::OK, "ok").into_response()
}

async fn paired_devices_list(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let devices = state.paired_devices.lock().await.clone();
    axum::Json(json!({ "devices": devices })).into_response()
}

async fn paired_devices_delete(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<Arc<AppState>>,
    AxumPath(key): AxumPath<String>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let mut devices = state.paired_devices.lock().await;
    let before = devices.len();
    devices.retain(|d| d.device_key != key);
    if devices.len() != before {
        let _ = save_paired_devices(&state.data_dir, &devices);
    }
    (StatusCode::OK, "ok").into_response()
}

async fn send_pairing_response(
    state: &Arc<AppState>,
    device_key: Option<&str>,
    approved: bool,
    assigned_key: Option<&str>,
) {
    let Some(tx) = state.wormhole_sender.lock().await.clone() else {
        return;
    };
    let msg = encode_json(json!({
        "type": "pairing_response",
        "deviceKey": device_key,
        "approved": approved,
        "assignedKey": assigned_key,
    }));
    let _ = tx.send(tokio_tungstenite::tungstenite::Message::Text(msg));
}

fn resolve_data_dir() -> PathBuf {
    let home = std::env::var("HOME")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| {
            std::env::var("USERPROFILE")
                .ok()
                .filter(|v| !v.trim().is_empty())
        });
    let base = home
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join(".blackhole").join("horizon")
}

fn paired_devices_path(dir: &Path) -> PathBuf {
    dir.join("paired_devices.json")
}

fn daemon_pid_path(dir: &Path) -> PathBuf {
    dir.join("daemon.pid")
}

fn write_pid_file_exclusive(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(mut file) => {
            writeln!(file, "{}", std::process::id())?;
            Ok(())
        }
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            if let Ok(text) = fs::read_to_string(path) {
                if let Ok(pid) = text.trim().parse::<u32>() {
                    if pid_is_running(pid) {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            format!("horizon-daemon already running (pid={pid})"),
                        ));
                    }
                }
            }
            let _ = fs::remove_file(path);
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)?;
            writeln!(file, "{}", std::process::id())?;
            Ok(())
        }
        Err(err) => Err(err),
    }
}

fn pid_is_running(pid: u32) -> bool {
    #[cfg(unix)]
    unsafe {
        let rc = libc::kill(pid as i32, 0);
        if rc == 0 {
            return true;
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(code) if code == libc::EPERM => true,
            _ => false,
        }
    }
    #[cfg(windows)]
    {
        winconpty::pid_is_running(pid)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = pid;
        false
    }
}

#[cfg(unix)]
fn install_signal_handlers() {
    unsafe {
        libc::signal(libc::SIGTERM, handle_shutdown_signal as libc::sighandler_t);
        libc::signal(libc::SIGINT, handle_shutdown_signal as libc::sighandler_t);
    }
}

#[cfg(unix)]
extern "C" fn handle_shutdown_signal(_sig: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
}

async fn shutdown_signal() {
    loop {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

fn load_paired_devices(dir: &Path) -> std::io::Result<Vec<PairedDevice>> {
    let path = paired_devices_path(dir);
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(path)?;
    let parsed: PairedDevicesFile = serde_json::from_str(&content).unwrap_or_default();
    Ok(parsed.devices)
}

fn save_paired_devices(dir: &Path, devices: &[PairedDevice]) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let file = PairedDevicesFile {
        devices: devices.to_vec(),
        settings: serde_json::Value::Object(Default::default()),
    };
    let text =
        serde_json::to_string_pretty(&file).unwrap_or_else(|_| "{\"devices\":[]}".to_string());
    fs::write(paired_devices_path(dir), text)
}

// ============ Group Storage ============

fn groups_path(dir: &Path) -> PathBuf {
    dir.join("terminal_groups.json")
}

fn load_groups(dir: &Path) -> (Vec<TerminalGroup>, HashMap<String, String>) {
    let path = groups_path(dir);
    if !path.exists() {
        return (vec![TerminalGroup::new_default()], HashMap::new());
    }
    match fs::read_to_string(&path) {
        Ok(content) => {
            let storage: GroupStorage = serde_json::from_str(&content).unwrap_or_default();
            let mut groups = storage.groups;
            if groups.is_empty() || !groups.iter().any(|g| g.is_default()) {
                groups.insert(0, TerminalGroup::new_default());
            }
            (groups, storage.session_names)
        }
        Err(_) => (vec![TerminalGroup::new_default()], HashMap::new()),
    }
}

fn save_groups(dir: &Path, groups: &[TerminalGroup], session_names: &HashMap<String, String>) {
    let storage = GroupStorage {
        version: 1,
        groups: groups.to_vec(),
        session_names: session_names.clone(),
    };
    if let Ok(text) = serde_json::to_string_pretty(&storage) {
        let _ = fs::create_dir_all(dir);
        let _ = fs::write(groups_path(dir), text);
    }
}

fn ensure_default_group(groups: &mut Vec<TerminalGroup>) -> bool {
    if groups.iter().any(|g| g.is_default()) {
        return false;
    }
    groups.insert(0, TerminalGroup::new_default());
    true
}

fn find_group_index(groups: &[TerminalGroup], id: &str) -> Option<usize> {
    groups.iter().position(|g| g.id == id)
}

fn default_group_mut(groups: &mut Vec<TerminalGroup>) -> &mut TerminalGroup {
    ensure_default_group(groups);
    groups.iter_mut().find(|g| g.is_default()).unwrap()
}

fn next_group_name(groups: &[TerminalGroup]) -> String {
    let existing: std::collections::HashSet<_> = groups.iter().map(|g| g.name.as_str()).collect();
    let mut index = 1;
    loop {
        let name = format!("Group {}", index);
        if !existing.contains(name.as_str()) {
            return name;
        }
        index += 1;
    }
}

fn remove_session_from_all_groups(groups: &mut [TerminalGroup], session_id: &str) {
    for group in groups.iter_mut() {
        group.session_ids.retain(|id| id != session_id);
    }
}

fn cleanup_empty_groups(groups: &mut Vec<TerminalGroup>) -> bool {
    let before = groups.len();
    groups.retain(|g| g.is_default() || !g.session_ids.is_empty());
    groups.len() != before
}

fn reconcile_groups_with_sessions(
    groups: &mut Vec<TerminalGroup>,
    active_sessions: &std::collections::HashSet<String>,
) -> bool {
    let mut changed = ensure_default_group(groups);

    // Remove sessions that no longer exist
    for group in groups.iter_mut() {
        let before = group.session_ids.len();
        group.session_ids.retain(|id| active_sessions.contains(id));
        if group.session_ids.len() != before {
            changed = true;
        }
    }

    // Find sessions not in any group
    let assigned: std::collections::HashSet<_> = groups
        .iter()
        .flat_map(|g| g.session_ids.iter().cloned())
        .collect();

    let missing: Vec<_> = active_sessions
        .iter()
        .filter(|id| !assigned.contains(*id))
        .cloned()
        .collect();

    if !missing.is_empty() {
        let default = default_group_mut(groups);
        for session_id in missing {
            if !default.session_ids.contains(&session_id) {
                default.session_ids.push(session_id);
            }
        }
        changed = true;
    }

    if cleanup_empty_groups(groups) {
        changed = true;
    }

    changed
}

fn build_group_sync_payload(
    groups: &[TerminalGroup],
    session_names: &HashMap<String, String>,
) -> serde_json::Value {
    json!({
        "type": "group_sync",
        "version": 1,
        "groups": groups,
        "sessionNames": session_names,
    })
}

fn broadcast_group_sync(
    state: &Arc<AppState>,
    groups: &[TerminalGroup],
    names: &HashMap<String, String>,
) {
    let payload = build_group_sync_payload(groups, names);
    let msg = BroadcastMsg::Text(encode_json(payload));
    let _ = state.lan_broadcast.send(msg.clone());
    let _ = state.wormhole_broadcast.send(msg);
}

fn generate_group_id() -> String {
    // Simple UUID-like ID
    let mut rng = rand::thread_rng();
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        rng.gen::<u32>(),
        rng.gen::<u16>(),
        rng.gen::<u16>(),
        rng.gen::<u16>(),
        rng.gen::<u64>() & 0xffffffffffff
    )
}

fn now_iso8601() -> String {
    #[cfg(unix)]
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::gmtime_r(&t, &mut tm);
        let mut buf = [0i8; 32];
        let fmt = b"%Y-%m-%dT%H:%M:%SZ\0";
        let _ = libc::strftime(buf.as_mut_ptr(), buf.len(), fmt.as_ptr() as *const i8, &tm);
        return std::ffi::CStr::from_ptr(buf.as_ptr())
            .to_string_lossy()
            .to_string();
    }
    #[cfg(windows)]
    {
        return winconpty::now_iso8601();
    }
    #[cfg(not(any(unix, windows)))]
    {
        "1970-01-01T00:00:00Z".to_string()
    }
}

async fn handle_lan_incoming(
    state: &Arc<AppState>,
    msg: AxumMessage,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) -> Result<(), ()> {
    match msg {
        AxumMessage::Text(text) => {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                return Ok(());
            };
            let version = value.get("v").and_then(|v| v.as_i64()).unwrap_or(1);
            if version != 1 {
                let _ = sink
                    .send(AxumMessage::Text(encode_json(json!({
                        "type": "error",
                        "code": "unsupported_version",
                        "message": "Unsupported protocol version",
                    }))))
                    .await;
                return Ok(());
            }
            let Some(ty) = value.get("type").and_then(|t| t.as_str()) else {
                return Ok(());
            };

            match ty {
                "ping" => {
                    let _ = sink.send(AxumMessage::Binary(build_pong_message())).await;
                }
                "list" => {
                    let _ = send_session_list(state, sink).await;
                }
                "create" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let session_id = create_session_in_group(state, group_id)
                        .await
                        .map_err(|_| ())?;
                    // Reply to requester (LAN behavior).
                    let msg = encode_json(json!({
                        "type": "session_created",
                        "sessionId": session_id,
                    }));
                    let _ = sink.send(AxumMessage::Text(msg.clone())).await;
                    // Also notify wormhole clients, to match current Horizon behavior.
                    let _ = state.wormhole_broadcast.send(BroadcastMsg::Text(msg));
                }
                "close" => {
                    let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) else {
                        return Ok(());
                    };
                    close_session(state, session_id).await;
                }
                "sync" => {
                    let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) else {
                        return Ok(());
                    };
                    let content = get_history(state, session_id).await.unwrap_or_default();
                    let _ = sink
                        .send(AxumMessage::Text(encode_json(json!({
                            "type": "session_sync",
                            "sessionId": session_id,
                            "content": content,
                        }))))
                        .await;
                }
                // Group management
                "group_list" => {
                    handle_group_list(state, sink).await;
                }
                "group_create" => {
                    let name = value.get("name").and_then(|v| v.as_str());
                    handle_group_create(state, name, sink).await;
                }
                "group_rename" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let name = value.get("name").and_then(|v| v.as_str());
                    if let (Some(gid), Some(n)) = (group_id, name) {
                        handle_group_rename(state, gid, n, sink).await;
                    }
                }
                "group_delete" => {
                    if let Some(group_id) = value.get("groupId").and_then(|v| v.as_str()) {
                        handle_group_delete(state, group_id, false, sink).await;
                    }
                }
                "group_delete_with_sessions" => {
                    if let Some(group_id) = value.get("groupId").and_then(|v| v.as_str()) {
                        handle_group_delete(state, group_id, true, sink).await;
                    }
                }
                "group_move_session" => {
                    let session_id = value.get("sessionId").and_then(|v| v.as_str());
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let old_index = value
                        .get("oldIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    let new_index = value
                        .get("newIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    if let (Some(sid), Some(gid)) = (session_id, group_id) {
                        handle_group_move_session(state, sid, gid, old_index, new_index, sink)
                            .await;
                    }
                }
                "group_reorder" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let new_index = value
                        .get("newIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    if let (Some(gid), Some(idx)) = (group_id, new_index) {
                        handle_group_reorder(state, gid, idx, sink).await;
                    }
                }
                "session_rename" => {
                    let session_id = value.get("sessionId").and_then(|v| v.as_str());
                    let name = value.get("name").and_then(|v| v.as_str());
                    if let (Some(sid), Some(n)) = (session_id, name) {
                        handle_session_rename(state, sid, n, sink).await;
                    }
                }
                "getCwd" => {
                    if let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) {
                        handle_get_cwd(state, session_id, sink).await;
                    }
                }
                _ => {}
            }
        }
        AxumMessage::Binary(bytes) => {
            let Some(decoded) = decode_binary(&bytes) else {
                return Ok(());
            };
            match decoded.ty {
                BinaryType::Stdin => {
                    write_stdin(state, &decoded.session_id, &decoded.payload).await;
                }
                BinaryType::Resize => {
                    if decoded.payload.len() < 4 {
                        return Ok(());
                    }
                    let rows = u16::from_be_bytes([decoded.payload[0], decoded.payload[1]]);
                    let cols = u16::from_be_bytes([decoded.payload[2], decoded.payload[3]]);
                    resize_session(state, &decoded.session_id, rows, cols).await;
                }
                BinaryType::Ping => {
                    let _ = sink.send(AxumMessage::Binary(build_pong_message())).await;
                }
                BinaryType::Pong | BinaryType::Stdout => {}
            }
        }
        AxumMessage::Close(_) => return Err(()),
        AxumMessage::Ping(_) | AxumMessage::Pong(_) => {}
    }
    Ok(())
}

async fn send_session_list(
    state: &Arc<AppState>,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) -> Result<(), ()> {
    let ids = list_session_ids(state).await;
    sink.send(AxumMessage::Text(encode_json(json!({
        "type": "session_list",
        "sessions": ids,
    }))))
    .await
    .map_err(|_| ())?;

    // Send host_info
    let _ = sink
        .send(AxumMessage::Text(encode_json(json!({
            "type": "host_info",
            "hostName": state.host_name,
        }))))
        .await;

    // Reconcile and send group_sync
    let mut groups = state.groups.lock().await;
    let active_sessions: std::collections::HashSet<_> = ids.into_iter().collect();
    let changed = reconcile_groups_with_sessions(&mut groups, &active_sessions);
    let session_names = state.session_names.lock().await;
    if changed {
        save_groups(&state.data_dir, &groups, &session_names);
    }
    let _ = sink
        .send(AxumMessage::Text(encode_json(build_group_sync_payload(
            &groups,
            &session_names,
        ))))
        .await;

    Ok(())
}

async fn list_session_ids(state: &Arc<AppState>) -> Vec<String> {
    let sessions = state.sessions.lock().await;
    sessions.keys().cloned().collect()
}

async fn create_session(state: &Arc<AppState>) -> std::io::Result<String> {
    create_session_in_group(state, None).await
}

async fn create_session_in_group(
    state: &Arc<AppState>,
    group_id: Option<&str>,
) -> std::io::Result<String> {
    let session_id = generate_session_id();
    let arc = Arc::new(spawn_pty_session(&session_id, &state.shell)?);
    start_output_thread(state.clone(), arc.clone());

    let mut sessions = state.sessions.lock().await;
    sessions.insert(session_id.clone(), arc);
    drop(sessions);

    // Add session to group
    let mut groups = state.groups.lock().await;
    if let Some(gid) = group_id {
        if let Some(target) = groups.iter_mut().find(|g| g.id == gid) {
            if !target.session_ids.contains(&session_id) {
                target.session_ids.push(session_id.clone());
            }
        } else {
            // Group not found, add to default
            let default = default_group_mut(&mut groups);
            if !default.session_ids.contains(&session_id) {
                default.session_ids.push(session_id.clone());
            }
        }
    } else {
        // Add to default group
        let default = default_group_mut(&mut groups);
        if !default.session_ids.contains(&session_id) {
            default.session_ids.push(session_id.clone());
        }
    }

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);

    Ok(session_id)
}

async fn close_session(state: &Arc<AppState>, session_id: &str) {
    let session = {
        let mut sessions = state.sessions.lock().await;
        sessions.remove(session_id)
    };
    let Some(session) = session else {
        return;
    };
    session.cleanup();

    // Remove from groups
    let mut groups = state.groups.lock().await;
    let before_len: usize = groups.iter().map(|g| g.session_ids.len()).sum();
    for group in groups.iter_mut() {
        group.session_ids.retain(|id| id != session_id);
    }
    let after_len: usize = groups.iter().map(|g| g.session_ids.len()).sum();
    let mut changed = before_len != after_len;

    // Remove session name
    let mut session_names = state.session_names.lock().await;
    if session_names.remove(session_id).is_some() {
        changed = true;
    }

    // Cleanup empty groups
    if cleanup_empty_groups(&mut groups) {
        changed = true;
    }

    if changed {
        save_groups(&state.data_dir, &groups, &session_names);
        broadcast_group_sync(state, &groups, &session_names);
    }
    drop(groups);
    drop(session_names);

    let msg = encode_json(json!({
        "type": "session_closed",
        "sessionId": session_id,
    }));
    let _ = state.lan_broadcast.send(BroadcastMsg::Text(msg.clone()));
    let _ = state.wormhole_broadcast.send(BroadcastMsg::Text(msg));
}

#[cfg(unix)]
async fn write_stdin(state: &Arc<AppState>, session_id: &str, data: &[u8]) {
    let sessions = state.sessions.lock().await;
    let Some(session) = sessions.get(session_id) else {
        return;
    };
    unsafe {
        let _ = libc::write(
            session.master_fd,
            data.as_ptr() as *const libc::c_void,
            data.len(),
        );
    }
}

#[cfg(windows)]
async fn write_stdin(state: &Arc<AppState>, session_id: &str, data: &[u8]) {
    let sessions = state.sessions.lock().await;
    let Some(session) = sessions.get(session_id) else {
        return;
    };
    let _ = session.conpty.write_stdin(data);
}

#[cfg(not(any(unix, windows)))]
async fn write_stdin(_state: &Arc<AppState>, _session_id: &str, _data: &[u8]) {}

#[cfg(unix)]
async fn resize_session(state: &Arc<AppState>, session_id: &str, rows: u16, cols: u16) {
    let sessions = state.sessions.lock().await;
    let Some(session) = sessions.get(session_id) else {
        return;
    };
    let winsz = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    unsafe {
        let _ = libc::ioctl(session.master_fd, libc::TIOCSWINSZ as libc::c_ulong, &winsz);
    }
}

#[cfg(windows)]
async fn resize_session(state: &Arc<AppState>, session_id: &str, rows: u16, cols: u16) {
    let sessions = state.sessions.lock().await;
    let Some(session) = sessions.get(session_id) else {
        return;
    };
    let _ = session.conpty.resize(rows, cols);
}

#[cfg(not(any(unix, windows)))]
async fn resize_session(_state: &Arc<AppState>, _session_id: &str, _rows: u16, _cols: u16) {}

async fn get_history(state: &Arc<AppState>, session_id: &str) -> Option<String> {
    let sessions = state.sessions.lock().await;
    let session = sessions.get(session_id)?.clone();
    drop(sessions);

    let bytes = session.history.lock().ok()?.clone();
    Some(String::from_utf8_lossy(&bytes).to_string())
}

fn encode_json(value: serde_json::Value) -> String {
    let mut obj = value;
    if let serde_json::Value::Object(ref mut map) = obj {
        map.entry("v".to_string()).or_insert_with(|| json!(1));
    }
    obj.to_string()
}

fn generate_session_id() -> String {
    const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    (0..8)
        .map(|_| {
            let idx = rng.gen_range(0..CHARSET.len());
            CHARSET[idx] as char
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BinaryType {
    Stdin,
    Stdout,
    Resize,
    Ping,
    Pong,
}

struct DecodedBinary {
    ty: BinaryType,
    session_id: String,
    payload: Vec<u8>,
}

fn decode_binary(data: &[u8]) -> Option<DecodedBinary> {
    if data.len() < 4 {
        return None;
    }
    if data[0] != 1 {
        return None;
    }
    let ty = match data[1] {
        1 => BinaryType::Stdin,
        2 => BinaryType::Stdout,
        3 => BinaryType::Resize,
        4 => BinaryType::Ping,
        5 => BinaryType::Pong,
        _ => return None,
    };
    let session_len = u16::from_be_bytes([data[2], data[3]]) as usize;
    if data.len() < 4 + session_len {
        return None;
    }
    let session_id = String::from_utf8_lossy(&data[4..4 + session_len]).to_string();
    let payload = data[4 + session_len..].to_vec();
    Some(DecodedBinary {
        ty,
        session_id,
        payload,
    })
}

fn encode_binary(ty: BinaryType, session_id: &str, payload: &[u8]) -> Vec<u8> {
    let sid = session_id.as_bytes();
    let mut out = Vec::with_capacity(4 + sid.len() + payload.len());
    out.push(1);
    out.push(match ty {
        BinaryType::Stdin => 1,
        BinaryType::Stdout => 2,
        BinaryType::Resize => 3,
        BinaryType::Ping => 4,
        BinaryType::Pong => 5,
    });
    let len = (sid.len() as u16).to_be_bytes();
    out.extend_from_slice(&len);
    out.extend_from_slice(sid);
    out.extend_from_slice(payload);
    out
}

fn build_pong_message() -> Vec<u8> {
    encode_binary(BinaryType::Pong, "", &[])
}

fn build_stdout_message(session_id: &str, payload: &[u8]) -> Vec<u8> {
    encode_binary(BinaryType::Stdout, session_id, payload)
}

fn append_history(history: &std::sync::Mutex<Vec<u8>>, data: &[u8]) {
    let Ok(mut buf) = history.lock() else {
        return;
    };
    buf.extend_from_slice(data);
    if buf.len() <= MAX_HISTORY_BYTES {
        return;
    }
    let keep_from = buf.len().saturating_sub(MAX_HISTORY_BYTES / 2);
    let mut cut = keep_from;
    for i in keep_from..buf.len() {
        if buf[i] == b'\n' {
            cut = i + 1;
            break;
        }
    }
    buf.drain(0..cut);
}

#[cfg(unix)]
fn start_output_thread(state: Arc<AppState>, session: Arc<PtySession>) {
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 8192];
        loop {
            let n = unsafe {
                libc::read(
                    session.master_fd,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                )
            };
            if n <= 0 {
                break;
            }
            let chunk = &buf[..n as usize];
            append_history(&session.history, chunk);
            let msg = BroadcastMsg::Binary(build_stdout_message(&session.session_id, chunk));
            let _ = state.lan_broadcast.send(msg.clone());
            let _ = state.wormhole_broadcast.send(msg);
        }
    });
}

#[cfg(windows)]
fn start_output_thread(state: Arc<AppState>, session: Arc<PtySession>) {
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 8192];
        loop {
            let n = match session.conpty.read_stdout(&mut buf) {
                Ok(n) => n,
                Err(_) => break,
            };
            if n == 0 {
                break;
            }
            let chunk = &buf[..n];
            append_history(&session.history, chunk);
            let msg = BroadcastMsg::Binary(build_stdout_message(&session.session_id, chunk));
            let _ = state.lan_broadcast.send(msg.clone());
            let _ = state.wormhole_broadcast.send(msg);
        }
    });
}

#[cfg(not(any(unix, windows)))]
fn start_output_thread(_state: Arc<AppState>, _session: Arc<PtySession>) {}

#[cfg(unix)]
impl Drop for PtySession {
    fn drop(&mut self) {
        self.cleanup();
    }
}

#[cfg(windows)]
impl Drop for PtySession {
    fn drop(&mut self) {
        self.cleanup();
    }
}

#[cfg(not(any(unix, windows)))]
impl Drop for PtySession {
    fn drop(&mut self) {}
}

#[cfg(unix)]
impl PtySession {
    fn cleanup(&self) {
        use std::sync::atomic::Ordering;
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        unsafe {
            libc::kill(self.child_pid, libc::SIGKILL);
            libc::close(self.master_fd);
            let mut status: i32 = 0;
            let _ = libc::waitpid(self.child_pid, &mut status as *mut i32, 0);
        }
    }
}

#[cfg(windows)]
impl PtySession {
    fn cleanup(&self) {
        use std::sync::atomic::Ordering;
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.conpty.cleanup();
    }
}

#[cfg(not(any(unix, windows)))]
impl PtySession {
    fn cleanup(&self) {}
}

#[cfg(unix)]
fn spawn_pty_session(session_id: &str, shell: &str) -> std::io::Result<PtySession> {
    use std::ffi::CString;
    use std::os::unix::io::FromRawFd;
    use std::os::unix::process::CommandExt;
    use std::process::Command;
    use std::process::Stdio;

    let master_fd = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) };
    if master_fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::grantpt(master_fd) } != 0 {
        unsafe { libc::close(master_fd) };
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::unlockpt(master_fd) } != 0 {
        unsafe { libc::close(master_fd) };
        return Err(std::io::Error::last_os_error());
    }
    let name_ptr = unsafe { libc::ptsname(master_fd) };
    if name_ptr.is_null() {
        unsafe { libc::close(master_fd) };
        return Err(std::io::Error::last_os_error());
    }
    let slave_name = unsafe { std::ffi::CStr::from_ptr(name_ptr) }
        .to_string_lossy()
        .to_string();
    let slave_name_c = CString::new(slave_name).unwrap();
    let slave_fd = unsafe { libc::open(slave_name_c.as_ptr(), libc::O_RDWR | libc::O_NOCTTY) };
    if slave_fd < 0 {
        unsafe { libc::close(master_fd) };
        return Err(std::io::Error::last_os_error());
    }

    let term = std::env::var("TERM")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "xterm-256color".to_string());
    let shell_path = if shell.is_empty() {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    } else {
        shell.to_string()
    };

    let stdin_fd = unsafe { libc::dup(slave_fd) };
    let stdout_fd = unsafe { libc::dup(slave_fd) };
    let stderr_fd = unsafe { libc::dup(slave_fd) };
    if stdin_fd < 0 || stdout_fd < 0 || stderr_fd < 0 {
        unsafe {
            libc::close(master_fd);
            libc::close(slave_fd);
            if stdin_fd >= 0 {
                libc::close(stdin_fd);
            }
            if stdout_fd >= 0 {
                libc::close(stdout_fd);
            }
            if stderr_fd >= 0 {
                libc::close(stderr_fd);
            }
        }
        return Err(std::io::Error::last_os_error());
    }

    let winsz = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    let mut cmd = Command::new(shell_path);
    cmd.env("TERM", term);
    cmd.stdin(unsafe { Stdio::from_raw_fd(stdin_fd) });
    cmd.stdout(unsafe { Stdio::from_raw_fd(stdout_fd) });
    cmd.stderr(unsafe { Stdio::from_raw_fd(stderr_fd) });

    let pre_exec = move || {
        unsafe {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let _ = libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0);
            let _ = libc::ioctl(slave_fd, libc::TIOCSWINSZ as libc::c_ulong, &winsz);
        }
        Ok(())
    };
    unsafe { cmd.pre_exec(pre_exec) };

    let child = cmd.spawn()?;
    let pid = child.id() as i32;

    unsafe { libc::close(slave_fd) };

    Ok(PtySession {
        session_id: session_id.to_string(),
        master_fd,
        child_pid: pid,
        history: std::sync::Mutex::new(Vec::<u8>::new()),
        closed: std::sync::atomic::AtomicBool::new(false),
    })
}

#[cfg(windows)]
fn spawn_pty_session(session_id: &str, shell: &str) -> std::io::Result<PtySession> {
    let conpty = winconpty::ConPty::spawn(shell, 24, 80)?;
    Ok(PtySession {
        session_id: session_id.to_string(),
        conpty,
        history: std::sync::Mutex::new(Vec::<u8>::new()),
        closed: std::sync::atomic::AtomicBool::new(false),
    })
}

#[cfg(not(any(unix, windows)))]
fn spawn_pty_session(_session_id: &str, _shell: &str) -> std::io::Result<PtySession> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "PTY is not implemented for this platform yet",
    ))
}

// ============ Group Message Handlers (LAN) ============

async fn handle_group_list(
    state: &Arc<AppState>,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let groups = state.groups.lock().await;
    let session_names = state.session_names.lock().await;
    let payload = build_group_sync_payload(&groups, &session_names);
    let _ = sink.send(AxumMessage::Text(encode_json(payload))).await;
}

async fn handle_group_create(
    state: &Arc<AppState>,
    name: Option<&str>,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let trimmed = name.map(|s| s.trim()).filter(|s| !s.is_empty());
    let group_id = generate_group_id();

    let mut groups = state.groups.lock().await;
    let group_name = trimmed
        .map(|s| s.to_string())
        .unwrap_or_else(|| next_group_name(&groups));
    let new_group = TerminalGroup {
        id: group_id.clone(),
        name: group_name,
        session_ids: Vec::new(),
        created_at: now_iso8601(),
        sort_order: groups.len() as i32,
    };
    groups.push(new_group);
    drop(groups);

    // Create a session in the new group
    if let Ok(session_id) = create_session_in_group(state, Some(&group_id)).await {
        let msg = encode_json(json!({
            "type": "session_created",
            "sessionId": session_id,
        }));
        let _ = sink.send(AxumMessage::Text(msg.clone())).await;
        let _ = state.wormhole_broadcast.send(BroadcastMsg::Text(msg));
    }

    let groups = state.groups.lock().await;
    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
}

async fn handle_group_rename(
    state: &Arc<AppState>,
    group_id: &str,
    name: &str,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        let _ = send_group_error(sink, "invalid_name", "Group name cannot be empty.").await;
        return;
    }

    let mut groups = state.groups.lock().await;
    if let Some(group) = groups.iter_mut().find(|g| g.id == group_id) {
        if group.name != trimmed {
            group.name = trimmed.to_string();
            let session_names = state.session_names.lock().await;
            save_groups(&state.data_dir, &groups, &session_names);
            broadcast_group_sync(state, &groups, &session_names);
        }
    } else {
        let _ = send_group_error(sink, "group_not_found", "Group not found.").await;
    }
}

async fn handle_group_delete(
    state: &Arc<AppState>,
    group_id: &str,
    close_sessions: bool,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    if group_id == DEFAULT_GROUP_ID {
        let _ = send_group_error(sink, "delete_default", "Default group cannot be deleted.").await;
        return;
    }

    let mut groups = state.groups.lock().await;
    let Some(idx) = find_group_index(&groups, group_id) else {
        let _ = send_group_error(sink, "group_not_found", "Group not found.").await;
        return;
    };

    let removed = groups.remove(idx);
    let sessions_to_close = removed.session_ids.clone();

    if !close_sessions {
        // Move sessions to default group
        let default = default_group_mut(&mut groups);
        for sid in &sessions_to_close {
            if !default.session_ids.contains(sid) {
                default.session_ids.push(sid.clone());
            }
        }
    }

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
    drop(groups);
    drop(session_names);

    if close_sessions {
        for sid in &sessions_to_close {
            close_session(state, sid).await;
        }
    }
}

async fn handle_group_move_session(
    state: &Arc<AppState>,
    session_id: &str,
    target_group_id: &str,
    old_index: Option<usize>,
    new_index: Option<usize>,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let mut groups = state.groups.lock().await;

    // Check if session exists
    let session_exists = groups
        .iter()
        .any(|g| g.session_ids.contains(&session_id.to_string()));
    if !session_exists {
        let _ = send_group_error(sink, "session_not_found", "Session not found.").await;
        return;
    }

    let Some(target_idx) = find_group_index(&groups, target_group_id) else {
        let _ = send_group_error(sink, "group_not_found", "Group not found.").await;
        return;
    };

    // Handle reordering within same group
    if let (Some(old_i), Some(new_i)) = (old_index, new_index) {
        let target = &mut groups[target_idx];
        if old_i < target.session_ids.len() && target.session_ids[old_i] == session_id {
            let moved = target.session_ids.remove(old_i);
            let insert_idx = if new_i > old_i { new_i - 1 } else { new_i };
            let insert_idx = insert_idx.min(target.session_ids.len());
            target.session_ids.insert(insert_idx, moved);
        }
    } else {
        // Move between groups
        remove_session_from_all_groups(&mut groups, session_id);
        let target = &mut groups[target_idx];
        if !target.session_ids.contains(&session_id.to_string()) {
            target.session_ids.push(session_id.to_string());
        }
        cleanup_empty_groups(&mut groups);
    }

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
}

async fn handle_group_reorder(
    state: &Arc<AppState>,
    group_id: &str,
    new_index: usize,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let mut groups = state.groups.lock().await;
    let Some(current_idx) = find_group_index(&groups, group_id) else {
        let _ = send_group_error(sink, "group_not_found", "Group not found.").await;
        return;
    };

    let new_idx = new_index.min(groups.len().saturating_sub(1));
    if current_idx != new_idx {
        let group = groups.remove(current_idx);
        groups.insert(new_idx, group);
        let session_names = state.session_names.lock().await;
        save_groups(&state.data_dir, &groups, &session_names);
        broadcast_group_sync(state, &groups, &session_names);
    }
}

async fn handle_session_rename(
    state: &Arc<AppState>,
    session_id: &str,
    name: &str,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let groups = state.groups.lock().await;
    let session_exists = groups
        .iter()
        .any(|g| g.session_ids.contains(&session_id.to_string()));
    if !session_exists {
        let _ = send_group_error(sink, "session_not_found", "Session not found.").await;
        return;
    }

    let mut session_names = state.session_names.lock().await;
    let trimmed = name.trim();
    let changed = if trimmed.is_empty() {
        session_names.remove(session_id).is_some()
    } else if session_names.get(session_id).map(|s| s.as_str()) != Some(trimmed) {
        session_names.insert(session_id.to_string(), trimmed.to_string());
        true
    } else {
        false
    };

    if changed {
        save_groups(&state.data_dir, &groups, &session_names);
        broadcast_group_sync(state, &groups, &session_names);
    }
}

async fn handle_get_cwd(
    state: &Arc<AppState>,
    session_id: &str,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    let cwd = get_session_cwd(state, session_id).await;
    let _ = sink
        .send(AxumMessage::Text(encode_json(json!({
            "type": "cwd",
            "sessionId": session_id,
            "cwd": cwd,
        }))))
        .await;
}

async fn send_group_error(
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
    code: &str,
    message: &str,
) -> Result<(), ()> {
    sink.send(AxumMessage::Text(encode_json(json!({
        "type": "group_error",
        "code": code,
        "message": message,
    }))))
    .await
    .map_err(|_| ())
}

// ============ Group Message Handlers (Wormhole) ============

type WormholeSink = futures_util::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    tokio_tungstenite::tungstenite::Message,
>;

async fn handle_group_list_wormhole(state: &Arc<AppState>, sink: &mut WormholeSink) {
    let groups = state.groups.lock().await;
    let session_names = state.session_names.lock().await;
    let payload = build_group_sync_payload(&groups, &session_names);
    let _ = sink
        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
            payload,
        )))
        .await;
}

async fn handle_group_create_wormhole(
    state: &Arc<AppState>,
    name: Option<&str>,
    sink: &mut WormholeSink,
) {
    let trimmed = name.map(|s| s.trim()).filter(|s| !s.is_empty());
    let group_id = generate_group_id();

    let mut groups = state.groups.lock().await;
    let group_name = trimmed
        .map(|s| s.to_string())
        .unwrap_or_else(|| next_group_name(&groups));
    let new_group = TerminalGroup {
        id: group_id.clone(),
        name: group_name,
        session_ids: Vec::new(),
        created_at: now_iso8601(),
        sort_order: groups.len() as i32,
    };
    groups.push(new_group);
    drop(groups);

    // Create a session in the new group
    if let Ok(session_id) = create_session_in_group(state, Some(&group_id)).await {
        let msg = encode_json(json!({
            "type": "session_created",
            "sessionId": session_id,
        }));
        let _ = state.lan_broadcast.send(BroadcastMsg::Text(msg.clone()));
        let _ = sink
            .send(tokio_tungstenite::tungstenite::Message::Text(msg))
            .await;
    }

    let groups = state.groups.lock().await;
    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
}

async fn handle_group_rename_wormhole(
    state: &Arc<AppState>,
    group_id: &str,
    name: &str,
    sink: &mut WormholeSink,
) {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        let _ =
            send_group_error_wormhole(sink, "invalid_name", "Group name cannot be empty.").await;
        return;
    }

    let mut groups = state.groups.lock().await;
    if let Some(group) = groups.iter_mut().find(|g| g.id == group_id) {
        if group.name != trimmed {
            group.name = trimmed.to_string();
            let session_names = state.session_names.lock().await;
            save_groups(&state.data_dir, &groups, &session_names);
            broadcast_group_sync(state, &groups, &session_names);
        }
    } else {
        let _ = send_group_error_wormhole(sink, "group_not_found", "Group not found.").await;
    }
}

async fn handle_group_delete_wormhole(
    state: &Arc<AppState>,
    group_id: &str,
    close_sessions: bool,
    sink: &mut WormholeSink,
) {
    if group_id == DEFAULT_GROUP_ID {
        let _ =
            send_group_error_wormhole(sink, "delete_default", "Default group cannot be deleted.")
                .await;
        return;
    }

    let mut groups = state.groups.lock().await;
    let Some(idx) = find_group_index(&groups, group_id) else {
        let _ = send_group_error_wormhole(sink, "group_not_found", "Group not found.").await;
        return;
    };

    let removed = groups.remove(idx);
    let sessions_to_close = removed.session_ids.clone();

    if !close_sessions {
        let default = default_group_mut(&mut groups);
        for sid in &sessions_to_close {
            if !default.session_ids.contains(sid) {
                default.session_ids.push(sid.clone());
            }
        }
    }

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
    drop(groups);
    drop(session_names);

    if close_sessions {
        for sid in &sessions_to_close {
            close_session(state, sid).await;
        }
    }
}

async fn handle_group_move_session_wormhole(
    state: &Arc<AppState>,
    session_id: &str,
    target_group_id: &str,
    old_index: Option<usize>,
    new_index: Option<usize>,
    sink: &mut WormholeSink,
) {
    let mut groups = state.groups.lock().await;

    let session_exists = groups
        .iter()
        .any(|g| g.session_ids.contains(&session_id.to_string()));
    if !session_exists {
        let _ = send_group_error_wormhole(sink, "session_not_found", "Session not found.").await;
        return;
    }

    let Some(target_idx) = find_group_index(&groups, target_group_id) else {
        let _ = send_group_error_wormhole(sink, "group_not_found", "Group not found.").await;
        return;
    };

    if let (Some(old_i), Some(new_i)) = (old_index, new_index) {
        let target = &mut groups[target_idx];
        if old_i < target.session_ids.len() && target.session_ids[old_i] == session_id {
            let moved = target.session_ids.remove(old_i);
            let insert_idx = if new_i > old_i { new_i - 1 } else { new_i };
            let insert_idx = insert_idx.min(target.session_ids.len());
            target.session_ids.insert(insert_idx, moved);
        }
    } else {
        remove_session_from_all_groups(&mut groups, session_id);
        let target = &mut groups[target_idx];
        if !target.session_ids.contains(&session_id.to_string()) {
            target.session_ids.push(session_id.to_string());
        }
        cleanup_empty_groups(&mut groups);
    }

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
}

async fn handle_group_reorder_wormhole(
    state: &Arc<AppState>,
    group_id: &str,
    new_index: usize,
    sink: &mut WormholeSink,
) {
    let mut groups = state.groups.lock().await;
    let Some(current_idx) = find_group_index(&groups, group_id) else {
        let _ = send_group_error_wormhole(sink, "group_not_found", "Group not found.").await;
        return;
    };

    let new_idx = new_index.min(groups.len().saturating_sub(1));
    if current_idx != new_idx {
        let group = groups.remove(current_idx);
        groups.insert(new_idx, group);
        let session_names = state.session_names.lock().await;
        save_groups(&state.data_dir, &groups, &session_names);
        broadcast_group_sync(state, &groups, &session_names);
    }
}

async fn handle_session_rename_wormhole(
    state: &Arc<AppState>,
    session_id: &str,
    name: &str,
    sink: &mut WormholeSink,
) {
    let groups = state.groups.lock().await;
    let session_exists = groups
        .iter()
        .any(|g| g.session_ids.contains(&session_id.to_string()));
    if !session_exists {
        let _ = send_group_error_wormhole(sink, "session_not_found", "Session not found.").await;
        return;
    }

    let mut session_names = state.session_names.lock().await;
    let trimmed = name.trim();
    let changed = if trimmed.is_empty() {
        session_names.remove(session_id).is_some()
    } else if session_names.get(session_id).map(|s| s.as_str()) != Some(trimmed) {
        session_names.insert(session_id.to_string(), trimmed.to_string());
        true
    } else {
        false
    };

    if changed {
        save_groups(&state.data_dir, &groups, &session_names);
        broadcast_group_sync(state, &groups, &session_names);
    }
}

async fn handle_get_cwd_wormhole(state: &Arc<AppState>, session_id: &str, sink: &mut WormholeSink) {
    let cwd = get_session_cwd(state, session_id).await;
    let _ = sink
        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
            json!({
                "type": "cwd",
                "sessionId": session_id,
                "cwd": cwd,
            }),
        )))
        .await;
}

async fn send_group_error_wormhole(
    sink: &mut WormholeSink,
    code: &str,
    message: &str,
) -> Result<(), ()> {
    sink.send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
        json!({
            "type": "group_error",
            "code": code,
            "message": message,
        }),
    )))
    .await
    .map_err(|_| ())
}

// ============ getCwd Implementation ============

async fn get_session_cwd(state: &Arc<AppState>, session_id: &str) -> Option<String> {
    let sessions = state.sessions.lock().await;
    let session = sessions.get(session_id)?;

    #[cfg(target_os = "macos")]
    {
        get_cwd_macos(session.child_pid)
    }

    #[cfg(target_os = "linux")]
    {
        get_cwd_linux(session.child_pid)
    }

    #[cfg(windows)]
    {
        None // Windows getCwd is complex, skip for now
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn get_cwd_macos(child_pid: i32) -> Option<String> {
    // Get foreground process group if possible
    // For simplicity, just use child_pid
    use std::ffi::CStr;
    use std::mem::MaybeUninit;

    const PROC_PIDVNODEPATHINFO: i32 = 9;

    #[repr(C)]
    struct VnodeInfoPath {
        _vip_vi: [u8; 152],
        vip_path: [i8; 1024],
    }

    #[repr(C)]
    struct ProcVnodePathInfo {
        pvi_cdir: VnodeInfoPath,
        _pvi_rdir: VnodeInfoPath,
    }

    extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut libc::c_void,
            buffersize: i32,
        ) -> i32;
    }

    let mut pathinfo = MaybeUninit::<ProcVnodePathInfo>::uninit();
    let size = std::mem::size_of::<ProcVnodePathInfo>() as i32;

    unsafe {
        let result = proc_pidinfo(
            child_pid,
            PROC_PIDVNODEPATHINFO,
            0,
            pathinfo.as_mut_ptr() as *mut libc::c_void,
            size,
        );
        if result == size {
            let pathinfo = pathinfo.assume_init();
            let cstr = CStr::from_ptr(pathinfo.pvi_cdir.vip_path.as_ptr());
            return cstr.to_str().ok().map(|s| s.to_string());
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn get_cwd_linux(child_pid: i32) -> Option<String> {
    let proc_path = format!("/proc/{}/cwd", child_pid);
    std::fs::read_link(&proc_path)
        .ok()
        .and_then(|p| p.to_str().map(String::from))
}

#[cfg(windows)]
mod winconpty {
    use std::ffi::c_void;
    use std::io;
    use std::mem::{size_of, zeroed};
    use std::ptr::{null, null_mut};

    type HANDLE = *mut c_void;
    type HPCON = HANDLE;
    type DWORD = u32;
    type BOOL = i32;
    type HRESULT = i32;
    type LPWSTR = *mut u16;
    type UINT = u32;

    const INVALID_HANDLE_VALUE: HANDLE = (-1isize) as HANDLE;
    const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;

    #[repr(C)]
    struct COORD {
        x: i16,
        y: i16,
    }

    #[repr(C)]
    struct SECURITY_ATTRIBUTES {
        n_length: DWORD,
        lp_security_descriptor: *mut c_void,
        b_inherit_handle: BOOL,
    }

    #[repr(C)]
    struct STARTUPINFOW {
        cb: DWORD,
        lp_reserved: *mut u16,
        lp_desktop: *mut u16,
        lp_title: *mut u16,
        dw_x: DWORD,
        dw_y: DWORD,
        dw_x_size: DWORD,
        dw_y_size: DWORD,
        dw_x_count_chars: DWORD,
        dw_y_count_chars: DWORD,
        dw_fill_attribute: DWORD,
        dw_flags: DWORD,
        w_show_window: u16,
        cb_reserved2: u16,
        lp_reserved2: *mut u8,
        h_std_input: HANDLE,
        h_std_output: HANDLE,
        h_std_error: HANDLE,
    }

    #[repr(C)]
    struct STARTUPINFOEXW {
        startup_info: STARTUPINFOW,
        lp_attribute_list: *mut c_void,
    }

    #[repr(C)]
    struct PROCESS_INFORMATION {
        h_process: HANDLE,
        h_thread: HANDLE,
        dw_process_id: DWORD,
        dw_thread_id: DWORD,
    }

    #[repr(C)]
    struct SYSTEMTIME {
        w_year: u16,
        w_month: u16,
        w_day_of_week: u16,
        w_day: u16,
        w_hour: u16,
        w_minute: u16,
        w_second: u16,
        w_milliseconds: u16,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(
            dw_desired_access: DWORD,
            b_inherit_handle: BOOL,
            dw_process_id: DWORD,
        ) -> HANDLE;
        fn CreatePipe(
            h_read_pipe: *mut HANDLE,
            h_write_pipe: *mut HANDLE,
            lp_pipe_attributes: *mut SECURITY_ATTRIBUTES,
            n_size: DWORD,
        ) -> BOOL;
        fn SetHandleInformation(h_object: HANDLE, dw_mask: DWORD, dw_flags: DWORD) -> BOOL;
        fn CloseHandle(h_object: HANDLE) -> BOOL;
        fn ReadFile(
            h_file: HANDLE,
            lp_buffer: *mut c_void,
            n_number_of_bytes_to_read: DWORD,
            lp_number_of_bytes_read: *mut DWORD,
            lp_overlapped: *mut c_void,
        ) -> BOOL;
        fn WriteFile(
            h_file: HANDLE,
            lp_buffer: *const c_void,
            n_number_of_bytes_to_write: DWORD,
            lp_number_of_bytes_written: *mut DWORD,
            lp_overlapped: *mut c_void,
        ) -> BOOL;
        fn TerminateProcess(h_process: HANDLE, u_exit_code: UINT) -> BOOL;
        fn GetLastError() -> DWORD;
        fn GetSystemTime(lp_system_time: *mut SYSTEMTIME);

        fn CreatePseudoConsole(
            size: COORD,
            h_input: HANDLE,
            h_output: HANDLE,
            dw_flags: DWORD,
            ph_pc: *mut HPCON,
        ) -> HRESULT;
        fn ResizePseudoConsole(h_pc: HPCON, size: COORD) -> HRESULT;
        fn ClosePseudoConsole(h_pc: HPCON);

        fn InitializeProcThreadAttributeList(
            lp_attribute_list: *mut c_void,
            dw_attribute_count: DWORD,
            dw_flags: DWORD,
            lp_size: *mut usize,
        ) -> BOOL;
        fn UpdateProcThreadAttribute(
            lp_attribute_list: *mut c_void,
            dw_flags: DWORD,
            attribute: usize,
            lp_value: *mut c_void,
            cb_size: usize,
            lp_previous_value: *mut c_void,
            lp_return_size: *mut usize,
        ) -> BOOL;
        fn DeleteProcThreadAttributeList(lp_attribute_list: *mut c_void);

        fn CreateProcessW(
            lp_application_name: *const u16,
            lp_command_line: LPWSTR,
            lp_process_attributes: *mut c_void,
            lp_thread_attributes: *mut c_void,
            b_inherit_handles: BOOL,
            dw_creation_flags: DWORD,
            lp_environment: *mut c_void,
            lp_current_directory: *const u16,
            lp_startup_info: *mut STARTUPINFOW,
            lp_process_information: *mut PROCESS_INFORMATION,
        ) -> BOOL;
    }

    fn handle_to_usize(h: HANDLE) -> usize {
        h as usize
    }
    fn usize_to_handle(h: usize) -> HANDLE {
        h as HANDLE
    }

    fn wide_null(s: &str) -> Vec<u16> {
        let mut v: Vec<u16> = s.encode_utf16().collect();
        v.push(0);
        v
    }

    fn io_error(msg: &str) -> io::Error {
        let code = unsafe { GetLastError() } as i32;
        io::Error::new(io::ErrorKind::Other, format!("{msg} (win32={code})"))
    }

    pub fn now_iso8601() -> String {
        unsafe {
            let mut st: SYSTEMTIME = zeroed();
            GetSystemTime(&mut st as *mut SYSTEMTIME);
            format!(
                "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
                st.w_year, st.w_month, st.w_day, st.w_hour, st.w_minute, st.w_second
            )
        }
    }

    pub fn pid_is_running(pid: u32) -> bool {
        const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
        let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as DWORD) };
        if h.is_null() {
            return false;
        }
        unsafe {
            CloseHandle(h);
        }
        true
    }

    pub struct ConPty {
        h_pc: usize,
        in_write: usize,
        out_read: usize,
        child_proc: usize,
        child_thread: usize,
    }

    unsafe impl Send for ConPty {}
    unsafe impl Sync for ConPty {}

    impl ConPty {
        pub fn spawn(shell: &str, rows: u16, cols: u16) -> io::Result<Self> {
            let mut in_read: HANDLE = null_mut();
            let mut in_write: HANDLE = null_mut();
            let mut out_read: HANDLE = null_mut();
            let mut out_write: HANDLE = null_mut();

            let mut sa = SECURITY_ATTRIBUTES {
                n_length: size_of::<SECURITY_ATTRIBUTES>() as DWORD,
                lp_security_descriptor: null_mut(),
                b_inherit_handle: 1,
            };

            unsafe {
                if CreatePipe(&mut in_read, &mut in_write, &mut sa, 0) == 0 {
                    return Err(io_error("CreatePipe stdin"));
                }
                if CreatePipe(&mut out_read, &mut out_write, &mut sa, 0) == 0 {
                    CloseHandle(in_read);
                    CloseHandle(in_write);
                    return Err(io_error("CreatePipe stdout"));
                }

                // Ensure the handles we keep are not inherited by the child.
                let _ = SetHandleInformation(in_write, 0x0000_0001, 0);
                let _ = SetHandleInformation(out_read, 0x0000_0001, 0);
            }

            let size = COORD {
                x: cols as i16,
                y: rows as i16,
            };
            let mut h_pc: HPCON = null_mut();
            let hr = unsafe { CreatePseudoConsole(size, in_read, out_write, 0, &mut h_pc) };
            if hr != 0 {
                unsafe {
                    CloseHandle(in_read);
                    CloseHandle(in_write);
                    CloseHandle(out_read);
                    CloseHandle(out_write);
                }
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!("CreatePseudoConsole failed (hr=0x{hr:08x})"),
                ));
            }

            // The pseudoconsole keeps its own references.
            unsafe {
                CloseHandle(in_read);
                CloseHandle(out_write);
            }

            let mut attr_size: usize = 0;
            unsafe {
                InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut attr_size);
            }
            if attr_size == 0 {
                unsafe {
                    ClosePseudoConsole(h_pc);
                    CloseHandle(in_write);
                    CloseHandle(out_read);
                }
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "InitializeProcThreadAttributeList size failed",
                ));
            }
            let mut attr_buf = vec![0u8; attr_size];
            let attr_list = attr_buf.as_mut_ptr() as *mut c_void;

            unsafe {
                if InitializeProcThreadAttributeList(attr_list, 1, 0, &mut attr_size) == 0 {
                    ClosePseudoConsole(h_pc);
                    CloseHandle(in_write);
                    CloseHandle(out_read);
                    return Err(io_error("InitializeProcThreadAttributeList"));
                }
                let mut h_pc_value: HANDLE = h_pc;
                if UpdateProcThreadAttribute(
                    attr_list,
                    0,
                    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    &mut h_pc_value as *mut HANDLE as *mut c_void,
                    size_of::<HANDLE>(),
                    null_mut(),
                    null_mut(),
                ) == 0
                {
                    DeleteProcThreadAttributeList(attr_list);
                    ClosePseudoConsole(h_pc);
                    CloseHandle(in_write);
                    CloseHandle(out_read);
                    return Err(io_error("UpdateProcThreadAttribute(PSEUDOCONSOLE)"));
                }
            }

            let mut si_ex: STARTUPINFOEXW = unsafe { zeroed() };
            si_ex.startup_info.cb = size_of::<STARTUPINFOEXW>() as DWORD;
            si_ex.lp_attribute_list = attr_list;

            let cmd = if shell.trim().is_empty() {
                "cmd.exe".to_string()
            } else {
                shell.to_string()
            };
            let mut cmd_w = wide_null(&cmd);

            let mut pi: PROCESS_INFORMATION = unsafe { zeroed() };
            let ok = unsafe {
                CreateProcessW(
                    null(),
                    cmd_w.as_mut_ptr() as LPWSTR,
                    null_mut(),
                    null_mut(),
                    0,
                    EXTENDED_STARTUPINFO_PRESENT,
                    null_mut(),
                    null(),
                    &mut si_ex.startup_info as *mut STARTUPINFOW,
                    &mut pi as *mut PROCESS_INFORMATION,
                )
            };

            unsafe {
                DeleteProcThreadAttributeList(attr_list);
            }
            drop(attr_buf);

            if ok == 0 {
                unsafe {
                    ClosePseudoConsole(h_pc);
                    CloseHandle(in_write);
                    CloseHandle(out_read);
                }
                return Err(io_error("CreateProcessW"));
            }

            Ok(ConPty {
                h_pc: handle_to_usize(h_pc),
                in_write: handle_to_usize(in_write),
                out_read: handle_to_usize(out_read),
                child_proc: handle_to_usize(pi.h_process),
                child_thread: handle_to_usize(pi.h_thread),
            })
        }

        pub fn write_stdin(&self, data: &[u8]) -> io::Result<()> {
            if data.is_empty() {
                return Ok(());
            }
            let mut written: DWORD = 0;
            let ok = unsafe {
                WriteFile(
                    usize_to_handle(self.in_write),
                    data.as_ptr() as *const c_void,
                    data.len() as DWORD,
                    &mut written as *mut DWORD,
                    null_mut(),
                )
            };
            if ok == 0 {
                return Err(io_error("WriteFile"));
            }
            Ok(())
        }

        pub fn read_stdout(&self, buf: &mut [u8]) -> io::Result<usize> {
            if buf.is_empty() {
                return Ok(0);
            }
            let mut read: DWORD = 0;
            let ok = unsafe {
                ReadFile(
                    usize_to_handle(self.out_read),
                    buf.as_mut_ptr() as *mut c_void,
                    buf.len() as DWORD,
                    &mut read as *mut DWORD,
                    null_mut(),
                )
            };
            if ok == 0 {
                return Err(io_error("ReadFile"));
            }
            Ok(read as usize)
        }

        pub fn resize(&self, rows: u16, cols: u16) -> io::Result<()> {
            let size = COORD {
                x: cols as i16,
                y: rows as i16,
            };
            let hr = unsafe { ResizePseudoConsole(usize_to_handle(self.h_pc), size) };
            if hr != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!("ResizePseudoConsole failed (hr=0x{hr:08x})"),
                ));
            }
            Ok(())
        }

        pub fn cleanup(&self) {
            unsafe {
                let _ = TerminateProcess(usize_to_handle(self.child_proc), 0);
                ClosePseudoConsole(usize_to_handle(self.h_pc));
                let _ = CloseHandle(usize_to_handle(self.in_write));
                let _ = CloseHandle(usize_to_handle(self.out_read));
                let _ = CloseHandle(usize_to_handle(self.child_thread));
                let _ = CloseHandle(usize_to_handle(self.child_proc));
            }
        }
    }
}

#[derive(Debug)]
struct Config {
    bind: IpAddr,
    port: u16,
    shell: String,
    host_name: String,
    dev_mode: bool,
    wormhole_url: Option<String>,
    wormhole_token: Option<String>,
    custom_session: Option<String>,
    config_id: Option<String>,
    no_initial_session: bool,
}

fn parse_args(args: Vec<String>) -> Result<Config, String> {
    let mut bind = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
    let mut port = 9527u16;
    #[cfg(not(windows))]
    let mut shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    #[cfg(windows)]
    let mut shell = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string());
    let mut host_name = hostname();
    let mut dev_mode = std::env::var("BLACKHOLE_DEV").ok().as_deref() == Some("1");
    let mut wormhole_url = std::env::var("WORMHOLE_URL")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let mut wormhole_token = std::env::var("WORMHOLE_TOKEN")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let mut custom_session = None::<String>;
    let mut config_id = None::<String>;
    let mut no_initial_session = false;

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--help" | "-h" => return Err(usage()),
            "--bind" => {
                let Some(v) = it.next() else {
                    return Err("--bind requires a value".to_string());
                };
                bind = v
                    .parse::<IpAddr>()
                    .map_err(|_| format!("invalid --bind: {v}"))?;
            }
            "--port" => {
                let Some(v) = it.next() else {
                    return Err("--port requires a value".to_string());
                };
                port = v
                    .parse::<u16>()
                    .map_err(|_| format!("invalid --port: {v}"))?;
            }
            "--shell" => {
                let Some(v) = it.next() else {
                    return Err("--shell requires a value".to_string());
                };
                shell = v;
            }
            "--host-name" => {
                let Some(v) = it.next() else {
                    return Err("--host-name requires a value".to_string());
                };
                host_name = v;
            }
            "--dev-mode" => dev_mode = true,
            "--wormhole-url" => {
                let Some(v) = it.next() else {
                    return Err("--wormhole-url requires a value".to_string());
                };
                wormhole_url = Some(v);
            }
            "--wormhole-token" => {
                let Some(v) = it.next() else {
                    return Err("--wormhole-token requires a value".to_string());
                };
                wormhole_token = Some(v);
            }
            "--wormhole-session" => {
                let Some(v) = it.next() else {
                    return Err("--wormhole-session requires a value".to_string());
                };
                custom_session = Some(v);
            }
            "--config-id" => {
                let Some(v) = it.next() else {
                    return Err("--config-id requires a value".to_string());
                };
                config_id = Some(v);
            }
            "--no-initial-session" => no_initial_session = true,
            _ if arg.starts_with("--bind=") => {
                let v = arg.trim_start_matches("--bind=");
                bind = v
                    .parse::<IpAddr>()
                    .map_err(|_| format!("invalid --bind: {v}"))?;
            }
            _ if arg.starts_with("--port=") => {
                let v = arg.trim_start_matches("--port=");
                port = v
                    .parse::<u16>()
                    .map_err(|_| format!("invalid --port: {v}"))?;
            }
            _ if arg.starts_with("--shell=") => {
                shell = arg.trim_start_matches("--shell=").to_string();
            }
            _ if arg.starts_with("--host-name=") => {
                host_name = arg.trim_start_matches("--host-name=").to_string();
            }
            _ if arg.starts_with("--wormhole-url=") => {
                wormhole_url = Some(arg.trim_start_matches("--wormhole-url=").to_string());
            }
            _ if arg.starts_with("--wormhole-token=") => {
                wormhole_token = Some(arg.trim_start_matches("--wormhole-token=").to_string());
            }
            _ if arg.starts_with("--wormhole-session=") => {
                custom_session = Some(arg.trim_start_matches("--wormhole-session=").to_string());
            }
            _ if arg.starts_with("--config-id=") => {
                config_id = Some(arg.trim_start_matches("--config-id=").to_string());
            }
            _ => return Err(format!("unknown arg: {arg}\n\n{}", usage())),
        }
    }

    Ok(Config {
        bind,
        port,
        shell,
        host_name,
        dev_mode,
        wormhole_url,
        wormhole_token,
        custom_session,
        config_id,
        no_initial_session,
    })
}

fn usage() -> String {
    [
        "Usage: horizon-daemon [--bind IP] [--port PORT] [--shell PATH] [--host-name NAME] [--dev-mode]",
        "                   [--wormhole-url WS_URL] [--wormhole-token TOKEN] [--wormhole-session SESSION] [--config-id ID]",
        "                   [--no-initial-session]",
        "",
        "Starts the Horizon host core as a separate process.",
        "",
        "LAN WebSocket endpoint:",
        "  ws://<bind>:<port>/ws",
        "",
        "Wormhole mode:",
        "  Set WORMHOLE_URL (and optional WORMHOLE_TOKEN), or pass --wormhole-url/--wormhole-token.",
        "",
    ]
    .join("\n")
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "Horizon".to_string())
}

async fn run_wormhole(
    state: Arc<AppState>,
    base_url: String,
    token: Option<String>,
    custom_session: Option<String>,
) {
    loop {
        match connect_wormhole(&state, &base_url, token.clone(), custom_session.clone()).await {
            Ok(()) => {
                warn!("wormhole connection ended, reconnecting");
            }
            Err(err) => {
                warn!("wormhole connect failed: {} ({})", err.kind, err.message);
                let mut wh = state.wormhole_state.lock().await;
                wh.last_error_kind = Some(err.kind.to_string());
                wh.last_error = Some(err.message);
                wh.last_error_at = Some(now_iso8601());
            }
        }
        {
            let mut wh = state.wormhole_state.lock().await;
            wh.connected = false;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

#[derive(Debug)]
struct WormholeConnectError {
    kind: &'static str,
    message: String,
}

async fn connect_wormhole(
    state: &Arc<AppState>,
    base_url: &str,
    token: Option<String>,
    custom_session: Option<String>,
) -> Result<(), WormholeConnectError> {
    let url =
        build_wormhole_url(base_url, token.as_deref(), custom_session.as_deref()).map_err(|e| {
            WormholeConnectError {
                kind: "invalid_url",
                message: e,
            }
        })?;
    info!("connecting wormhole: {url}");

    let connect = tokio_tungstenite::connect_async(url);
    let (ws, _) = match tokio::time::timeout(std::time::Duration::from_secs(5), connect).await {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return Err(classify_wormhole_ws_error(&e)),
        Err(_) => {
            return Err(WormholeConnectError {
                kind: "timeout",
                message: "Timed out connecting to relay.".to_string(),
            });
        }
    };

    {
        let mut wh = state.wormhole_state.lock().await;
        wh.connected = true;
        // Keep previous session_id until replaced by session_assigned.
        wh.last_error_kind = None;
        wh.last_error = None;
        wh.last_error_at = None;
    }

    let (mut write, mut read) = ws.split();
    let mut broadcast_rx = state.wormhole_broadcast.subscribe();
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<tokio_tungstenite::tungstenite::Message>();
    {
        let mut sender = state.wormhole_sender.lock().await;
        *sender = Some(cmd_tx);
    }

    struct SenderGuard {
        state: Arc<AppState>,
    }
    impl Drop for SenderGuard {
        fn drop(&mut self) {
            // Best-effort cleanup; don't block.
            if let Ok(mut sender) = self.state.wormhole_sender.try_lock() {
                *sender = None;
            }
        }
    }
    let _sender_guard = SenderGuard {
        state: state.clone(),
    };

    // Send host info immediately (best-effort).
    let _ = write
        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
            json!({"type":"host_info","hostName": state.host_name}),
        )))
        .await;

    loop {
        tokio::select! {
            msg = read.next() => {
                let Some(Ok(msg)) = msg else { return Ok(()) };
                if handle_wormhole_incoming(state, msg, &mut write).await.is_err() {
                    return Ok(());
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { return Ok(()) };
                if write.send(cmd).await.is_err() {
                    return Ok(());
                }
            }
            out = broadcast_rx.recv() => {
                let Ok(out) = out else { return Ok(()) };
                let msg = match out {
                    BroadcastMsg::Text(text) => tokio_tungstenite::tungstenite::Message::Text(text),
                    BroadcastMsg::Binary(bytes) => tokio_tungstenite::tungstenite::Message::Binary(bytes),
                };
                if write.send(msg).await.is_err() {
                    return Ok(());
                }
            }
        }
    }
}

async fn handle_wormhole_incoming(
    state: &Arc<AppState>,
    msg: tokio_tungstenite::tungstenite::Message,
    write: &mut futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        tokio_tungstenite::tungstenite::Message,
    >,
) -> Result<(), ()> {
    match msg {
        tokio_tungstenite::tungstenite::Message::Text(text) => {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                return Ok(());
            };
            let version = value.get("v").and_then(|v| v.as_i64()).unwrap_or(1);
            if version != 1 {
                return Ok(());
            }
            let Some(ty) = value.get("type").and_then(|t| t.as_str()) else {
                return Ok(());
            };

            match ty {
                "ping" => {
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Binary(
                            build_pong_message(),
                        ))
                        .await;
                }
                "session_assigned" => {
                    if let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) {
                        info!("wormhole session assigned: {session_id}");
                        let mut wh = state.wormhole_state.lock().await;
                        wh.session_id = Some(session_id.to_string());
                    }
                }
                "voyager_connect" => {
                    handle_voyager_connect_wormhole(state, &value, write).await;
                }
                "voyager_disconnect" => {}
                "list" => {
                    let ids = list_session_ids(state).await;
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
                            json!({"type":"session_list","sessions": ids}),
                        )))
                        .await;
                }
                "sync" => {
                    let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) else {
                        return Ok(());
                    };
                    let content = get_history(state, session_id).await.unwrap_or_default();
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Text(
                            encode_json(json!({"type":"session_sync","sessionId": session_id, "content": content})),
                        ))
                        .await;
                }
                "create" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let session_id = create_session_in_group(state, group_id)
                        .await
                        .map_err(|_| ())?;
                    // Notify LAN clients and Wormhole clients (via the same WS).
                    let msg =
                        encode_json(json!({"type":"session_created","sessionId": session_id}));
                    let _ = state.lan_broadcast.send(BroadcastMsg::Text(msg.clone()));
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Text(msg))
                        .await;
                }
                "close" => {
                    let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) else {
                        return Ok(());
                    };
                    close_session(state, session_id).await;
                }
                // Group management
                "group_list" => {
                    handle_group_list_wormhole(state, write).await;
                }
                "group_create" => {
                    let name = value.get("name").and_then(|v| v.as_str());
                    handle_group_create_wormhole(state, name, write).await;
                }
                "group_rename" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let name = value.get("name").and_then(|v| v.as_str());
                    if let (Some(gid), Some(n)) = (group_id, name) {
                        handle_group_rename_wormhole(state, gid, n, write).await;
                    }
                }
                "group_delete" => {
                    if let Some(group_id) = value.get("groupId").and_then(|v| v.as_str()) {
                        handle_group_delete_wormhole(state, group_id, false, write).await;
                    }
                }
                "group_delete_with_sessions" => {
                    if let Some(group_id) = value.get("groupId").and_then(|v| v.as_str()) {
                        handle_group_delete_wormhole(state, group_id, true, write).await;
                    }
                }
                "group_move_session" => {
                    let session_id = value.get("sessionId").and_then(|v| v.as_str());
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let old_index = value
                        .get("oldIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    let new_index = value
                        .get("newIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    if let (Some(sid), Some(gid)) = (session_id, group_id) {
                        handle_group_move_session_wormhole(
                            state, sid, gid, old_index, new_index, write,
                        )
                        .await;
                    }
                }
                "group_reorder" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let new_index = value
                        .get("newIndex")
                        .and_then(|v| v.as_i64())
                        .map(|v| v as usize);
                    if let (Some(gid), Some(idx)) = (group_id, new_index) {
                        handle_group_reorder_wormhole(state, gid, idx, write).await;
                    }
                }
                "session_rename" => {
                    let session_id = value.get("sessionId").and_then(|v| v.as_str());
                    let name = value.get("name").and_then(|v| v.as_str());
                    if let (Some(sid), Some(n)) = (session_id, name) {
                        handle_session_rename_wormhole(state, sid, n, write).await;
                    }
                }
                "getCwd" => {
                    if let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) {
                        handle_get_cwd_wormhole(state, session_id, write).await;
                    }
                }
                _ => {}
            }
        }
        tokio_tungstenite::tungstenite::Message::Binary(bytes) => {
            if let Some(decoded) = decode_binary(&bytes) {
                match decoded.ty {
                    BinaryType::Stdin => {
                        write_stdin(state, &decoded.session_id, &decoded.payload).await;
                    }
                    BinaryType::Resize => {
                        if decoded.payload.len() >= 4 {
                            let rows = u16::from_be_bytes([decoded.payload[0], decoded.payload[1]]);
                            let cols = u16::from_be_bytes([decoded.payload[2], decoded.payload[3]]);
                            resize_session(state, &decoded.session_id, rows, cols).await;
                        }
                    }
                    BinaryType::Ping => {
                        let _ = write
                            .send(tokio_tungstenite::tungstenite::Message::Binary(
                                build_pong_message(),
                            ))
                            .await;
                    }
                    BinaryType::Pong | BinaryType::Stdout => {}
                }
            }
        }
        tokio_tungstenite::tungstenite::Message::Close(_) => return Err(()),
        tokio_tungstenite::tungstenite::Message::Ping(_) => {}
        tokio_tungstenite::tungstenite::Message::Pong(_) => {}
        tokio_tungstenite::tungstenite::Message::Frame(_) => {}
    }
    Ok(())
}

fn classify_wormhole_ws_error(err: &tokio_tungstenite::tungstenite::Error) -> WormholeConnectError {
    use tokio_tungstenite::tungstenite::Error as WsError;

    match err {
        WsError::Http(resp) => {
            let status = resp.status();
            let (kind, message) = match status.as_u16() {
                401 | 403 => ("unauthorized", "Token is invalid.".to_string()),
                404 => (
                    "not_found",
                    "Relay endpoint not found (check URL).".to_string(),
                ),
                409 => ("session_exists", "Session ID already exists.".to_string()),
                429 => ("rate_limited", "Rate limited by relay.".to_string()),
                500..=599 => ("server_error", format!("Relay error ({status}).")),
                _ => ("http_error", format!("Relay returned {status}.")),
            };
            WormholeConnectError { kind, message }
        }
        WsError::Io(e) => WormholeConnectError {
            kind: "io",
            message: format!("Network error: {e}"),
        },
        WsError::Tls(e) => WormholeConnectError {
            kind: "tls",
            message: format!("TLS error: {e}"),
        },
        other => WormholeConnectError {
            kind: "handshake",
            message: other.to_string(),
        },
    }
}

async fn handle_voyager_connect_wormhole(
    state: &Arc<AppState>,
    value: &serde_json::Value,
    write: &mut futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        tokio_tungstenite::tungstenite::Message,
    >,
) {
    let device_key = value
        .get("deviceKey")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let device_name = value
        .get("deviceName")
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown Device")
        .to_string();
    let device_type = value
        .get("deviceType")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let public_key = value
        .get("publicKey")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // Only support a single pending request (matches the current Flutter UI flow).
    if state.pending_pairing.lock().await.is_some() {
        let response = encode_json(json!({
            "type": "pairing_response",
            "deviceKey": device_key,
            "approved": false,
        }));
        let _ = write
            .send(tokio_tungstenite::tungstenite::Message::Text(response))
            .await;
        return;
    }

    // Auto-approve already paired devices.
    if let Some(key) = device_key.as_deref() {
        let mut devices = state.paired_devices.lock().await;
        if let Some(dev) = devices.iter_mut().find(|d| d.device_key == key) {
            let now = now_iso8601();
            dev.device_name = device_name.clone();
            dev.last_seen_at = now;
            dev.device_type = device_type.clone();
            if public_key.is_some() {
                dev.public_key = public_key.clone();
            }
            let _ = save_paired_devices(&state.data_dir, &devices);

            let response = encode_json(json!({
                "type": "pairing_response",
                "deviceKey": device_key,
                "approved": true,
            }));
            let _ = write
                .send(tokio_tungstenite::tungstenite::Message::Text(response))
                .await;
            return;
        }
    }

    // Dev mode: auto-approve, but don't persist.
    if state.dev_mode {
        let assigned_key = device_key.clone().unwrap_or_else(generate_device_key);
        let response = encode_json(json!({
            "type": "pairing_response",
            "deviceKey": device_key,
            "approved": true,
            "assignedKey": assigned_key,
        }));
        let _ = write
            .send(tokio_tungstenite::tungstenite::Message::Text(response))
            .await;
        return;
    }

    // Otherwise: require UI approval via local control endpoints.
    let pending = PendingPairing {
        device_key,
        device_name,
        requested_at: now_iso8601(),
        device_type,
        public_key,
    };
    *state.pending_pairing.lock().await = Some(pending);
    info!("pairing pending (waiting for local approval)");
}

fn build_wormhole_url(
    base_url: &str,
    token: Option<&str>,
    session: Option<&str>,
) -> Result<String, String> {
    // base_url is typically like: ws://host:6666/ws
    // It may already have query parameters.
    let mut parts = base_url.splitn(2, '?');
    let base = parts.next().unwrap_or(base_url);
    let existing = parts.next();

    let mut query: Vec<(String, String)> = Vec::new();
    if let Some(existing) = existing {
        for pair in existing.split('&') {
            if pair.trim().is_empty() {
                continue;
            }
            let mut kv = pair.splitn(2, '=');
            let k = kv.next().unwrap_or("").to_string();
            let v = kv.next().unwrap_or("").to_string();
            if !k.is_empty() {
                query.push((k, v));
            }
        }
    }

    query.push(("role".to_string(), "horizon".to_string()));
    if let Some(session) = session {
        if !session.trim().is_empty() {
            query.push(("session".to_string(), session.to_string()));
        }
    }
    if let Some(token) = token {
        if !token.trim().is_empty() {
            query.push(("token".to_string(), token.to_string()));
        }
    }

    let q = query
        .into_iter()
        .map(|(k, v)| format!("{k}={}", url_escape(&v)))
        .collect::<Vec<_>>()
        .join("&");
    Ok(format!("{base}?{q}"))
}

fn url_escape(input: &str) -> String {
    // Minimal escape for query values; enough for tokens/ids.
    input
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{:02X}", b),
        })
        .collect()
}

fn generate_device_key() -> String {
    // Simple random key; Voyager will persist assignedKey.
    const CHARSET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    (0..32)
        .map(|_| {
            let idx = rng.gen_range(0..CHARSET.len());
            CHARSET[idx] as char
        })
        .collect()
}
