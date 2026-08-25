mod dns_forwarder;
mod nat;
mod session_persist;
mod tun_device;
mod upnp;
mod vpn_config;
mod vpn_helper_client;
mod vpn_helper_protocol;
mod vpn_signaling;
mod vpn_tcp_delivery;
mod wg_server;

use std::collections::HashMap;
use std::env;
#[cfg(unix)]
use std::ffi::CStr;
use std::fmt;
use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::connect_info::Connected;
use axum::extract::ws::{Message as AxumMessage, WebSocket, WebSocketUpgrade};
use axum::extract::ConnectInfo;
use axum::extract::{Path as AxumPath, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use axum::serve::IncomingStream;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::{broadcast, mpsc, oneshot, watch, Mutex};
use tracing::{debug, info, warn};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
const VPN_SERVER_IP_STR: &str = "10.13.37.1";
const RELAY_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
const DEFAULT_HEADLESS_BIND: &str = "0.0.0.0";
const DEFAULT_WORMHOLE_URL: &str = "wss://wormhole.blackhole-ai.com/ws";

#[derive(Clone)]
enum BroadcastMsg {
    Text(String),
    Binary(Vec<u8>),
}

struct AppState {
    sessions: Arc<Mutex<HashMap<String, Arc<PtySession>>>>,
    inject_tasks: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    lan_broadcast: broadcast::Sender<BroadcastMsg>,
    wormhole_broadcast: broadcast::Sender<BroadcastMsg>,
    config_id: Option<String>,
    host_name: String,
    shell: String,
    dev_mode: bool,
    bind: IpAddr,
    ws_bind_addrs: Vec<IpAddr>,
    port: u16,
    wormhole_url: Option<String>,
    wormhole_token: Option<String>,
    wormhole_requested_session: Option<String>,
    wormhole_has_token: bool,
    lan_client_count: AtomicUsize,
    /// Number of Voyagers currently subscribed via Wormhole. PTY output is
    /// only uploaded to the relay while this is > 0, so a Horizon that is
    /// merely connected to Wormhole (no viewers) does not stream in real time.
    wormhole_subscriber_count: AtomicUsize,
    wormhole_state: Mutex<WormholeState>,
    data_dir: PathBuf,
    paired_devices: Mutex<Vec<PairedDevice>>,
    pending_pairing: Mutex<Option<PendingPairing>>,
    wormhole_sender: Mutex<Option<mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>>>,
    groups: Mutex<Vec<TerminalGroup>>,
    session_names: Mutex<HashMap<String, String>>,
    /// WireGuard public key for VPN (base64-encoded).
    wg_public_key: Mutex<Option<String>>,
    /// WireGuard UDP listen port for VPN.
    wg_udp_port: Mutex<Option<u16>>,
    /// Our observed public address as reported by Wormhole.
    wg_observed_addr: Mutex<Option<String>>,
    /// Recently observed public endpoints as reported by Wormhole.
    wg_observed_endpoints: Mutex<Vec<DirectCandidate>>,
    /// Internal routes advertised to VPN clients.
    wg_internal_routes: Mutex<Vec<String>>,
    /// Channel to send peer add/remove commands to the WgServer event loop.
    wg_peer_tx: Mutex<Option<mpsc::UnboundedSender<WgPeerCommand>>>,
    /// Highest punchEpoch accepted from signaling candidate lists.
    last_punch_epoch: AtomicU64,
    /// Dedupes endpoint_register floods on the same candidate set.
    last_endpoint_register_sig: Mutex<Option<String>>,
    endpoint_register_retrying: AtomicBool,
    /// When true, bind 10.13.37.1:lanPort after pf rdr has been removed.
    vpn_explicit_ws: watch::Sender<bool>,
    vpn_tcp_probe: Mutex<Option<oneshot::Sender<(SocketAddr, SocketAddr)>>>,
}

#[derive(Clone, Copy, Debug)]
struct ClientConnectInfo {
    remote: SocketAddr,
    local: SocketAddr,
}

impl Deref for ClientConnectInfo {
    type Target = SocketAddr;

    fn deref(&self) -> &Self::Target {
        &self.remote
    }
}

impl fmt::Display for ClientConnectInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.remote.fmt(f)
    }
}

impl Connected<IncomingStream<'_>> for ClientConnectInfo {
    fn connect_info(target: IncomingStream<'_>) -> Self {
        Self {
            remote: target.remote_addr(),
            local: target
                .local_addr()
                .unwrap_or_else(|_| SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)),
        }
    }
}

/// Commands sent to the WgServer event loop for adding/removing peers.
enum WgPeerCommand {
    AddPeer {
        public_key: String,
        device_key: Option<String>,
        endpoint: Option<SocketAddr>,
        candidate_endpoints: Vec<SocketAddr>,
        reply_tx: tokio::sync::oneshot::Sender<Result<wg_server::VpnAssignment, String>>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DirectCandidate {
    addr: String,
    port: u16,
    scope: String,
    priority: i32,
    source: String,
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
    history_base_offset: std::sync::Mutex<usize>,
    history_dirty: AtomicBool,
    rows: AtomicU16,
    cols: AtomicU16,
    closed: AtomicBool,
}

#[cfg(windows)]
struct PtySession {
    session_id: String,
    conpty: winconpty::ConPty,
    history: std::sync::Mutex<Vec<u8>>,
    history_base_offset: std::sync::Mutex<usize>,
    history_dirty: AtomicBool,
    rows: AtomicU16,
    cols: AtomicU16,
    closed: AtomicBool,
}

#[cfg(not(any(unix, windows)))]
struct PtySession {
    session_id: String,
    history: std::sync::Mutex<Vec<u8>>,
    history_base_offset: std::sync::Mutex<usize>,
    history_dirty: AtomicBool,
    rows: AtomicU16,
    cols: AtomicU16,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    layout: Option<serde_json::Value>,
    #[serde(default)]
    layout_revision: u64,
}

impl TerminalGroup {
    fn new_default() -> Self {
        Self {
            id: DEFAULT_GROUP_ID.to_string(),
            name: DEFAULT_GROUP_NAME.to_string(),
            session_ids: Vec::new(),
            created_at: now_iso8601(),
            sort_order: 0,
            layout: None,
            layout_revision: 0,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HeadlessLaunchMode {
    Foreground,
    Background,
}

#[derive(Debug)]
struct HeadlessCliOptions {
    mode: HeadlessLaunchMode,
    configure: bool,
    server_args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeadlessCliConfig {
    version: u32,
    bind: String,
    port: u16,
    host_name: String,
    wormhole: Option<HeadlessWormholeConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeadlessWormholeConfig {
    url: String,
    token: Option<String>,
    code: Option<String>,
}

#[derive(Debug, Clone)]
struct RuntimeSummary {
    pid: u32,
    host_name: String,
    lan_ws: String,
    wormhole_url: Option<String>,
    wormhole_code: Option<String>,
    log_path: PathBuf,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{}", usage());
        return;
    }
    if is_headless_cli_invocation(&args) {
        if let Err(err) = run_headless_cli(args).await {
            eprintln!("{err}");
            std::process::exit(2);
        }
        return;
    }

    let config = match parse_args(args.clone()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    run_server(config, &args, None).await;
}

async fn run_server(
    mut config: Config,
    cli_args: &[String],
    ready_tx: Option<tokio::sync::oneshot::Sender<RuntimeSummary>>,
) {
    let (lan_tx, _) = broadcast::channel::<BroadcastMsg>(512);
    let (wormhole_tx, _) = broadcast::channel::<BroadcastMsg>(512);
    let data_dir = resolve_data_dir();

    // I-9: Apply VPN settings from settings.json (CLI args override)
    {
        let (file_vpn, file_subnet, file_port, file_routes) =
            load_vpn_settings_from_file(&data_dir);
        // Only apply file settings if the CLI did NOT explicitly set --vpn
        let has_cli_vpn = cli_args.iter().any(|a| a == "--vpn");
        if !has_cli_vpn {
            if let Some(true) = file_vpn {
                config.vpn = true;
            }
        }
        let has_cli_subnet = cli_args.iter().any(|a| a.starts_with("--vpn-subnet"));
        if !has_cli_subnet {
            if let Some(subnet) = file_subnet {
                config.vpn_subnet = subnet;
            }
        }
        let has_cli_port = cli_args.iter().any(|a| a.starts_with("--vpn-port"));
        if !has_cli_port {
            if let Some(port) = file_port {
                config.vpn_port = port;
            }
        }
        let has_cli_routes = cli_args.iter().any(|a| a.starts_with("--vpn-routes"));
        if !has_cli_routes {
            if let Some(routes) = file_routes {
                if !routes.is_empty() {
                    config.vpn_routes = routes;
                }
            }
        }
    }
    if config.vpn && config.vpn_ws_bind.is_none() {
        config.vpn_ws_bind = Some(default_vpn_ws_bind());
    }

    let paired_devices = load_paired_devices(&data_dir).unwrap_or_default();
    let (groups, session_names) = load_groups(&data_dir);
    let (vpn_explicit_ws, vpn_explicit_rx) = watch::channel(false);
    let state = Arc::new(AppState {
        sessions: Arc::new(Mutex::new(HashMap::new())),
        inject_tasks: Mutex::new(HashMap::new()),
        lan_broadcast: lan_tx,
        wormhole_broadcast: wormhole_tx,
        config_id: config.config_id.clone(),
        host_name: config.host_name.clone(),
        shell: config.shell.clone(),
        dev_mode: config.dev_mode,
        bind: config.bind,
        ws_bind_addrs: websocket_bind_ips(config.bind, config.vpn_ws_bind),
        port: config.port,
        wormhole_url: config.wormhole_url.clone(),
        wormhole_token: config.wormhole_token.clone(),
        wormhole_requested_session: config.custom_session.clone(),
        wormhole_has_token: config
            .wormhole_token
            .as_ref()
            .is_some_and(|v| !v.trim().is_empty()),
        lan_client_count: AtomicUsize::new(0),
        wormhole_subscriber_count: AtomicUsize::new(0),
        wormhole_state: Mutex::new(WormholeState::default()),
        data_dir,
        paired_devices: Mutex::new(paired_devices),
        pending_pairing: Mutex::new(None),
        wormhole_sender: Mutex::new(None),
        groups: Mutex::new(groups),
        session_names: Mutex::new(session_names),
        wg_public_key: Mutex::new(None),
        wg_udp_port: Mutex::new(None),
        wg_observed_addr: Mutex::new(None),
        wg_observed_endpoints: Mutex::new(Vec::new()),
        wg_internal_routes: Mutex::new(config.vpn_routes.clone()),
        wg_peer_tx: Mutex::new(None),
        last_punch_epoch: AtomicU64::new(0),
        last_endpoint_register_sig: Mutex::new(None),
        endpoint_register_retrying: AtomicBool::new(false),
        vpn_explicit_ws,
        vpn_tcp_probe: Mutex::new(None),
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
        let restored = restore_sessions_from_disk(&state).await;
        if restored == 0 {
            match create_session(&state).await {
                Ok(session_id) => info!("started initial session: {session_id}"),
                Err(err) => warn!("failed to start initial session: {err}"),
            }
        }
    }
    start_session_persist_task(state.clone());

    if let Some(wormhole_url) = config.wormhole_url.clone() {
        let state_for_wormhole = state.clone();
        let wormhole_token = config.wormhole_token.clone();
        let custom_session = config.custom_session.clone();
        tokio::spawn(async move {
            run_wormhole(
                state_for_wormhole,
                wormhole_url,
                wormhole_token,
                custom_session,
            )
            .await;
        });
    }

    // Start VPN server if enabled
    if config.vpn {
        let vpn_state = state.clone();
        let vpn_port = config.vpn_port;
        let vpn_subnet = config.vpn_subnet.clone();
        let vpn_routes = config.vpn_routes.clone();
        tokio::spawn(async move {
            if let Err(e) = start_vpn_server(vpn_state, vpn_port, &vpn_subnet, &vpn_routes).await {
                warn!("VPN server failed to start: {}", e);
            }
        });
    }

    // Start ufoo Terminal Host daemon management socket
    #[cfg(unix)]
    {
        let mgmt_state = state.clone();
        tokio::spawn(async move {
            start_daemon_mgmt_socket(mgmt_state).await;
        });
    }

    #[cfg(unix)]
    install_signal_handlers();

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/vpn-tcp-probe", get(vpn_tcp_probe_handler))
        .route("/status", get(status_handler))
        .route("/shutdown", post(shutdown_handler))
        .route("/pairing/pending", get(pairing_pending))
        .route("/pairing/approve", post(pairing_approve))
        .route("/pairing/reject", post(pairing_reject))
        .route("/paired-devices", get(paired_devices_list))
        .route("/paired-devices/:key", delete(paired_devices_delete))
        .route("/vpn/status", get(vpn_status_handler))
        .route("/ws", get(ws_handler))
        .with_state(state.clone());

    if config.vpn {
        spawn_explicit_vpn_ws_listener(
            app.clone(),
            config.bind,
            config.port,
            config.vpn_ws_bind,
            vpn_explicit_rx,
        );
    } else {
        drop(vpn_explicit_rx);
    }

    let addr = SocketAddr::new(config.bind, config.port);
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(err) => {
            warn!("failed to bind {addr}: {err}");
            let _ = fs::remove_file(&pid_path);
            std::process::exit(1);
        }
    };
    info!("horizon-daemon listening on {addr}");

    // UPnP: map WebSocket TCP port for external access
    let ws_port = config.port;
    tokio::spawn(async move {
        match upnp::add_tcp_port_mapping(ws_port).await {
            Ok(ip) => info!("UPnP: external TCP endpoint {ip}:{ws_port}"),
            Err(e) => warn!("UPnP TCP: {e}"),
        }
    });

    if let Some(tx) = ready_tx {
        let _ = tx.send(RuntimeSummary::from_config(&config, &state.data_dir));
    }
    let result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<ClientConnectInfo>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await;

    if let Err(err) = result {
        warn!("server ended with error: {err}");
    }

    persist_live_sessions(&state).await;
    let _ = fs::remove_file(&pid_path);
    let _ = fs::remove_file(state.data_dir.join("daemon.sock"));
}

impl Default for HeadlessCliConfig {
    fn default() -> Self {
        Self {
            version: 1,
            bind: DEFAULT_HEADLESS_BIND.to_string(),
            port: 9527,
            host_name: hostname(),
            wormhole: None,
        }
    }
}

impl RuntimeSummary {
    fn from_config(config: &Config, data_dir: &Path) -> Self {
        Self {
            pid: std::process::id(),
            host_name: config.host_name.clone(),
            lan_ws: format!("ws://{}:{}/ws", config.bind, config.port),
            wormhole_url: config.wormhole_url.clone(),
            wormhole_code: config.custom_session.clone(),
            log_path: daemon_log_path(data_dir),
        }
    }
}

fn is_headless_cli_invocation(args: &[String]) -> bool {
    matches!(
        args.first().map(String::as_str),
        Some("start" | "foreground" | "background")
    ) || args.iter().any(|arg| {
        matches!(
            arg.as_str(),
            "--foreground" | "--background" | "--configure"
        )
    })
}

async fn run_headless_cli(args: Vec<String>) -> Result<(), String> {
    let options = parse_headless_cli_options(&args)?;
    let data_dir = resolve_data_dir();
    let config_path = headless_config_path(&data_dir);
    let existing = load_headless_config(&config_path);
    let should_save_config = options.configure || existing.is_none();
    let headless_config = if should_save_config {
        prompt_headless_config(existing)?
    } else {
        existing.unwrap_or_default()
    };

    let mut server_args = headless_config_to_args(&headless_config);
    server_args.extend(options.server_args.clone());

    let mut config = parse_args(server_args.clone())?;
    if headless_config.wormhole.is_none() && !args_include_wormhole(&options.server_args) {
        config.wormhole_url = None;
        config.wormhole_token = None;
        config.custom_session = None;
    }
    if should_save_config {
        save_headless_config(&config_path, &headless_config)?;
    }

    match options.mode {
        HeadlessLaunchMode::Foreground => run_headless_foreground(config, server_args).await,
        HeadlessLaunchMode::Background => run_headless_background(&config, &server_args).await,
    }
}

fn parse_headless_cli_options(args: &[String]) -> Result<HeadlessCliOptions, String> {
    let mut mode = HeadlessLaunchMode::Foreground;
    let mut configure = false;
    let mut server_args = Vec::new();
    let mut start_index = 0;

    if let Some(command) = args.first().map(String::as_str) {
        match command {
            "start" => start_index = 1,
            "foreground" => {
                mode = HeadlessLaunchMode::Foreground;
                start_index = 1;
            }
            "background" => {
                mode = HeadlessLaunchMode::Background;
                start_index = 1;
            }
            _ => {}
        }
    }

    for arg in &args[start_index..] {
        match arg.as_str() {
            "--foreground" => mode = HeadlessLaunchMode::Foreground,
            "--background" => mode = HeadlessLaunchMode::Background,
            "--configure" => configure = true,
            _ => server_args.push(arg.clone()),
        }
    }

    Ok(HeadlessCliOptions {
        mode,
        configure,
        server_args,
    })
}

async fn run_headless_foreground(config: Config, server_args: Vec<String>) -> Result<(), String> {
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let server_args_for_task = server_args.clone();
    let server_task = tokio::spawn(async move {
        run_server(config, &server_args_for_task, Some(ready_tx)).await;
    });

    let summary = ready_rx
        .await
        .map_err(|_| "horizon-daemon exited before it became reachable".to_string())?;
    print_runtime_summary(&summary, HeadlessLaunchMode::Foreground);
    println!("Press Enter to enter logs. Press Ctrl-C to stop Horizon.");
    wait_for_enter().await?;
    println!("Logs are streaming. Press Ctrl-C to stop Horizon.");
    server_task
        .await
        .map_err(|e| format!("horizon-daemon task failed: {e}"))?;
    Ok(())
}

async fn run_headless_background(config: &Config, server_args: &[String]) -> Result<(), String> {
    let exe =
        env::current_exe().map_err(|e| format!("failed to resolve current executable: {e}"))?;
    let data_dir = resolve_data_dir();
    fs::create_dir_all(&data_dir).map_err(|e| format!("failed to create data directory: {e}"))?;
    let log_path = daemon_log_path(&data_dir);
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| format!("failed to open daemon log {}: {e}", log_path.display()))?;
    let log_err = log
        .try_clone()
        .map_err(|e| format!("failed to clone daemon log handle: {e}"))?;

    let mut command = Command::new(exe);
    command
        .args(server_args)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    if config.wormhole_url.is_none() {
        command.env_remove("WORMHOLE_URL");
        command.env_remove("WORMHOLE_TOKEN");
    }
    configure_background_process(&mut command);
    let mut child = command
        .spawn()
        .map_err(|e| format!("failed to start horizon-daemon in background: {e}"))?;

    let healthy =
        wait_for_health(config.bind, config.port, &mut child, Duration::from_secs(8)).await?;
    if !healthy {
        return Err(format!(
            "horizon-daemon did not become reachable; see {}",
            log_path.display()
        ));
    }

    let summary = RuntimeSummary {
        pid: child.id(),
        host_name: config.host_name.clone(),
        lan_ws: format!("ws://{}:{}/ws", config.bind, config.port),
        wormhole_url: config.wormhole_url.clone(),
        wormhole_code: config.custom_session.clone(),
        log_path,
    };
    print_runtime_summary(&summary, HeadlessLaunchMode::Background);
    println!("Startup guide complete. Horizon is running in the background.");
    Ok(())
}

fn configure_background_process(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x00000008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
}

async fn wait_for_enter() -> Result<(), String> {
    let _ = tokio::task::spawn_blocking(|| {
        let mut line = String::new();
        io::stdin()
            .read_line(&mut line)
            .map_err(|e| format!("failed to read Enter: {e}"))
    })
    .await
    .map_err(|e| format!("failed to wait for Enter: {e}"))??;
    Ok(())
}

async fn wait_for_health(
    bind: IpAddr,
    port: u16,
    child: &mut std::process::Child,
    timeout: Duration,
) -> Result<bool, String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(status) = child
            .try_wait()
            .map_err(|e| format!("failed to inspect background daemon: {e}"))?
        {
            return Err(format!("horizon-daemon exited early with status {status}"));
        }
        if probe_health(bind, port) {
            return Ok(true);
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Ok(false)
}

fn probe_health(bind: IpAddr, port: u16) -> bool {
    let host = health_probe_host(bind);
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(
        &SocketAddr::new(host, port),
        Duration::from_millis(300),
    ) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    let request = "GET /health HTTP/1.1\r\nHost: horizon-daemon\r\nConnection: close\r\n\r\n";
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut response = String::new();
    stream.read_to_string(&mut response).is_ok() && response.contains("200 OK")
}

fn health_probe_host(bind: IpAddr) -> IpAddr {
    match bind {
        IpAddr::V4(ip) if ip.is_unspecified() || ip.is_loopback() => {
            IpAddr::V4(Ipv4Addr::LOCALHOST)
        }
        IpAddr::V6(ip) if ip.is_unspecified() || ip.is_loopback() => {
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        }
        _ => bind,
    }
}

fn print_runtime_summary(summary: &RuntimeSummary, mode: HeadlessLaunchMode) {
    let mode_label = match mode {
        HeadlessLaunchMode::Foreground => "foreground",
        HeadlessLaunchMode::Background => "background",
    };
    println!();
    println!("Horizon headless started ({mode_label})");
    println!("PID: {}", summary.pid);
    println!("Host: {}", summary.host_name);
    println!("LAN: {}", summary.lan_ws);
    match (&summary.wormhole_url, &summary.wormhole_code) {
        (Some(url), Some(code)) => println!("Wormhole: {url} (code: {code})"),
        (Some(url), None) => println!("Wormhole: {url}"),
        (None, _) => println!("Wormhole: disabled"),
    }
    println!("Log: {}", summary.log_path.display());
    println!();
}

fn prompt_headless_config(
    existing: Option<HeadlessCliConfig>,
) -> Result<HeadlessCliConfig, String> {
    let mut config = existing.unwrap_or_default();
    if !io::stdin().is_terminal() {
        return Err(
            "headless setup requires an interactive terminal; run `horizon-daemon start --configure` in a terminal, or use `horizon-daemon [server options]` for non-interactive launch"
                .to_string(),
        );
    }

    println!("Horizon headless first-run setup");
    println!("Press Enter to accept defaults.");
    config.host_name = prompt_line("Host name", Some(&config.host_name))?;
    config.bind = prompt_line("Bind address", Some(&config.bind))?;
    config.port = prompt_port("Port", config.port)?;

    let existing_wormhole = config.wormhole.clone();
    let enable_wormhole = prompt_yes_no("Enable Wormhole relay?", existing_wormhole.is_some())?;
    config.wormhole = if enable_wormhole {
        let existing_url = existing_wormhole
            .as_ref()
            .map(|w| w.url.as_str())
            .unwrap_or(DEFAULT_WORMHOLE_URL);
        let url = prompt_line("Wormhole URL", Some(existing_url))?;
        let token = prompt_optional_value(
            "Wormhole token (optional)",
            existing_wormhole.as_ref().and_then(|w| w.token.as_deref()),
            false,
        )?;
        let code = prompt_optional_value(
            "Wormhole code/session (optional)",
            existing_wormhole.as_ref().and_then(|w| w.code.as_deref()),
            true,
        )?;
        Some(HeadlessWormholeConfig { url, token, code })
    } else {
        None
    };

    Ok(config)
}

fn prompt_line(label: &str, default: Option<&str>) -> Result<String, String> {
    match default {
        Some(default) if !default.is_empty() => print!("{label} [{default}]: "),
        _ => print!("{label}: "),
    }
    io::stdout()
        .flush()
        .map_err(|e| format!("failed to flush stdout: {e}"))?;
    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .map_err(|e| format!("failed to read input: {e}"))?;
    let value = line.trim();
    if value.is_empty() {
        Ok(default.unwrap_or("").to_string())
    } else {
        Ok(value.to_string())
    }
}

fn prompt_port(label: &str, default: u16) -> Result<u16, String> {
    loop {
        let value = prompt_line(label, Some(&default.to_string()))?;
        match value.parse::<u16>() {
            Ok(port) => return Ok(port),
            Err(_) => println!("Please enter a valid TCP port."),
        }
    }
}

fn prompt_yes_no(label: &str, default: bool) -> Result<bool, String> {
    let hint = if default { "Y/n" } else { "y/N" };
    loop {
        print!("{label} [{hint}]: ");
        io::stdout()
            .flush()
            .map_err(|e| format!("failed to flush stdout: {e}"))?;
        let mut line = String::new();
        io::stdin()
            .read_line(&mut line)
            .map_err(|e| format!("failed to read input: {e}"))?;
        match line.trim().to_ascii_lowercase().as_str() {
            "" => return Ok(default),
            "y" | "yes" => return Ok(true),
            "n" | "no" => return Ok(false),
            _ => println!("Please answer y or n."),
        }
    }
}

fn prompt_optional_value(
    label: &str,
    existing: Option<&str>,
    show_existing: bool,
) -> Result<Option<String>, String> {
    match existing {
        Some(value) if show_existing && !value.is_empty() => {
            print!("{label} [{value}; '-' clears]: ")
        }
        Some(_) => print!("{label} [configured; blank keeps, '-' clears]: "),
        None => print!("{label}: "),
    }
    io::stdout()
        .flush()
        .map_err(|e| format!("failed to flush stdout: {e}"))?;
    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .map_err(|e| format!("failed to read input: {e}"))?;
    let value = line.trim();
    if value.is_empty() {
        Ok(existing.map(ToString::to_string))
    } else if value == "-" {
        Ok(None)
    } else {
        Ok(Some(value.to_string()))
    }
}

fn headless_config_to_args(config: &HeadlessCliConfig) -> Vec<String> {
    let mut args = vec![
        "--bind".to_string(),
        config.bind.clone(),
        "--port".to_string(),
        config.port.to_string(),
        "--host-name".to_string(),
        config.host_name.clone(),
    ];
    if let Some(wormhole) = &config.wormhole {
        if !wormhole.url.trim().is_empty() {
            args.extend(["--wormhole-url".to_string(), wormhole.url.clone()]);
        }
        if let Some(token) = &wormhole.token {
            args.extend(["--wormhole-token".to_string(), token.clone()]);
        }
        if let Some(code) = &wormhole.code {
            args.extend(["--wormhole-session".to_string(), code.clone()]);
        }
    }
    args
}

fn args_include_wormhole(args: &[String]) -> bool {
    args.iter().any(|arg| {
        arg == "--wormhole-url"
            || arg.starts_with("--wormhole-url=")
            || arg == "--wormhole-token"
            || arg.starts_with("--wormhole-token=")
            || arg == "--wormhole-session"
            || arg.starts_with("--wormhole-session=")
    })
}

fn headless_config_path(dir: &Path) -> PathBuf {
    dir.join("headless.json")
}

fn daemon_log_path(dir: &Path) -> PathBuf {
    dir.join("daemon.log")
}

fn load_headless_config(path: &Path) -> Option<HeadlessCliConfig> {
    let content = fs::read_to_string(path).ok()?;
    serde_json::from_str::<HeadlessCliConfig>(&content).ok()
}

fn save_headless_config(path: &Path, config: &HeadlessCliConfig) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create config directory: {e}"))?;
    }
    let content = serde_json::to_string_pretty(config)
        .map_err(|e| format!("failed to serialize headless config: {e}"))?;
    fs::write(path, content).map_err(|e| format!("failed to write {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

async fn ws_handler(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let vpn_peer = vpn_tcp_delivery::classify_vpn_peer(addr.remote, addr.local);
    info!(
        remote_addr = %addr.remote,
        local_addr = %addr.local,
        vpn_peer = vpn_peer,
        "websocket upgrade requested"
    );
    ws.on_upgrade(move |socket| handle_lan_socket(state, socket, addr, vpn_peer))
}

async fn vpn_tcp_probe_handler(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
    State(state): State<Arc<AppState>>,
) -> &'static str {
    report_vpn_tcp_probe(&state, addr).await;
    "ok"
}

async fn report_vpn_tcp_probe(state: &AppState, addr: ClientConnectInfo) {
    if let Some(tx) = state.vpn_tcp_probe.lock().await.take() {
        let _ = tx.send((addr.remote, addr.local));
    }
}

async fn handle_lan_socket(
    state: Arc<AppState>,
    socket: WebSocket,
    remote: ClientConnectInfo,
    vpn_peer: bool,
) {
    state.lan_client_count.fetch_add(1, Ordering::SeqCst);
    let (mut sink, mut stream) = socket.split();
    let mut broadcast_rx = state.lan_broadcast.subscribe();
    let remote_addr = remote.remote;
    let mut first_vpn_stdout_logged = false;

    info!(
        remote_addr = %remote_addr,
        local_addr = %remote.local,
        vpn_peer = vpn_peer,
        "websocket accepted"
    );

    // Initial info.
    let host_info = encode_json(vpn_tcp_delivery::host_info_json(
        &state.host_name,
        vpn_peer,
        remote_addr,
    ));
    if sink.send(AxumMessage::Text(host_info)).await.is_err() {
        warn!(
            remote_addr = %remote_addr,
            vpn_peer = vpn_peer,
            "failed sending initial host_info on websocket"
        );
        return;
    }
    info!(
        remote_addr = %remote_addr,
        vpn_peer = vpn_peer,
        "initial host_info sent on websocket"
    );
    if send_session_list(&state, &mut sink, remote_addr, vpn_peer)
        .await
        .is_err()
    {
        warn!(
            remote_addr = %remote_addr,
            vpn_peer = vpn_peer,
            "failed sending initial session bootstrap on websocket"
        );
        return;
    }
    info!(
        remote_addr = %remote_addr,
        vpn_peer = vpn_peer,
        "initial session bootstrap sent on websocket"
    );

    loop {
        tokio::select! {
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { break };
                if handle_lan_incoming(&state, msg, &mut sink, remote_addr, vpn_peer)
                    .await
                    .is_err()
                {
                    break;
                }
            }
            out = broadcast_rx.recv() => {
                let Ok(out) = out else { break };
                if vpn_peer && !first_vpn_stdout_logged {
                    if let BroadcastMsg::Binary(bytes) = &out {
                        if let Some(decoded) = decode_binary(bytes) {
                            if decoded.ty == BinaryType::Stdout {
                                info!(
                                    remote_addr = %remote_addr,
                                    session_id = %decoded.session_id,
                                    payload_len = decoded.payload.len(),
                                    "sent terminal stdout over websocket"
                                );
                                first_vpn_stdout_logged = true;
                            }
                        }
                    }
                }
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
    info!(
        remote_addr = %remote_addr,
        vpn_peer = vpn_peer,
        "websocket closed"
    );
}

async fn status_handler(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
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

    let wg_pub = state.wg_public_key.lock().await.clone();
    let wg_port = state.wg_udp_port.lock().await.clone();
    let wg_addr = state.wg_observed_addr.lock().await.clone();
    let ws_binds: Vec<String> = state
        .ws_bind_addrs
        .iter()
        .map(ToString::to_string)
        .collect();

    axum::Json(json!({
        "configId": state.config_id,
        "hostName": state.host_name,
        "lan": {
            "bind": state.bind.to_string(),
            "binds": ws_binds,
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
        "vpn": {
            "running": state.wg_peer_tx.lock().await.is_some(),
            "wgPublicKey": wg_pub,
            "wgUdpPort": wg_port,
            "observedAddr": wg_addr,
        },
        "devMode": state.dev_mode,
        "sessions": session_count,
        "pairing": {
            "pending": pending.is_some(),
        }
    }))
    .into_response()
}

async fn shutdown_handler(ConnectInfo(addr): ConnectInfo<ClientConnectInfo>) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
    (StatusCode::ACCEPTED, "shutting down").into_response()
}

async fn pairing_pending(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
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
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
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
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
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
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let devices = state.paired_devices.lock().await.clone();
    axum::Json(json!({ "devices": devices })).into_response()
}

async fn paired_devices_delete(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
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

async fn append_remote_log(state: &AppState, line: &str) {
    use std::io::Write;
    let path = state.data_dir.join("voyager-remote.log");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let millis = now.subsec_millis();
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "[{secs}.{millis:03}] {line}");
    }
}

fn paired_devices_path(dir: &Path) -> PathBuf {
    dir.join("paired_devices.json")
}

fn settings_path(dir: &Path) -> PathBuf {
    dir.join("settings.json")
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

fn load_vpn_settings_from_path(
    path: &Path,
) -> (
    Option<bool>,
    Option<String>,
    Option<u16>,
    Option<Vec<String>>,
) {
    if !path.exists() {
        return (None, None, None, None);
    }
    let Ok(content) = fs::read_to_string(&path) else {
        return (None, None, None, None);
    };
    let Ok(parsed) = serde_json::from_str::<PairedDevicesFile>(&content) else {
        return (None, None, None, None);
    };
    let settings = &parsed.settings;
    let vpn_enabled = settings.get("vpnEnabled").and_then(|v| v.as_bool());
    let vpn_subnet = settings
        .get("vpnSubnet")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let vpn_port = settings
        .get("vpnPort")
        .and_then(|v| v.as_u64())
        .map(|v| v as u16);
    let vpn_routes = settings
        .get("vpnRoutes")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        });
    (vpn_enabled, vpn_subnet, vpn_port, vpn_routes)
}

/// Load VPN settings from settings.json, falling back to the legacy
/// paired_devices.json settings field when needed.
/// Returns (vpn_enabled, vpn_subnet, vpn_port, vpn_routes) or None values.
fn load_vpn_settings_from_file(
    dir: &Path,
) -> (
    Option<bool>,
    Option<String>,
    Option<u16>,
    Option<Vec<String>>,
) {
    let current = load_vpn_settings_from_path(&settings_path(dir));
    if current.0.is_some() || current.1.is_some() || current.2.is_some() || current.3.is_some() {
        return current;
    }
    load_vpn_settings_from_path(&paired_devices_path(dir))
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

fn session_ids_from_groups(groups: &[TerminalGroup]) -> Vec<String> {
    let mut ids = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for group in groups {
        for id in &group.session_ids {
            if seen.insert(id.clone()) {
                ids.push(id.clone());
            }
        }
    }
    ids
}

#[cfg(unix)]
fn session_child_pid(session: &PtySession) -> Option<i32> {
    Some(session.child_pid)
}

#[cfg(not(unix))]
fn session_child_pid(_session: &PtySession) -> Option<i32> {
    None
}

fn cwd_for_pid(pid: i32) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        get_cwd_macos(pid)
    }
    #[cfg(target_os = "linux")]
    {
        get_cwd_linux(pid)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = pid;
        None
    }
}

fn restore_banner(cwd: Option<&str>) -> Vec<u8> {
    match cwd {
        Some(path) if !path.is_empty() => {
            format!("\r\n\x1b[90m[horizon] session restored - new shell in {path}\x1b[0m\r\n")
                .into_bytes()
        }
        _ => b"\r\n\x1b[90m[horizon] session restored - new shell\x1b[0m\r\n".to_vec(),
    }
}

async fn persist_live_sessions(state: &AppState) {
    struct Snapshot {
        id: String,
        pid: Option<i32>,
        rows: u16,
        cols: u16,
        history: Vec<u8>,
        history_base_offset: usize,
        history_dirty: bool,
    }

    let snapshots = {
        let sessions = state.sessions.lock().await;
        let mut out = Vec::with_capacity(sessions.len());
        for (id, session) in sessions.iter() {
            let dirty = session.history_dirty.swap(false, Ordering::SeqCst);
            let history = session
                .history
                .lock()
                .ok()
                .map(|buf| buf.clone())
                .unwrap_or_default();
            let history_base_offset = session
                .history_base_offset
                .lock()
                .ok()
                .map(|offset| *offset)
                .unwrap_or(0);
            out.push(Snapshot {
                id: id.clone(),
                pid: session_child_pid(session),
                rows: session.rows.load(Ordering::Relaxed),
                cols: session.cols.load(Ordering::Relaxed),
                history,
                history_base_offset,
                history_dirty: dirty,
            });
        }
        out
    };

    let mut persisted = Vec::with_capacity(snapshots.len());
    for snap in snapshots {
        if snap.history_dirty {
            if let Err(err) =
                session_persist::write_history(&state.data_dir, &snap.id, &snap.history)
            {
                warn!(session_id = %snap.id, error = %err, "failed to persist session history");
                if let Some(session) = state.sessions.lock().await.get(&snap.id) {
                    session.history_dirty.store(true, Ordering::SeqCst);
                }
            }
        }
        persisted.push(session_persist::PersistedSession {
            id: snap.id,
            cwd: snap.pid.and_then(cwd_for_pid),
            rows: snap.rows,
            cols: snap.cols,
            history_base_offset: snap.history_base_offset,
        });
    }

    let catalog = session_persist::SessionCatalog {
        version: session_persist::CATALOG_VERSION,
        sessions: persisted,
    };
    if let Err(err) = session_persist::save_catalog(&state.data_dir, &catalog) {
        warn!(error = %err, "failed to persist session catalog");
    }
}

fn start_session_persist_task(state: Arc<AppState>) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            persist_live_sessions(&state).await;
            if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
                persist_live_sessions(&state).await;
                break;
            }
        }
    });
}

async fn restore_sessions_from_disk(state: &Arc<AppState>) -> usize {
    let mut records = session_persist::load_catalog(&state.data_dir).sessions;
    if records.is_empty() {
        let groups = state.groups.lock().await;
        records = session_ids_from_groups(&groups)
            .into_iter()
            .map(session_persist::PersistedSession::from_id)
            .collect();
    }
    if records.is_empty() {
        return 0;
    }

    let mut restored = 0usize;
    for record in records {
        match restore_one_session(state, record).await {
            Ok(()) => restored += 1,
            Err(err) => warn!(error = %err, "failed to restore persisted session"),
        }
    }
    if restored > 0 {
        persist_live_sessions(state).await;
        info!(count = restored, "restored sessions from disk");
    }
    restored
}

async fn restore_one_session(
    state: &Arc<AppState>,
    record: session_persist::PersistedSession,
) -> std::io::Result<()> {
    {
        let sessions = state.sessions.lock().await;
        if sessions.contains_key(&record.id) {
            return Ok(());
        }
    }

    let rows = if record.rows == 0 {
        session_persist::DEFAULT_ROWS
    } else {
        record.rows
    };
    let cols = if record.cols == 0 {
        session_persist::DEFAULT_COLS
    } else {
        record.cols
    };
    let cwd = record
        .cwd
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let session = spawn_pty_session(&record.id, &state.shell, None, None, cwd)?;
    session.rows.store(rows, Ordering::Relaxed);
    session.cols.store(cols, Ordering::Relaxed);

    if let Some(bytes) = session_persist::read_history(&state.data_dir, &record.id) {
        if let Ok(mut history) = session.history.lock() {
            *history = bytes;
        }
        if let Ok(mut base) = session.history_base_offset.lock() {
            *base = record.history_base_offset;
        }
    }

    let banner = restore_banner(cwd);
    append_history(
        &session.history,
        &session.history_base_offset,
        &session.history_dirty,
        &banner,
    );

    let arc = Arc::new(session);
    start_output_thread(state.clone(), arc.clone());
    start_inject_socket(state, &record.id, arc.clone());
    {
        let mut sessions = state.sessions.lock().await;
        sessions.insert(record.id.clone(), arc);
    }
    resize_session(state, &record.id, rows, cols).await;
    Ok(())
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

async fn resolve_group_id_for_source_session(
    state: &Arc<AppState>,
    session_id: &str,
) -> Result<String, (String, String)> {
    {
        let sessions = state.sessions.lock().await;
        if !sessions.contains_key(session_id) {
            return Err(host_err(
                "not_found",
                &format!("session not found: {session_id}"),
            ));
        }
    }

    let groups = state.groups.lock().await;
    if let Some(group) = groups
        .iter()
        .find(|g| g.session_ids.iter().any(|id| id == session_id))
    {
        return Ok(group.id.clone());
    }

    Ok(DEFAULT_GROUP_ID.to_string())
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
    let mut group_layouts = serde_json::Map::new();
    for group in groups {
        if let Some(layout) = &group.layout {
            group_layouts.insert(
                group.id.clone(),
                json!({
                    "layout": layout,
                    "revision": group.layout_revision,
                }),
            );
        }
    }
    json!({
        "type": "group_sync",
        "version": 1,
        "groups": groups,
        "sessionNames": session_names,
        "groupLayouts": group_layouts,
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
    remote_addr: SocketAddr,
    vpn_peer: bool,
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
                "remote_log" => {
                    if let Some(line) = value.get("line").and_then(|v| v.as_str()) {
                        append_remote_log(state, line).await;
                    }
                }
                "ping" => {
                    let _ = sink.send(AxumMessage::Binary(build_pong_message())).await;
                }
                "list" => {
                    let _ = send_session_list(state, sink, remote_addr, vpn_peer).await;
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
                    let requested_offset = value
                        .get("offset")
                        .and_then(|v| v.as_u64())
                        .and_then(|v| usize::try_from(v).ok());
                    let delta = get_history_delta(state, session_id, requested_offset)
                        .await
                        .unwrap_or(HistoryDelta {
                            offset: 0,
                            next_offset: 0,
                            reset: true,
                            content: String::new(),
                        });
                    let _ = sink
                        .send(AxumMessage::Text(encode_json(json!({
                            "type": "session_sync",
                            "sessionId": session_id,
                            "offset": delta.offset,
                            "nextOffset": delta.next_offset,
                            "reset": delta.reset,
                            "content": delta.content,
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
                "group_layout_update" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let layout = value.get("layout").cloned();
                    let base_revision = value.get("baseRevision").and_then(|v| v.as_u64());
                    if let (Some(gid), Some(layout)) = (group_id, layout) {
                        handle_group_layout_update(state, gid, layout, base_revision, sink).await;
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
                ty if vpn_signaling::is_vpn_control_type(ty) => {
                    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel();
                    vpn_signaling::handle_vpn_control(state, &value, reply_tx).await;
                    while let Some(reply) = reply_rx.recv().await {
                        let _ = sink.send(AxumMessage::Text(encode_json(reply))).await;
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
                    if vpn_peer && !decoded.payload.is_empty() {
                        info!(
                            remote_addr = %remote_addr,
                            session_id = %decoded.session_id,
                            payload_len = decoded.payload.len(),
                            "received terminal stdin over websocket"
                        );
                    }
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
    remote_addr: SocketAddr,
    vpn_peer: bool,
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
        .send(AxumMessage::Text(encode_json(
            vpn_tcp_delivery::host_info_json(&state.host_name, vpn_peer, remote_addr),
        )))
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

    info!(
        remote_addr = %remote_addr,
        session_count = active_sessions.len(),
        group_count = groups.len(),
        "sent websocket bootstrap payloads"
    );

    Ok(())
}

async fn list_session_ids(state: &Arc<AppState>) -> Vec<String> {
    let sessions = state.sessions.lock().await;
    sessions.keys().cloned().collect()
}

async fn create_session(state: &Arc<AppState>) -> std::io::Result<String> {
    create_session_with_command(state, None, None, None, None).await
}

async fn create_session_in_group(
    state: &Arc<AppState>,
    group_id: Option<&str>,
) -> std::io::Result<String> {
    // Inherit cwd from the first existing session in the same group so that
    // a cd inside any pane carries to a newly-created sibling pane.
    let mut seed_cwd: Option<String> = None;
    if let Some(gid) = group_id {
        let groups = state.groups.lock().await;
        let seed_session = groups
            .iter()
            .find(|g| g.id == gid)
            .and_then(|g| g.session_ids.first().cloned());
        drop(groups);
        if let Some(seed) = seed_session {
            seed_cwd = get_session_cwd(state, &seed).await;
        }
    }
    create_session_with_command(state, group_id, None, None, seed_cwd.as_deref()).await
}

async fn create_session_with_command(
    state: &Arc<AppState>,
    group_id: Option<&str>,
    startup_command: Option<&str>,
    env_vars: Option<&serde_json::Map<String, serde_json::Value>>,
    cwd: Option<&str>,
) -> std::io::Result<String> {
    let session_id = generate_session_id();
    let arc = Arc::new(spawn_pty_session(
        &session_id,
        &state.shell,
        startup_command,
        env_vars,
        cwd,
    )?);
    start_output_thread(state.clone(), arc.clone());
    start_inject_socket(state, &session_id, arc.clone());

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
    drop(groups);
    drop(session_names);
    persist_live_sessions(state).await;

    Ok(session_id)
}

fn inject_sock_path(data_dir: &Path, session_id: &str) -> PathBuf {
    data_dir
        .join("sessions")
        .join(session_id)
        .join("inject.sock")
}

#[cfg(unix)]
fn start_inject_socket(state: &Arc<AppState>, session_id: &str, session: Arc<PtySession>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let sock_path = inject_sock_path(&state.data_dir, session_id);
    if let Some(parent) = sock_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    // Remove stale socket
    let _ = fs::remove_file(&sock_path);

    let listener = match std::os::unix::net::UnixListener::bind(&sock_path) {
        Ok(l) => {
            l.set_nonblocking(true).ok();
            // Restrict to owner only
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&sock_path, fs::Permissions::from_mode(0o600));
            l
        }
        Err(e) => {
            warn!("failed to bind inject socket {sock_path:?}: {e}");
            return;
        }
    };
    let listener = match tokio::net::UnixListener::from_std(listener) {
        Ok(l) => l,
        Err(e) => {
            warn!("failed to convert inject socket to tokio: {e}");
            return;
        }
    };

    let state_for_listener = state.clone();
    let session_id = session_id.to_string();
    let listener_session_id = session_id.clone();
    let handle = tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(conn) => conn,
                Err(_) => break,
            };
            let session = session.clone();
            let state = state_for_listener.clone();
            let inject_session_id = listener_session_id.clone();
            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line.trim().is_empty() {
                        continue;
                    }
                    let (req_id, resp, should_close_session) = match serde_json::from_str::<
                        serde_json::Value,
                    >(&line)
                    {
                        Ok(req) => {
                            let rid = req
                                .get("request_id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            match handle_inject_request(&state, &inject_session_id, &session, &req)
                                .await
                            {
                                Ok((result, should_close_session)) => {
                                    (rid, Ok(result), should_close_session)
                                }
                                Err(err) => (rid, Err(err), false),
                            }
                        }
                        Err(e) => (
                            "".to_string(),
                            Err(("invalid_request".to_string(), format!("{e}"))),
                            false,
                        ),
                    };
                    let envelope = match resp {
                        Ok(result) => {
                            serde_json::json!({"v": 1, "request_id": req_id, "ok": true, "result": result})
                        }
                        Err((code, msg)) => {
                            serde_json::json!({"v": 1, "request_id": req_id, "ok": false, "error_code": code, "error": msg})
                        }
                    };
                    let mut out = envelope.to_string();
                    out.push('\n');
                    if writer.write_all(out.as_bytes()).await.is_err() {
                        break;
                    }
                    if should_close_session {
                        let state = state.clone();
                        let session_id = inject_session_id.clone();
                        tokio::spawn(async move {
                            close_session(&state, &session_id).await;
                        });
                        break;
                    }
                }
            });
        }
    });

    // Store task handle for cleanup — spawn a blocking lock to avoid
    // holding the future across an await in the synchronous caller.
    let state2 = state.clone();
    let sid = session_id;
    tokio::spawn(async move {
        state2.inject_tasks.lock().await.insert(sid, handle);
    });
}

fn host_err(code: &str, msg: &str) -> (String, String) {
    (code.to_string(), msg.to_string())
}

#[cfg(unix)]
fn session_capability_commands() -> Vec<&'static str> {
    let mut commands = vec![
        "inject",
        "raw",
        "resize",
        "ping",
        "capabilities",
        "snapshot",
        "close_session",
    ];
    #[cfg(target_os = "macos")]
    {
        commands.push("activate");
        commands.push("notify");
    }
    commands
}

#[cfg(unix)]
fn current_terminal_size(master_fd: std::os::fd::RawFd) -> (usize, usize) {
    let mut winsz: libc::winsize = unsafe { std::mem::zeroed() };
    let ioctl_rc = unsafe { libc::ioctl(master_fd, libc::TIOCGWINSZ as libc::c_ulong, &mut winsz) };
    if ioctl_rc < 0 || winsz.ws_col == 0 || winsz.ws_row == 0 {
        return (80, 24);
    }
    (winsz.ws_col as usize, winsz.ws_row as usize)
}

#[cfg(target_os = "macos")]
fn escape_applescript_string(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

#[cfg(target_os = "macos")]
fn activate_host_window() -> Result<(), (String, String)> {
    let status = std::process::Command::new("osascript")
        .arg("-e")
        .arg(r#"tell application "Horizon" to activate"#)
        .status()
        .map_err(|e| host_err("internal_error", &format!("activate failed: {e}")))?;
    if !status.success() {
        return Err(host_err("internal_error", "activate failed"));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn activate_host_window() -> Result<(), (String, String)> {
    Err(host_err(
        "unsupported",
        "activate is not supported on this platform",
    ))
}

#[cfg(target_os = "macos")]
fn deliver_host_notification(title: &str, message: &str) -> Result<(), (String, String)> {
    let script = format!(
        "display notification \"{}\" with title \"{}\"",
        escape_applescript_string(message),
        escape_applescript_string(title)
    );
    let status = std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .status()
        .map_err(|e| host_err("internal_error", &format!("notify failed: {e}")))?;
    if !status.success() {
        return Err(host_err("internal_error", "notify failed"));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn deliver_host_notification(_title: &str, _message: &str) -> Result<(), (String, String)> {
    Err(host_err(
        "unsupported",
        "notify is not supported on this platform",
    ))
}

#[cfg(unix)]
async fn handle_inject_request(
    state: &Arc<AppState>,
    session_id: &str,
    session: &PtySession,
    req: &serde_json::Value,
) -> Result<(serde_json::Value, bool), (String, String)> {
    let req_type = req.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match req_type {
        "inject" => {
            let command = req
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or_else(|| host_err("invalid_request", "missing field: command"))?;
            let data = encode_injected_command_text(command);
            if !data.is_empty() {
                write_all_pty(session.master_fd, &data)
                    .map_err(|_| host_err("internal_error", "write to pty failed"))?;
                let submit_delay_ms = compute_injected_submit_delay_ms(command);
                tokio::time::sleep(std::time::Duration::from_millis(submit_delay_ms)).await;
            }
            if write_all_pty(session.master_fd, injected_submit_bytes()).is_err() {
                Err(host_err("internal_error", "write to pty failed"))
            } else {
                Ok((serde_json::json!({}), false))
            }
        }
        "raw" => {
            let data = req
                .get("data")
                .and_then(|v| v.as_str())
                .ok_or_else(|| host_err("invalid_request", "missing field: data"))?;
            if write_all_pty(session.master_fd, data.as_bytes()).is_err() {
                Err(host_err("internal_error", "write to pty failed"))
            } else {
                Ok((serde_json::json!({}), false))
            }
        }
        "resize" => {
            let rows = req.get("rows").and_then(|v| v.as_u64()).unwrap_or(0) as u16;
            let cols = req.get("cols").and_then(|v| v.as_u64()).unwrap_or(0) as u16;
            if rows == 0 || cols == 0 {
                return Err(host_err("invalid_request", "rows and cols must be > 0"));
            }
            let winsz = libc::winsize {
                ws_row: rows,
                ws_col: cols,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            unsafe {
                libc::ioctl(session.master_fd, libc::TIOCSWINSZ as libc::c_ulong, &winsz);
            }
            Ok((serde_json::json!({}), false))
        }
        "snapshot" => {
            let (cols, rows) = current_terminal_size(session.master_fd);
            let cap = (cols * rows * 4).min(65536).max(4096);
            let raw = {
                let history = session
                    .history
                    .lock()
                    .map_err(|_| host_err("internal_error", "history lock poisoned"))?;
                let start = history.len().saturating_sub(cap);
                history[start..].to_vec()
            };
            let text = String::from_utf8_lossy(&raw);
            let lines: Vec<&str> = text.lines().collect();
            let visible_start = lines.len().saturating_sub(rows);
            let visible: Vec<&str> = lines[visible_start..].to_vec();
            Ok((
                serde_json::json!({
                    "lines": visible,
                    "cols": cols,
                    "rows": rows,
                }),
                false,
            ))
        }
        "activate" => {
            activate_host_window()?;
            Ok((
                serde_json::json!({
                    "session_id": session.session_id,
                }),
                false,
            ))
        }
        "notify" => {
            let message = req
                .get("message")
                .and_then(|v| v.as_str())
                .ok_or_else(|| host_err("invalid_request", "missing field: message"))?;
            let title = req.get("title").and_then(|v| v.as_str()).unwrap_or("ufoo");
            deliver_host_notification(title, message)?;
            Ok((
                serde_json::json!({
                    "delivered": true,
                    "title": title,
                    "message": message,
                }),
                false,
            ))
        }
        "close_session" => {
            let sessions = state.sessions.lock().await;
            if !sessions.contains_key(session_id) {
                return Err(host_err(
                    "not_found",
                    &format!("session not found: {session_id}"),
                ));
            }
            drop(sessions);
            Ok((serde_json::json!({}), true))
        }
        "ping" => Ok((serde_json::json!({"pong": true}), false)),
        "capabilities" => Ok((
            serde_json::json!({
                "host": "horizon",
                "protocol_version": 1,
                "commands": session_capability_commands()
            }),
            false,
        )),
        _ => Err(host_err(
            "unsupported",
            &format!("unknown command: {req_type}"),
        )),
    }
}

#[cfg(not(unix))]
fn start_inject_socket(_state: &Arc<AppState>, _session_id: &str, _session: Arc<PtySession>) {}

/// Daemon management socket — ufoo Terminal Host Protocol (per-host).
/// Listens at `~/.blackhole/horizon/daemon.sock`.
/// Commands: create_session, list_sessions, close_session, capabilities, ping.
#[cfg(unix)]
async fn start_daemon_mgmt_socket(state: Arc<AppState>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let sock_path = state.data_dir.join("daemon.sock");
    let _ = fs::remove_file(&sock_path);

    let listener = match std::os::unix::net::UnixListener::bind(&sock_path) {
        Ok(l) => {
            l.set_nonblocking(true).ok();
            // Restrict to owner only
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&sock_path, fs::Permissions::from_mode(0o600));
            l
        }
        Err(e) => {
            warn!("failed to bind daemon mgmt socket {sock_path:?}: {e}");
            return;
        }
    };
    let listener = match tokio::net::UnixListener::from_std(listener) {
        Ok(l) => l,
        Err(e) => {
            warn!("failed to convert daemon mgmt socket to tokio: {e}");
            return;
        }
    };

    info!("daemon mgmt socket listening on {sock_path:?}");

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(conn) => conn,
            Err(_) => break,
        };
        let state = state.clone();
        tokio::spawn(async move {
            let (reader, mut writer) = stream.into_split();
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if line.trim().is_empty() {
                    continue;
                }
                let (req_id, resp) = match serde_json::from_str::<serde_json::Value>(&line) {
                    Ok(req) => {
                        let rid = req
                            .get("request_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        (rid, handle_daemon_request(&state, &req).await)
                    }
                    Err(e) => (
                        "".to_string(),
                        Err(("invalid_request".to_string(), format!("{e}"))),
                    ),
                };
                let envelope = match resp {
                    Ok(result) => {
                        serde_json::json!({"v": 1, "request_id": req_id, "ok": true, "result": result})
                    }
                    Err((code, msg)) => {
                        serde_json::json!({"v": 1, "request_id": req_id, "ok": false, "error_code": code, "error": msg})
                    }
                };
                let mut out = envelope.to_string();
                out.push('\n');
                if writer.write_all(out.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
    }
}

#[cfg(unix)]
async fn handle_daemon_request(
    state: &Arc<AppState>,
    req: &serde_json::Value,
) -> Result<serde_json::Value, (String, String)> {
    let req_type = req.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match req_type {
        "create_session" => {
            let explicit_group_id = req.get("group_id").and_then(|v| v.as_str());
            let source_session_id = req.get("source_session_id").and_then(|v| v.as_str());
            let startup_command = req
                .get("command")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|v| !v.is_empty());
            // Parse env vars from request (e.g., UFOO_SUBSCRIBER_ID, UFOO_LAUNCH_MODE)
            let env_vars = req.get("env").and_then(|v| v.as_object());
            let resolved_group_id = if let Some(group_id) = explicit_group_id {
                Some(group_id.to_string())
            } else if let Some(session_id) = source_session_id {
                Some(resolve_group_id_for_source_session(state, session_id).await?)
            } else {
                None
            };
            let session_id = create_session_with_command(
                state,
                resolved_group_id.as_deref(),
                startup_command,
                env_vars,
                None,
            )
            .await
            .map_err(|e| host_err("internal_error", &format!("spawn failed: {e}")))?;
            // Notify LAN + Wormhole clients so UI updates
            let msg = encode_json(json!({
                "type": "session_created",
                "sessionId": session_id,
            }));
            let _ = state.lan_broadcast.send(BroadcastMsg::Text(msg.clone()));
            let _ = state.wormhole_broadcast.send(BroadcastMsg::Text(msg));
            let inject_sock = inject_sock_path(&state.data_dir, &session_id);
            Ok(serde_json::json!({
                "session_id": session_id,
                "inject_sock": inject_sock.to_string_lossy(),
            }))
        }
        "list_sessions" => {
            let sessions = state.sessions.lock().await;
            let list: Vec<serde_json::Value> = sessions
                .keys()
                .map(|id| {
                    let sock = inject_sock_path(&state.data_dir, id);
                    serde_json::json!({
                        "session_id": id,
                        "inject_sock": sock.to_string_lossy(),
                    })
                })
                .collect();
            Ok(serde_json::json!({"sessions": list}))
        }
        "close_session" => {
            let session_id = req
                .get("session_id")
                .and_then(|v| v.as_str())
                .ok_or_else(|| host_err("invalid_request", "missing field: session_id"))?;
            // Check session exists
            {
                let sessions = state.sessions.lock().await;
                if !sessions.contains_key(session_id) {
                    return Err(host_err(
                        "not_found",
                        &format!("session not found: {session_id}"),
                    ));
                }
            }
            close_session(state, session_id).await;
            Ok(serde_json::json!({}))
        }
        "ping" => Ok(serde_json::json!({"pong": true})),
        "capabilities" => Ok(serde_json::json!({
            "host": "horizon",
            "protocol_version": 1,
            "commands": [
                "create_session",
                "list_sessions",
                "close_session",
                "ping",
                "capabilities"
            ],
            "session_commands": session_capability_commands()
        })),
        _ => Err(host_err(
            "unsupported",
            &format!("unknown command: {req_type}"),
        )),
    }
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

    // Abort inject socket task and remove socket file
    {
        let mut tasks = state.inject_tasks.lock().await;
        if let Some(handle) = tasks.remove(session_id) {
            handle.abort();
        }
    }
    let sock_path = inject_sock_path(&state.data_dir, session_id);
    let _ = fs::remove_file(&sock_path);
    // Remove session directory if empty
    if let Some(parent) = sock_path.parent() {
        let _ = fs::remove_dir(parent);
    }

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
    session_persist::remove_session_files(&state.data_dir, session_id);
    persist_live_sessions(state).await;

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
    session.rows.store(rows, Ordering::Relaxed);
    session.cols.store(cols, Ordering::Relaxed);
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
    session.rows.store(rows, Ordering::Relaxed);
    session.cols.store(cols, Ordering::Relaxed);
    let _ = session.conpty.resize(rows, cols);
}

#[cfg(not(any(unix, windows)))]
async fn resize_session(_state: &Arc<AppState>, _session_id: &str, _rows: u16, _cols: u16) {}

#[derive(Debug)]
struct HistoryDelta {
    offset: usize,
    next_offset: usize,
    reset: bool,
    content: String,
}

async fn get_history_delta(
    state: &Arc<AppState>,
    session_id: &str,
    requested_offset: Option<usize>,
) -> Option<HistoryDelta> {
    let sessions = state.sessions.lock().await;
    let session = sessions.get(session_id)?.clone();
    drop(sessions);

    let bytes = session.history.lock().ok()?.clone();
    let base_offset = *session.history_base_offset.lock().ok()?;
    let next_offset = base_offset.saturating_add(bytes.len());
    let mut reset = false;
    let mut offset = requested_offset.unwrap_or(base_offset);
    if offset < base_offset || offset > next_offset {
        reset = true;
        offset = base_offset;
    }
    let relative_start = offset.saturating_sub(base_offset).min(bytes.len());
    Some(HistoryDelta {
        offset,
        next_offset,
        reset,
        content: String::from_utf8_lossy(&bytes[relative_start..]).to_string(),
    })
}

fn encode_json(value: serde_json::Value) -> String {
    let mut obj = value;
    if let serde_json::Value::Object(ref mut map) = obj {
        map.entry("v".to_string()).or_insert_with(|| json!(1));
    }
    obj.to_string()
}

fn parse_direct_candidates(value: &serde_json::Value, key: &str) -> Vec<DirectCandidate> {
    value
        .get(key)
        .and_then(|raw| raw.as_array())
        .into_iter()
        .flatten()
        .filter_map(|candidate| {
            let addr = candidate.get("addr")?.as_str()?.trim();
            let port = candidate.get("port")?.as_u64()? as u16;
            if addr.is_empty() || port == 0 {
                return None;
            }
            Some(DirectCandidate {
                addr: addr.to_string(),
                port,
                scope: candidate
                    .get("scope")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string(),
                priority: candidate
                    .get("priority")
                    .and_then(|v| v.as_i64())
                    .unwrap_or_default() as i32,
                source: candidate
                    .get("source")
                    .and_then(|v| v.as_str())
                    .unwrap_or("peer")
                    .to_string(),
            })
        })
        .collect()
}

fn merge_direct_candidates(
    base: Vec<DirectCandidate>,
    extra: impl IntoIterator<Item = DirectCandidate>,
) -> Vec<DirectCandidate> {
    let mut merged = base;
    for candidate in extra {
        let duplicate = merged.iter().any(|existing| {
            existing.addr == candidate.addr
                && existing.port == candidate.port
                && existing.scope == candidate.scope
        });
        if !duplicate {
            merged.push(candidate);
        }
    }
    merged.sort_by(|a, b| b.priority.cmp(&a.priority));
    merged
}

fn is_shared_private_ipv4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    matches!(
        (a, b),
        (10, _) | (172, 16..=31) | (192, 168) | (100, 64..=127)
    )
}

fn is_usable_lan_direct_ipv4(ip: Ipv4Addr) -> bool {
    if ip.is_unspecified() || ip.is_loopback() || ip.is_link_local() || ip.is_multicast() {
        return false;
    }
    if ip.octets()[0..3] == [10, 13, 37] {
        return false;
    }
    is_shared_private_ipv4(ip)
}

fn parse_candidate_ip(addr: &str) -> Option<IpAddr> {
    addr.trim().parse::<IpAddr>().ok()
}

fn has_scope(candidates: &[DirectCandidate], scope: &str) -> bool {
    candidates.iter().any(|candidate| candidate.scope == scope)
}

fn classify_nat_mapping_behavior(observed_endpoints: &[DirectCandidate]) -> &'static str {
    if observed_endpoints.is_empty() {
        return "unknown";
    }
    let mut unique = observed_endpoints
        .iter()
        .map(|candidate| (candidate.addr.clone(), candidate.port))
        .collect::<Vec<_>>();
    unique.sort();
    unique.dedup();
    if unique.len() <= 1 {
        return "stable";
    }
    let first_addr = unique.first().map(|entry| entry.0.clone());
    if unique
        .iter()
        .all(|(addr, _)| Some(addr.clone()) == first_addr)
    {
        "port_variant"
    } else {
        "endpoint_variant"
    }
}

fn compute_direct_reachability_score(
    horizon_candidates: &[DirectCandidate],
    voyager_candidates: &[DirectCandidate],
    nat_mapping_behavior: &str,
    hairpin_likely: bool,
) -> i32 {
    if horizon_candidates.is_empty() {
        return 0;
    }
    let mut score = 35;
    if has_scope(horizon_candidates, "lan") {
        score += 20;
    }
    if has_scope(voyager_candidates, "lan") {
        score += 15;
    }
    if has_scope(horizon_candidates, "public_observed") {
        score += 10;
    }
    if has_scope(horizon_candidates, "last_known") {
        score += 5;
    }
    if hairpin_likely {
        score += 10;
    }
    score += match nat_mapping_behavior {
        "stable" => 15,
        "port_variant" => 8,
        "endpoint_variant" => 0,
        _ => 4,
    };
    score.clamp(0, 100)
}

fn hairpin_likely(observed_addr: Option<&str>, voyager_candidates: &[DirectCandidate]) -> bool {
    let Some(observed_ip) = observed_addr.and_then(parse_candidate_ip) else {
        return false;
    };
    voyager_candidates.iter().any(|candidate| {
        matches!(candidate.scope.as_str(), "public_observed" | "last_known")
            && parse_candidate_ip(&candidate.addr) == Some(observed_ip)
    })
}

fn record_upnp_udp_candidate(store: &mut Vec<DirectCandidate>, addr: &str, port: u16) {
    let has_netcheck_public = store.iter().any(|candidate| {
        candidate.scope == "public_observed" && candidate.source == "wormhole_netcheck"
    });
    if has_netcheck_public {
        if store
            .iter()
            .any(|candidate| candidate.addr == addr && candidate.port == port)
        {
            return;
        }
        store.push(DirectCandidate {
            addr: addr.to_string(),
            port,
            scope: "last_known".to_string(),
            priority: 120,
            source: "upnp".to_string(),
        });
        store.sort_by(|a, b| b.priority.cmp(&a.priority));
        if store.len() > 8 {
            store.truncate(8);
        }
        return;
    }
    record_observed_direct_candidate(store, Some(addr), Some(port), "upnp");
}

fn record_observed_direct_candidate(
    store: &mut Vec<DirectCandidate>,
    addr: Option<&str>,
    port: Option<u16>,
    source: &str,
) {
    let Some(addr) = addr.map(str::trim) else {
        return;
    };
    let Some(port) = port else {
        return;
    };
    if addr.is_empty() || port == 0 {
        return;
    }

    for candidate in store.iter_mut() {
        if candidate.scope == "public_observed" {
            candidate.scope = "last_known".to_string();
            candidate.priority = 120;
        }
    }

    if let Some(candidate) = store
        .iter_mut()
        .find(|candidate| candidate.addr == addr && candidate.port == port)
    {
        candidate.scope = "public_observed".to_string();
        candidate.priority = 180;
        candidate.source = source.to_string();
    } else {
        store.push(DirectCandidate {
            addr: addr.to_string(),
            port,
            scope: "public_observed".to_string(),
            priority: 180,
            source: source.to_string(),
        });
    }
    store.sort_by(|a, b| b.priority.cmp(&a.priority));
    if store.len() > 8 {
        store.truncate(8);
    }
}

fn observed_direct_candidate(addr: Option<&str>, port: Option<u16>) -> Option<DirectCandidate> {
    let addr = addr?.trim();
    let port = port?;
    if addr.is_empty() || port == 0 {
        return None;
    }
    Some(DirectCandidate {
        addr: addr.to_string(),
        port,
        scope: "public_observed".to_string(),
        priority: 180,
        source: "wormhole_observed".to_string(),
    })
}

#[cfg(unix)]
fn local_lan_direct_candidates(port: u16) -> Vec<DirectCandidate> {
    let mut result = Vec::new();
    let mut addrs: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut addrs) } != 0 || addrs.is_null() {
        return result;
    }

    unsafe {
        let mut cursor = addrs;
        while !cursor.is_null() {
            let ifa = &*cursor;
            let flags = ifa.ifa_flags as i32;
            if !ifa.ifa_addr.is_null()
                && (flags & libc::IFF_UP) != 0
                && (flags & libc::IFF_LOOPBACK) == 0
                && (*ifa.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let sockaddr = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                let ip = Ipv4Addr::from(u32::from_be(sockaddr.sin_addr.s_addr));
                if is_usable_lan_direct_ipv4(ip) {
                    let name = CStr::from_ptr(ifa.ifa_name).to_string_lossy();
                    result.push(DirectCandidate {
                        addr: ip.to_string(),
                        port,
                        scope: "lan".to_string(),
                        priority: 250,
                        source: format!("local_interface:{name}"),
                    });
                }
            }
            cursor = (*cursor).ifa_next;
        }
        libc::freeifaddrs(addrs);
    }

    merge_direct_candidates(Vec::new(), result)
}

#[cfg(not(unix))]
fn local_lan_direct_candidates(_port: u16) -> Vec<DirectCandidate> {
    Vec::new()
}

fn best_direct_endpoint(
    candidates: &[DirectCandidate],
    fallback: Option<SocketAddr>,
) -> Option<SocketAddr> {
    candidates
        .iter()
        .filter_map(|candidate| {
            if candidate.port == 0 || candidate.addr.is_empty() {
                return None;
            }
            format!("{}:{}", candidate.addr, candidate.port)
                .parse::<SocketAddr>()
                .ok()
        })
        .next()
        .or(fallback)
}

async fn current_horizon_direct_candidates(state: &Arc<AppState>) -> Vec<DirectCandidate> {
    let observed_endpoints = state.wg_observed_endpoints.lock().await.clone();
    let wg_port = state.wg_udp_port.lock().await.clone();
    let local_candidates = wg_port.map(local_lan_direct_candidates).unwrap_or_default();
    merge_direct_candidates(local_candidates, observed_endpoints)
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

fn append_history(
    history: &std::sync::Mutex<Vec<u8>>,
    history_base_offset: &std::sync::Mutex<usize>,
    history_dirty: &AtomicBool,
    data: &[u8],
) {
    let Ok(mut buf) = history.lock() else {
        return;
    };
    buf.extend_from_slice(data);
    if buf.len() <= MAX_HISTORY_BYTES {
        history_dirty.store(true, Ordering::SeqCst);
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
    if let Ok(mut base_offset) = history_base_offset.lock() {
        *base_offset = base_offset.saturating_add(cut);
    }
    history_dirty.store(true, Ordering::SeqCst);
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
            append_history(
                &session.history,
                &session.history_base_offset,
                &session.history_dirty,
                chunk,
            );
            let msg = BroadcastMsg::Binary(build_stdout_message(&session.session_id, chunk));
            let _ = state.lan_broadcast.send(msg.clone());
            // Skip the relay upload when no Voyager is subscribed through
            // Wormhole. History is still appended above, so a later subscriber
            // gets the full backlog via "sync"/"session_sync".
            if state.wormhole_subscriber_count.load(Ordering::SeqCst) > 0 {
                let _ = state.wormhole_broadcast.send(msg);
            }
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
            append_history(
                &session.history,
                &session.history_base_offset,
                &session.history_dirty,
                chunk,
            );
            let msg = BroadcastMsg::Binary(build_stdout_message(&session.session_id, chunk));
            let _ = state.lan_broadcast.send(msg.clone());
            // Skip the relay upload when no Voyager is subscribed (see unix path).
            if state.wormhole_subscriber_count.load(Ordering::SeqCst) > 0 {
                let _ = state.wormhole_broadcast.send(msg);
            }
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
fn resolve_unix_home_dir() -> Option<PathBuf> {
    if let Some(home) = std::env::var("HOME")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        return Some(PathBuf::from(home));
    }

    unsafe {
        let pw = libc::getpwuid(libc::geteuid());
        if pw.is_null() {
            return None;
        }
        let dir_ptr = (*pw).pw_dir;
        if dir_ptr.is_null() {
            return None;
        }
        let home = std::ffi::CStr::from_ptr(dir_ptr)
            .to_string_lossy()
            .trim()
            .to_string();
        if home.is_empty() {
            None
        } else {
            Some(PathBuf::from(home))
        }
    }
}

#[cfg(unix)]
fn should_use_login_interactive_shell(shell_path: &str) -> bool {
    let shell_name = Path::new(shell_path)
        .file_name()
        .and_then(|v| v.to_str())
        .map(|v| v.to_ascii_lowercase())
        .unwrap_or_default();
    matches!(
        shell_name.as_str(),
        "zsh" | "bash" | "sh" | "dash" | "ksh" | "mksh" | "ash" | "fish"
    )
}

#[cfg(target_os = "macos")]
fn build_macos_bootstrap_path() -> String {
    let current = std::env::var("PATH")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "/usr/bin:/bin:/usr/sbin:/sbin".to_string());

    let mut merged = Vec::<String>::new();
    for path in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] {
        if !current.split(':').any(|p| p == path) {
            merged.push(path.to_string());
        }
    }
    merged.push(current);
    merged.join(":")
}

#[cfg(unix)]
fn maybe_inject_codex_startup_overrides(command: &str) -> String {
    let trimmed = command.trim_end();
    if trimmed.is_empty() || trimmed.contains("disable_paste_burst") {
        return trimmed.to_string();
    }

    for launcher in ["ucodex", "codex"] {
        if trimmed == launcher || trimmed.ends_with(&format!(" {launcher}")) {
            return format!("{trimmed} -c disable_paste_burst=true");
        }
    }

    trimmed.to_string()
}

#[cfg(unix)]
const HOST_INJECT_SUBMIT_DELAY_MS: u64 = 180;

#[cfg(unix)]
fn compute_injected_submit_delay_ms(command: &str) -> u64 {
    let text = command.trim_end_matches(['\r', '\n']);
    if text.is_empty() {
        return HOST_INJECT_SUBMIT_DELAY_MS;
    }

    let mut delay_ms = HOST_INJECT_SUBMIT_DELAY_MS;
    if text.contains('\n') {
        delay_ms += 250;
    }
    let len = text.len() as u64;
    if len > 512 {
        let extra_chunks = (len - 512).div_ceil(512);
        delay_ms += (extra_chunks * 90).min(1200);
    }
    delay_ms.min(1800)
}

#[cfg(unix)]
fn encode_injected_command_text(command: &str) -> Vec<u8> {
    command.as_bytes().to_vec()
}

#[cfg(unix)]
fn injected_submit_bytes() -> &'static [u8] {
    b"\r"
}

#[cfg(unix)]
fn write_all_pty(master_fd: std::os::fd::RawFd, data: &[u8]) -> std::io::Result<()> {
    let mut total_written = 0;
    while total_written < data.len() {
        let written = unsafe {
            libc::write(
                master_fd,
                data[total_written..].as_ptr() as *const _,
                data.len() - total_written,
            )
        };
        if written < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        if written == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "write to pty returned 0",
            ));
        }
        total_written += written as usize;
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod startup_command_tests {
    use super::maybe_inject_codex_startup_overrides;

    #[test]
    fn appends_disable_paste_burst_for_ucodex_launches() {
        let input = "cd '/tmp' && UFOO_LAUNCH_MODE=host ucodex";
        let output = maybe_inject_codex_startup_overrides(input);
        assert_eq!(
            output,
            "cd '/tmp' && UFOO_LAUNCH_MODE=host ucodex -c disable_paste_burst=true"
        );
    }

    #[test]
    fn leaves_other_startup_commands_unchanged() {
        let input = "cd '/tmp' && echo hi";
        let output = maybe_inject_codex_startup_overrides(input);
        assert_eq!(output, input);
    }
}

#[cfg(all(test, unix))]
mod inject_command_tests {
    use super::compute_injected_submit_delay_ms;
    use super::encode_injected_command_text;
    use super::injected_submit_bytes;
    use super::HOST_INJECT_SUBMIT_DELAY_MS;

    #[test]
    fn host_inject_text_excludes_submit_terminator() {
        let encoded = encode_injected_command_text("$ufoo codex-8");
        assert_eq!(encoded, b"$ufoo codex-8");
    }

    #[test]
    fn host_inject_submit_uses_carriage_return() {
        assert_eq!(injected_submit_bytes(), b"\r");
    }

    #[test]
    fn host_inject_submit_delay_scales_for_multiline_payloads() {
        let short = compute_injected_submit_delay_ms("/ubus");
        let multiline = compute_injected_submit_delay_ms("line1\nline2");
        assert_eq!(short, HOST_INJECT_SUBMIT_DELAY_MS);
        assert!(multiline > short);
    }

    #[test]
    fn host_inject_submit_delay_scales_for_large_payloads() {
        let small = compute_injected_submit_delay_ms(&"a".repeat(128));
        let large = compute_injected_submit_delay_ms(&"a".repeat(2200));
        assert_eq!(small, HOST_INJECT_SUBMIT_DELAY_MS);
        assert!(large > small);
        assert!(large <= 1800);
    }
}

#[cfg(test)]
mod websocket_bind_tests {
    use super::{default_vpn_ws_bind, secondary_vpn_ws_addr, websocket_bind_ips};
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    #[test]
    fn adds_vpn_bind_when_primary_is_loopback() {
        let primary = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let vpn = default_vpn_ws_bind();

        assert_eq!(websocket_bind_ips(primary, Some(vpn)), vec![primary, vpn]);
        assert_eq!(
            secondary_vpn_ws_addr(primary, 9527, Some(vpn)),
            Some(SocketAddr::new(vpn, 9527))
        );
    }

    #[test]
    fn skips_secondary_bind_when_primary_already_covers_all_interfaces() {
        let primary = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
        let vpn = default_vpn_ws_bind();

        assert_eq!(websocket_bind_ips(primary, Some(vpn)), vec![primary]);
        assert_eq!(secondary_vpn_ws_addr(primary, 9527, Some(vpn)), None);
    }

    #[test]
    fn fallback_bind_uses_vpn_ip_when_primary_is_unspecified() {
        let primary = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
        let vpn = default_vpn_ws_bind();
        assert_eq!(
            crate::vpn_tcp_delivery::vpn_ws_fallback_addr(
                primary,
                9527,
                Some(vpn),
                secondary_vpn_ws_addr(primary, 9527, Some(vpn)),
            ),
            Some(SocketAddr::new(vpn, 9527))
        );
    }
}

#[cfg(unix)]
fn spawn_pty_session(
    session_id: &str,
    shell: &str,
    startup_command: Option<&str>,
    env_vars: Option<&serde_json::Map<String, serde_json::Value>>,
    cwd: Option<&str>,
) -> std::io::Result<PtySession> {
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
    let home_dir = resolve_unix_home_dir();

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

    let mut cmd = Command::new(&shell_path);
    let startup_command = startup_command.map(str::trim).filter(|v| !v.is_empty());
    if let Some(command) = startup_command {
        let command = maybe_inject_codex_startup_overrides(command);
        if should_use_login_interactive_shell(&shell_path) {
            cmd.arg("-ilc");
        } else {
            cmd.arg("-c");
        }
        cmd.arg(command);
    } else if should_use_login_interactive_shell(&shell_path) {
        // Keep daemon PTY shell init behavior aligned with in-process PTY paths.
        cmd.arg("-il");
    }
    cmd.env("TERM", term);
    cmd.env("COLORTERM", "truecolor");
    cmd.env(
        "LANG",
        std::env::var("LANG")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| "en_US.UTF-8".to_string()),
    );
    #[cfg(target_os = "macos")]
    {
        cmd.env("PATH", build_macos_bootstrap_path());
    }
    if let Some(home) = home_dir.as_ref() {
        cmd.env("HOME", home);
    }
    // Prefer caller-provided cwd (carries cd state from a sibling pane in
    // the same group). Fall back to HOME so the shell still starts in a
    // sensible place when no seed is available.
    let cwd_path = cwd.map(std::path::PathBuf::from).filter(|p| p.is_dir());
    if let Some(c) = cwd_path.as_ref() {
        cmd.current_dir(c);
    } else if let Some(home) = home_dir.as_ref().filter(|h| h.is_dir()) {
        cmd.current_dir(home);
    }
    // Clean up inherited env that interferes with nested tools
    cmd.env_remove("CLAUDECODE");

    // Pass through ufoo environment variables for agent coordination
    for (key, value) in std::env::vars() {
        if key.starts_with("UFOO_") {
            cmd.env(&key, &value);
        }
    }

    // Expose ufoo Terminal Host Protocol env vars for agent coordination
    cmd.env("UFOO_HOST_NAME", "horizon");
    cmd.env("UFOO_HOST_SESSION_ID", session_id);
    // Host-launched agents already run inside a real PTY provided by Horizon.
    // Disabling ufoo's nested node-pty wrapper avoids double-PTY input quirks
    // such as Enter being interpreted as newline inside Codex.
    cmd.env("UFOO_DISABLE_PTY", "1");
    if let Some(home) = home_dir.as_ref() {
        let base = home.join(".blackhole").join("horizon");
        let inject_sock = base.join("sessions").join(session_id).join("inject.sock");
        cmd.env(
            "UFOO_HOST_INJECT_SOCK",
            inject_sock.to_string_lossy().as_ref(),
        );
        let daemon_sock = base.join("daemon.sock");
        cmd.env(
            "UFOO_HOST_DAEMON_SOCK",
            daemon_sock.to_string_lossy().as_ref(),
        );
    }
    // Set additional env vars from the create_session request (e.g., UFOO_SUBSCRIBER_ID)
    if let Some(env_map) = env_vars {
        for (key, value) in env_map {
            if let Some(value_str) = value.as_str() {
                cmd.env(key, value_str);
            }
        }
    }
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
        history_base_offset: std::sync::Mutex::new(0),
        history_dirty: AtomicBool::new(false),
        rows: AtomicU16::new(session_persist::DEFAULT_ROWS),
        cols: AtomicU16::new(session_persist::DEFAULT_COLS),
        closed: AtomicBool::new(false),
    })
}

#[cfg(windows)]
fn spawn_pty_session(
    session_id: &str,
    shell: &str,
    _startup_command: Option<&str>,
    _env_vars: Option<&serde_json::Map<String, serde_json::Value>>,
    _cwd: Option<&str>,
) -> std::io::Result<PtySession> {
    let conpty = winconpty::ConPty::spawn(shell, 24, 80)?;
    Ok(PtySession {
        session_id: session_id.to_string(),
        conpty,
        history: std::sync::Mutex::new(Vec::<u8>::new()),
        history_base_offset: std::sync::Mutex::new(0),
        history_dirty: AtomicBool::new(false),
        rows: AtomicU16::new(session_persist::DEFAULT_ROWS),
        cols: AtomicU16::new(session_persist::DEFAULT_COLS),
        closed: AtomicBool::new(false),
    })
}

#[cfg(not(any(unix, windows)))]
fn spawn_pty_session(
    _session_id: &str,
    _shell: &str,
    _startup_command: Option<&str>,
    _env_vars: Option<&serde_json::Map<String, serde_json::Value>>,
    _cwd: Option<&str>,
) -> std::io::Result<PtySession> {
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
        layout: None,
        layout_revision: 0,
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

async fn handle_group_layout_update(
    state: &Arc<AppState>,
    group_id: &str,
    layout: serde_json::Value,
    base_revision: Option<u64>,
    sink: &mut futures_util::stream::SplitSink<WebSocket, AxumMessage>,
) {
    if !layout.is_object() {
        let _ = send_group_error(sink, "invalid_layout", "Layout must be a JSON object.").await;
        return;
    }

    let mut groups = state.groups.lock().await;
    let Some(group) = groups.iter_mut().find(|g| g.id == group_id) else {
        let _ = send_group_error(sink, "group_not_found", "Group not found.").await;
        return;
    };
    group.layout = Some(layout);
    group.layout_revision = base_revision
        .map(|revision| revision.saturating_add(1))
        .unwrap_or_else(|| group.layout_revision.saturating_add(1))
        .max(group.layout_revision.saturating_add(1));

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
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
        layout: None,
        layout_revision: 0,
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

async fn handle_group_layout_update_wormhole(
    state: &Arc<AppState>,
    group_id: &str,
    layout: serde_json::Value,
    base_revision: Option<u64>,
    sink: &mut WormholeSink,
) {
    if !layout.is_object() {
        let _ = send_group_error_wormhole(sink, "invalid_layout", "Layout must be a JSON object.")
            .await;
        return;
    }

    let mut groups = state.groups.lock().await;
    let Some(group) = groups.iter_mut().find(|g| g.id == group_id) else {
        let _ = send_group_error_wormhole(sink, "group_not_found", "Group not found.").await;
        return;
    };
    group.layout = Some(layout);
    group.layout_revision = base_revision
        .map(|revision| revision.saturating_add(1))
        .unwrap_or_else(|| group.layout_revision.saturating_add(1))
        .max(group.layout_revision.saturating_add(1));

    let session_names = state.session_names.lock().await;
    save_groups(&state.data_dir, &groups, &session_names);
    broadcast_group_sync(state, &groups, &session_names);
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

#[derive(Debug, Clone)]
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
    /// Enable VPN server.
    vpn: bool,
    /// Optional VPN-facing WebSocket bind address for Blackhole app takeover.
    vpn_ws_bind: Option<IpAddr>,
    /// VPN subnet (default: 10.13.37.0/24).
    vpn_subnet: String,
    /// WireGuard UDP listen port (default: 51820).
    vpn_port: u16,
    /// Internal network routes to advertise to VPN clients.
    vpn_routes: Vec<String>,
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
    let mut vpn = false;
    let vpn_ws_bind = None::<IpAddr>;
    let mut vpn_subnet = "10.13.37.0/24".to_string();
    let mut vpn_port = 51820u16;
    let mut vpn_routes: Vec<String> = Vec::new();

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
            "--vpn" => vpn = true,
            "--vpn-subnet" => {
                let Some(v) = it.next() else {
                    return Err("--vpn-subnet requires a value".to_string());
                };
                vpn_subnet = v;
            }
            "--vpn-port" => {
                let Some(v) = it.next() else {
                    return Err("--vpn-port requires a value".to_string());
                };
                vpn_port = v
                    .parse::<u16>()
                    .map_err(|_| format!("invalid --vpn-port: {v}"))?;
            }
            "--vpn-routes" => {
                let Some(v) = it.next() else {
                    return Err("--vpn-routes requires a value".to_string());
                };
                vpn_routes.extend(v.split(',').map(|s| s.trim().to_string()));
            }
            _ if arg.starts_with("--vpn-subnet=") => {
                vpn_subnet = arg.trim_start_matches("--vpn-subnet=").to_string();
            }
            _ if arg.starts_with("--vpn-port=") => {
                let v = arg.trim_start_matches("--vpn-port=");
                vpn_port = v
                    .parse::<u16>()
                    .map_err(|_| format!("invalid --vpn-port: {v}"))?;
            }
            _ if arg.starts_with("--vpn-routes=") => {
                let v = arg.trim_start_matches("--vpn-routes=");
                vpn_routes.extend(v.split(',').map(|s| s.trim().to_string()));
            }
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

    // Validate vpn_subnet CIDR format
    if vpn {
        if let Err(e) = validate_cidr(&vpn_subnet) {
            return Err(format!("invalid --vpn-subnet '{}': {}", vpn_subnet, e));
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
        vpn,
        vpn_ws_bind,
        vpn_subnet,
        vpn_port,
        vpn_routes,
    })
}

fn usage() -> String {
    [
        "Usage:",
        "  horizon-daemon start [--foreground|--background] [--configure] [server options]",
        "  horizon-daemon foreground [--configure] [server options]",
        "  horizon-daemon background [--configure] [server options]",
        "  horizon-daemon [server options]",
        "",
        "Headless CLI:",
        "  start/foreground/background run a first-use setup guide and then launch Horizon.",
        "  Wormhole is optional; LAN mode is used when Wormhole is not configured.",
        "",
        "Server options:",
        "  horizon-daemon [--bind IP] [--port PORT] [--shell PATH] [--host-name NAME] [--dev-mode]",
        "                 [--wormhole-url WS_URL] [--wormhole-token TOKEN] [--wormhole-session SESSION] [--config-id ID]",
        "                 [--no-initial-session]",
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

fn validate_cidr(cidr: &str) -> Result<(), String> {
    let parts: Vec<&str> = cidr.splitn(2, '/').collect();
    if parts.len() != 2 {
        return Err("expected format: IP/PREFIX (e.g. 10.13.37.0/24)".to_string());
    }
    parts[0]
        .parse::<Ipv4Addr>()
        .map_err(|_| format!("'{}' is not a valid IPv4 address", parts[0]))?;
    let prefix: u8 = parts[1]
        .parse()
        .map_err(|_| format!("'{}' is not a valid prefix length", parts[1]))?;
    if prefix > 32 {
        return Err(format!("prefix length {} exceeds maximum of 32", prefix));
    }
    if prefix < 8 {
        return Err(format!("prefix length {} is too small (minimum 8)", prefix));
    }
    Ok(())
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "Horizon".to_string())
}

fn default_vpn_ws_bind() -> IpAddr {
    IpAddr::V4(Ipv4Addr::new(10, 13, 37, 1))
}

fn websocket_bind_ips(primary_bind: IpAddr, vpn_ws_bind: Option<IpAddr>) -> Vec<IpAddr> {
    let mut binds = vec![primary_bind];
    if let Some(vpn_bind) = vpn_ws_bind {
        if !primary_bind.is_unspecified() && primary_bind != vpn_bind && !binds.contains(&vpn_bind)
        {
            binds.push(vpn_bind);
        }
    }
    binds
}

fn secondary_vpn_ws_addr(
    primary_bind: IpAddr,
    port: u16,
    vpn_ws_bind: Option<IpAddr>,
) -> Option<SocketAddr> {
    if primary_bind.is_unspecified() {
        return None;
    }
    let vpn_bind = vpn_ws_bind?;
    if vpn_bind == primary_bind {
        return None;
    }
    Some(SocketAddr::new(vpn_bind, port))
}

fn enable_explicit_vpn_ws_bind(
    state: &AppState,
    helper_session: Option<&vpn_helper_client::HelperSession>,
) {
    let torn_down = if let Some(session) = helper_session {
        session.disable_ws_redirect()
    } else {
        nat::disable_local_ws_redirect()
    };
    match torn_down {
        Ok(()) => {
            let _ = state.vpn_explicit_ws.send(true);
        }
        Err(e) => {
            warn!("refusing explicit VPN websocket bind until rdr is down: {e}");
        }
    }
}

async fn wait_for_local_ws(bind: IpAddr, port: u16) {
    let addr = if bind.is_unspecified() {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)
    } else {
        SocketAddr::new(bind, port)
    };
    for _ in 0..50 {
        if tokio::net::TcpStream::connect(addr).await.is_ok() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    warn!("timed out waiting for local websocket listener on {addr}");
}

async fn measure_and_maybe_failover(
    state: &AppState,
    helper_session: Option<&vpn_helper_client::HelperSession>,
    tun_fd: i32,
    transport: tun_device::TunTransport,
    rdr_installed: bool,
    env_explicit: bool,
) {
    if env_explicit || !rdr_installed {
        enable_explicit_vpn_ws_bind(state, helper_session);
        return;
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        wait_for_local_ws(state.bind, state.port).await;
        let (tx, rx) = oneshot::channel();
        *state.vpn_tcp_probe.lock().await = Some(tx);
        let timeout = Duration::from_secs(2);
        match vpn_tcp_delivery::tun_tcp_handshake(
            tun_fd,
            transport,
            vpn_tcp_delivery::VPN_PROBE_CLIENT_V4,
            vpn_tcp_delivery::VPN_SERVER_V4,
            49152,
            state.port,
            timeout,
        )
        .await
        {
            Ok(mut session) => {
                let host = vpn_tcp_delivery::VPN_SERVER_V4.to_string();
                if let Err(e) = vpn_tcp_delivery::tun_tcp_send(
                    tun_fd,
                    transport,
                    &mut session,
                    &vpn_tcp_delivery::vpn_probe_http_get(&host),
                    timeout,
                )
                .await
                {
                    warn!("in-tunnel TCP probe HTTP write failed: {e}");
                }
                if let Err(e) =
                    vpn_tcp_delivery::tun_tcp_rst(tun_fd, transport, &session, timeout).await
                {
                    warn!("in-tunnel TCP probe RST failed: {e}");
                }
            }
            Err(e) => {
                warn!("in-tunnel TCP probe handshake failed: {e}");
                *state.vpn_tcp_probe.lock().await = None;
                vpn_tcp_delivery::tun_drain(tun_fd, transport, Duration::from_millis(100)).await;
                enable_explicit_vpn_ws_bind(state, helper_session);
                return;
            }
        }

        let measured = tokio::time::timeout(timeout, rx)
            .await
            .ok()
            .and_then(|result| result.ok());
        *state.vpn_tcp_probe.lock().await = None;
        vpn_tcp_delivery::tun_drain(tun_fd, transport, Duration::from_millis(100)).await;
        let remote = measured.map(|(remote, _)| remote);
        info!(
            remote_addr = ?remote,
            local_addr = ?measured.map(|(_, local)| local),
            "measured in-tunnel TCP accept"
        );
        if vpn_tcp_delivery::rdr_probe_requires_failover(remote) {
            enable_explicit_vpn_ws_bind(state, helper_session);
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (tun_fd, transport);
        enable_explicit_vpn_ws_bind(state, helper_session);
    }
}

fn spawn_explicit_vpn_ws_listener(
    app: Router,
    primary_bind: IpAddr,
    port: u16,
    vpn_ws_bind: Option<IpAddr>,
    mut enabled: watch::Receiver<bool>,
) {
    tokio::spawn(async move {
        loop {
            if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
                return;
            }
            if !*enabled.borrow() {
                tokio::select! {
                    result = enabled.changed() => {
                        if result.is_err() {
                            return;
                        }
                    }
                    _ = shutdown_signal() => return,
                }
                continue;
            }

            let Some(vpn_ws_addr) = vpn_tcp_delivery::vpn_ws_fallback_addr(
                primary_bind,
                port,
                vpn_ws_bind,
                secondary_vpn_ws_addr(primary_bind, port, vpn_ws_bind),
            ) else {
                warn!("explicit VPN websocket bind requested but no address is configured");
                return;
            };

            let mut waiting_logged = false;
            loop {
                if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
                    return;
                }
                if !*enabled.borrow() {
                    break;
                }
                match tokio::net::TcpListener::bind(vpn_ws_addr).await {
                    Ok(listener) => {
                        info!("horizon-daemon VPN websocket listener on {vpn_ws_addr}");
                        let result = axum::serve(
                            listener,
                            app.into_make_service_with_connect_info::<ClientConnectInfo>(),
                        )
                        .with_graceful_shutdown(shutdown_signal())
                        .await;
                        if let Err(err) = result {
                            warn!(
                                "VPN websocket listener ended with error on {vpn_ws_addr}: {err}"
                            );
                        }
                        return;
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::AddrNotAvailable => {
                        if !waiting_logged {
                            info!(
                                "waiting for VPN websocket bind address {vpn_ws_addr} to become available"
                            );
                            waiting_logged = true;
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                    }
                    Err(err) => {
                        warn!("failed to bind VPN websocket listener on {vpn_ws_addr}: {err}");
                        return;
                    }
                }
            }
        }
    });
}

// ============ VPN Server ============

async fn start_vpn_server(
    state: Arc<AppState>,
    port: u16,
    subnet: &str,
    routes: &[String],
) -> Result<(), String> {
    info!("starting VPN server on port {port}, subnet {subnet}");

    {
        let mut advertised_routes = state.wg_internal_routes.lock().await;
        *advertised_routes = routes.to_vec();
    }

    // Load or generate WireGuard keypair (persist to disk for stability)
    let keys_path = state.data_dir.join("wg_keys.json");
    let (pub_key, priv_key) = if let Ok(content) = fs::read_to_string(&keys_path) {
        if let Ok(keys) = serde_json::from_str::<serde_json::Value>(&content) {
            let pk = keys
                .get("publicKey")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let sk = keys
                .get("privateKey")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            if let (Some(pk), Some(sk)) = (pk, sk) {
                info!("loaded existing VPN keypair from {}", keys_path.display());
                (pk, sk)
            } else {
                let (pk, sk) = tunnel::generate_keypair();
                let _ = fs::write(
                    &keys_path,
                    serde_json::to_string_pretty(&json!({
                        "publicKey": pk, "privateKey": sk
                    }))
                    .unwrap_or_default(),
                );
                (pk, sk)
            }
        } else {
            let (pk, sk) = tunnel::generate_keypair();
            let _ = fs::write(
                &keys_path,
                serde_json::to_string_pretty(&json!({
                    "publicKey": pk, "privateKey": sk
                }))
                .unwrap_or_default(),
            );
            (pk, sk)
        }
    } else {
        let (pk, sk) = tunnel::generate_keypair();
        let _ = fs::create_dir_all(&state.data_dir);
        let _ = fs::write(
            &keys_path,
            serde_json::to_string_pretty(&json!({
                "publicKey": pk, "privateKey": sk
            }))
            .unwrap_or_default(),
        );
        info!(
            "generated and saved new VPN keypair to {}",
            keys_path.display()
        );
        (pk, sk)
    };
    info!("VPN WireGuard public key: {}", pub_key);

    // Store public key and port in AppState
    {
        let mut wg_pub = state.wg_public_key.lock().await;
        *wg_pub = Some(pub_key.clone());
    }
    {
        let mut wg_port = state.wg_udp_port.lock().await;
        *wg_port = Some(port);
    }

    let server_ip = VPN_SERVER_IP_STR;
    let env_mode = vpn_tcp_delivery::vpn_tcp_delivery_mode();
    let env_explicit = vpn_tcp_delivery::uses_explicit_bind(env_mode);
    let ws_redirect = !env_explicit;
    info!(
        env_explicit,
        ws_redirect,
        env_rdr = vpn_tcp_delivery::uses_pf_rdr(env_mode),
        app_port = state.port,
        "VPN TCP delivery mode"
    );
    let mut helper_session = None;
    let mut rdr_installed = false;
    let tun = if cfg!(target_os = "macos") && vpn_helper_client::is_available(&state.data_dir) {
        let prepared = vpn_helper_client::start_vpn(
            &state.data_dir,
            server_ip,
            subnet,
            "255.255.255.0",
            state.port,
            ws_redirect,
        )
        .map_err(|e| format!("failed to start VPN via helper: {e}"))?;
        info!("created helper-backed TUN device: {}", prepared.tun.name);
        rdr_installed = prepared.ws_redirect;
        helper_session = Some(prepared.session);
        prepared.tun
    } else {
        let tun = tun_device::create_tun(None)
            .map_err(|e| format!("failed to create TUN device: {e}"))?;
        info!("created TUN device: {}", tun.name);

        tun_device::configure_tun(&tun, server_ip, "255.255.255.0")
            .map_err(|e| format!("failed to configure TUN: {e}"))?;
        info!("TUN device configured with IP {server_ip}");

        if let Err(e) = nat::enable_ip_forwarding() {
            warn!("failed to enable IP forwarding: {e}");
        }
        let local_ws_redirect = if ws_redirect {
            Some((server_ip, state.port, Some(tun.name.as_str())))
        } else {
            None
        };
        match nat::setup_nat(subnet, None, local_ws_redirect) {
            Ok(()) => rdr_installed = ws_redirect,
            Err(e) => {
                if ws_redirect {
                    warn!("failed to setup NAT/rdr: {e}");
                } else {
                    warn!("failed to setup NAT: {e}");
                }
            }
        }

        tun
    };

    measure_and_maybe_failover(
        &state,
        helper_session.as_ref(),
        tun.fd,
        tun.transport,
        rdr_installed,
        env_explicit,
    )
    .await;

    if helper_session.is_none() {
        // Start DNS forwarder
        let dns_listen: SocketAddr = format!("{server_ip}:53")
            .parse()
            .map_err(|e| format!("invalid dns listen addr: {e}"))?;
        let dns_upstream = dns_forwarder::detect_system_dns();
        info!(
            "starting DNS forwarder on {} → {}",
            dns_listen, dns_upstream
        );
        tokio::spawn(async move {
            if let Err(e) = dns_forwarder::run_dns_forwarder(dns_listen, dns_upstream).await {
                warn!("DNS forwarder error: {}", e);
            }
        });
    } else {
        info!("DNS forwarder delegated to privileged VPN helper");
    }

    // Create WG server
    let tun_fd = tun.fd;
    let tun_transport = tun.transport;
    // Prevent TunDevice from closing the fd (WgServer takes ownership)
    std::mem::forget(tun);

    let mut server = wg_server::WgServer::new(priv_key, port, tun_fd, tun_transport)
        .await
        .map_err(|e| format!("failed to create WG server: {e}"))?;
    info!("WireGuard server listening on UDP port {port}");

    let (netcheck_tx, mut netcheck_rx) = mpsc::unbounded_channel();
    server.set_netcheck_observer(netcheck_tx);
    let netcheck_state = state.clone();
    tokio::spawn(async move {
        while let Some(observation) = netcheck_rx.recv().await {
            {
                let mut observed = netcheck_state.wg_observed_endpoints.lock().await;
                record_observed_direct_candidate(
                    &mut observed,
                    Some(&observation.addr),
                    Some(observation.port),
                    "wormhole_netcheck",
                );
            }
            info!(
                addr = %observation.addr,
                port = observation.port,
                scope = "public_observed",
                source = "wormhole_netcheck",
                "recorded public_observed WG mapping"
            );
            send_horizon_endpoint_register(&netcheck_state).await;
        }
    });

    let (netcheck_host, netcheck_port) = configured_wg_netcheck_endpoint(&state);
    if let (Some(host), Some(nc_port)) = (netcheck_host, netcheck_port) {
        match resolve_wg_netcheck_dest(&host, nc_port).await {
            Some(dest) => {
                if let Err(error) = server.begin_netcheck(dest).await {
                    warn!(error = %error, dest = %dest, "failed to send WG netcheck");
                }
            }
            None => {
                warn!(
                    host = %host,
                    port = nc_port,
                    "failed to resolve WG netcheck destination"
                );
            }
        }
    }

    // Create peer command channel and store sender in AppState
    let (peer_tx, peer_rx) = mpsc::unbounded_channel::<WgPeerCommand>();
    {
        let mut tx = state.wg_peer_tx.lock().await;
        *tx = Some(peer_tx);
    }
    vpn_signaling::schedule_publish_horizon_endpoint(state.clone());
    vpn_signaling::spawn_horizon_endpoint_refresh_timer(state.clone());
    vpn_signaling::spawn_upnp_udp_candidate_task(state.clone(), port);

    // Run the WG server event loop with peer command receiver
    if let Err(e) = server.run_with_peer_commands(peer_rx).await {
        warn!("WG server stopped: {e}");
    }

    if let Some(session) = helper_session {
        if let Err(e) = session.stop() {
            warn!("failed to stop helper-backed VPN session: {e}");
        }
    } else if let Err(e) = nat::teardown_nat() {
        warn!("failed to tear down NAT: {e}");
    }

    Ok(())
}

async fn vpn_status_handler(
    ConnectInfo(addr): ConnectInfo<ClientConnectInfo>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, "forbidden").into_response();
    }
    let wg_pub = state.wg_public_key.lock().await.clone();
    let wg_port = state.wg_udp_port.lock().await.clone();
    let wg_addr = state.wg_observed_addr.lock().await.clone();
    let wg_running = state.wg_peer_tx.lock().await.is_some();

    axum::Json(json!({
        "enabled": wg_pub.is_some(),
        "running": wg_running,
        "serverIp": VPN_SERVER_IP_STR,
        "subnet": "10.13.37.0/24",
        "listenPort": wg_port,
        "publicKey": wg_pub,
        "observedAddr": wg_addr,
    }))
    .into_response()
}

fn configured_wg_netcheck_endpoint(state: &Arc<AppState>) -> (Option<String>, Option<u16>) {
    let configured_host = std::env::var("WORMHOLE_NETCHECK_HOST")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let configured_port = std::env::var("WORMHOLE_NETCHECK_PORT")
        .ok()
        .and_then(|value| value.trim().parse::<u16>().ok())
        .filter(|value| *value > 0 && *value != 443)
        .or(Some(6666));

    let derived_host = state.wormhole_url.as_deref().and_then(|base_url| {
        let without_scheme = base_url.split("://").nth(1).unwrap_or(base_url);
        let authority = without_scheme.split('/').next().unwrap_or(without_scheme);
        let host_port = authority.rsplit('@').next().unwrap_or(authority).trim();
        let host = host_port
            .strip_prefix('[')
            .and_then(|value| value.split(']').next())
            .unwrap_or_else(|| host_port.split(':').next().unwrap_or(host_port))
            .trim();
        if host.is_empty() {
            None
        } else {
            Some(host.to_string())
        }
    });

    (configured_host.or(derived_host), configured_port)
}

async fn resolve_wg_netcheck_dest(host: &str, port: u16) -> Option<SocketAddr> {
    if port == 0 || port == 443 {
        return None;
    }
    tokio::net::lookup_host((host, port)).await.ok()?.next()
}

async fn send_horizon_endpoint_register(state: &Arc<AppState>) {
    let sender = state.wormhole_sender.lock().await.clone();
    let Some(sender) = sender else {
        return;
    };
    let wg_pub = state.wg_public_key.lock().await.clone();
    let wg_port = *state.wg_udp_port.lock().await;
    if wg_pub.is_none() && wg_port.is_none() {
        return;
    }
    let horizon_candidates = current_horizon_direct_candidates(state).await;
    let _ = sender.send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
        json!({
            "type": "endpoint_register",
            "wgPublicKey": wg_pub,
            "wgUdpPort": wg_port,
            "horizonCandidates": horizon_candidates,
        }),
    )));
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
        // Reset subscriber count so stale counts don't suppress the PTY
        // stream after reconnect (session_assigned re-initialises it).
        state.wormhole_subscriber_count.store(0, Ordering::SeqCst);
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

    let connect_started_at = tokio::time::Instant::now();
    let connect = tokio_tungstenite::connect_async(url.clone());
    let (ws, _) = match tokio::time::timeout(RELAY_CONNECT_TIMEOUT, connect).await {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return Err(classify_wormhole_ws_error(&e)),
        Err(_) => {
            return Err(WormholeConnectError {
                kind: "timeout",
                message: format!(
                    "Timed out connecting to relay after {} ms (timeout={}s, url={}).",
                    connect_started_at.elapsed().as_millis(),
                    RELAY_CONNECT_TIMEOUT.as_secs(),
                    url
                ),
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
    let mut heartbeat = tokio::time::interval(std::time::Duration::from_secs(5));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_incoming = tokio::time::Instant::now();
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

    vpn_signaling::publish_horizon_endpoint_on_wormhole_connect(state).await;

    loop {
        tokio::select! {
            msg = read.next() => {
                let Some(Ok(msg)) = msg else { return Ok(()) };
                last_incoming = tokio::time::Instant::now();
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
            _ = heartbeat.tick() => {
                if last_incoming.elapsed() > std::time::Duration::from_secs(20) {
                    debug!("wormhole heartbeat timeout, reconnecting silently");
                    return Ok(());
                }
                let ping = encode_json(json!({"type":"ping"}));
                if write.send(tokio_tungstenite::tungstenite::Message::Text(ping)).await.is_err() {
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
                "remote_log" => {
                    if let Some(line) = value.get("line").and_then(|v| v.as_str()) {
                        append_remote_log(state, line).await;
                    }
                }
                "ping" => {
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Binary(
                            build_pong_message(),
                        ))
                        .await;
                }
                "pong" => {}
                "session_assigned" => {
                    if let Some(session_id) = value.get("sessionId").and_then(|v| v.as_str()) {
                        info!("wormhole session assigned: {session_id}");
                        let mut wh = state.wormhole_state.lock().await;
                        wh.session_id = Some(session_id.to_string());
                    }
                    // Initialise the subscriber counter from the relay's current
                    // voyager count so a reconnecting Horizon gates correctly.
                    let count = value
                        .get("voyagerCount")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as usize;
                    state
                        .wormhole_subscriber_count
                        .store(count, Ordering::SeqCst);
                }
                "voyager_connect" => {
                    state
                        .wormhole_subscriber_count
                        .fetch_add(1, Ordering::SeqCst);
                    handle_voyager_connect_wormhole(state, &value, write).await;
                }
                "voyager_disconnect" => {
                    state
                        .wormhole_subscriber_count
                        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                            Some(n.saturating_sub(1))
                        })
                        .ok();
                }
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
                    let requested_offset = value
                        .get("offset")
                        .and_then(|v| v.as_u64())
                        .and_then(|v| usize::try_from(v).ok());
                    let delta = get_history_delta(state, session_id, requested_offset)
                        .await
                        .unwrap_or(HistoryDelta {
                            offset: 0,
                            next_offset: 0,
                            reset: true,
                            content: String::new(),
                        });
                    let _ = write
                        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
                            json!({
                                "type": "session_sync",
                                "sessionId": session_id,
                                "offset": delta.offset,
                                "nextOffset": delta.next_offset,
                                "reset": delta.reset,
                                "content": delta.content,
                            }),
                        )))
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
                "group_layout_update" => {
                    let group_id = value.get("groupId").and_then(|v| v.as_str());
                    let layout = value.get("layout").cloned();
                    let base_revision = value.get("baseRevision").and_then(|v| v.as_u64());
                    if let (Some(gid), Some(layout)) = (group_id, layout) {
                        handle_group_layout_update_wormhole(
                            state,
                            gid,
                            layout,
                            base_revision,
                            write,
                        )
                        .await;
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
                // WireGuard VPN endpoint signaling
                "endpoint_registered" => {
                    let observed_addr = value.get("observedAddr").and_then(|v| v.as_str());
                    let observed_port = value.get("observedPort").and_then(|v| v.as_u64());
                    if let Some(addr) = observed_addr {
                        let mut wg_addr = state.wg_observed_addr.lock().await;
                        *wg_addr = Some(addr.to_string());
                        // TCP observedPort from Wormhole is not a WG mapping.
                        info!(
                            "wg endpoint registered: observed {} (tcp port {})",
                            addr,
                            observed_port.unwrap_or(0)
                        );
                    }
                }
                ty if vpn_signaling::is_vpn_control_type(ty) => {
                    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel();
                    vpn_signaling::handle_vpn_control(state, &value, reply_tx).await;
                    while let Some(reply) = reply_rx.recv().await {
                        let _ = write
                            .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
                                reply,
                            )))
                            .await;
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
    build_wormhole_socket_url(base_url, token, session, "horizon", "/ws")
}

fn build_wormhole_socket_url(
    base_url: &str,
    token: Option<&str>,
    session: Option<&str>,
    role: &str,
    path: &str,
) -> Result<String, String> {
    // base_url is typically like: ws://host:6666/ws
    // It may already have query parameters.
    let mut parts = base_url.splitn(2, '?');
    let base = parts.next().unwrap_or(base_url);
    let existing = parts.next();
    let target_base = if let Some((prefix, _)) = base.rsplit_once('/') {
        format!("{prefix}{path}")
    } else {
        return Err(format!("invalid wormhole base URL: {base_url}"));
    };

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

    query.retain(|(key, _)| key != "role" && key != "session" && key != "token");
    query.push(("role".to_string(), role.to_string()));
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
    Ok(format!("{target_base}?{q}"))
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

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(addr: &str, port: u16, scope: &str, priority: i32) -> DirectCandidate {
        DirectCandidate {
            addr: addr.to_string(),
            port,
            scope: scope.to_string(),
            priority,
            source: "test".to_string(),
        }
    }

    #[test]
    fn record_observed_direct_candidate_promotes_new_endpoint_and_keeps_last_known() {
        let mut store = Vec::new();

        record_observed_direct_candidate(
            &mut store,
            Some("1.2.3.4"),
            Some(1111),
            "wormhole_observed",
        );
        record_observed_direct_candidate(
            &mut store,
            Some("1.2.3.4"),
            Some(2222),
            "wormhole_observed",
        );

        assert_eq!(store.len(), 2);
        assert_eq!(store[0].scope, "public_observed");
        assert_eq!(store[0].port, 2222);
        assert_eq!(store[1].scope, "last_known");
        assert_eq!(store[1].port, 1111);
        assert_eq!(classify_nat_mapping_behavior(&store), "port_variant");
    }

    #[test]
    fn direct_reachability_score_and_hairpin_reflect_lan_candidates() {
        let horizon = vec![
            candidate("192.168.1.10", 51820, "lan", 250),
            candidate("1.2.3.4", 51820, "public_observed", 180),
        ];
        let voyager = vec![
            candidate("192.168.1.20", 25000, "lan", 250),
            candidate("1.2.3.4", 25000, "public_observed", 180),
        ];

        let hairpin = hairpin_likely(Some("1.2.3.4"), &voyager);
        let score = compute_direct_reachability_score(&horizon, &voyager, "stable", hairpin);

        assert!(hairpin);
        assert!(score >= 90);
    }

    #[test]
    fn upnp_does_not_replace_netcheck_public_observed() {
        let mut store = Vec::new();
        record_observed_direct_candidate(
            &mut store,
            Some("203.0.113.10"),
            Some(40123),
            "wormhole_netcheck",
        );
        record_upnp_udp_candidate(&mut store, "203.0.113.10", 51820);

        assert_eq!(store[0].scope, "public_observed");
        assert_eq!(store[0].port, 40123);
        assert_eq!(store[0].source, "wormhole_netcheck");
        assert_eq!(store[1].scope, "last_known");
        assert_eq!(store[1].port, 51820);
        assert_eq!(store[1].source, "upnp");
    }
}
