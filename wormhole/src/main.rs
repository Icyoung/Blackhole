use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, Mutex};
use tracing::{info, warn};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Horizon,
    Voyager,
}

#[derive(Debug)]
struct Session {
    horizon: Option<mpsc::UnboundedSender<Message>>,
    voyagers: Vec<VoyagerInfo>,
    custom_session: bool,
    /// Horizon's WireGuard public key (base64).
    wg_public_key: Option<String>,
    /// Horizon's WireGuard UDP listen port.
    wg_udp_port: Option<u16>,
    /// Horizon's observed public IP:port (as seen by Wormhole).
    horizon_observed_addr: Option<SocketAddr>,
    /// Horizon direct endpoint candidates advertised to Voyagers.
    horizon_candidates: Vec<DirectCandidate>,
    /// Recently observed Horizon endpoints from Wormhole's point of view.
    horizon_observed_endpoints: Vec<DirectCandidate>,
    /// Monotonic epoch used to coordinate simultaneous hole-punch attempts.
    punch_epoch: u64,
}

impl Session {
    fn new() -> Self {
        Self {
            horizon: None,
            voyagers: Vec::new(),
            custom_session: false,
            wg_public_key: None,
            wg_udp_port: None,
            horizon_observed_addr: None,
            horizon_candidates: Vec::new(),
            horizon_observed_endpoints: Vec::new(),
            punch_epoch: 0,
        }
    }

    fn has_live_connections(&self) -> bool {
        self.horizon.is_some()
            || !self.voyagers.is_empty()
    }
}

#[derive(Clone)]
struct AppState {
    sessions: Arc<Mutex<HashMap<String, Session>>>,
    token: Option<String>,
}

fn configured_netcheck_endpoint() -> (Option<String>, Option<u16>) {
    let host = std::env::var("WORMHOLE_NETCHECK_HOST")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let port = std::env::var("WORMHOLE_NETCHECK_PORT")
        .ok()
        .and_then(|value| value.trim().parse::<u16>().ok())
        .filter(|value| *value > 0)
        .or_else(|| {
            std::env::var("PORT")
                .ok()
                .and_then(|value| value.trim().parse::<u16>().ok())
                .filter(|value| *value > 0)
        });
    (host, port)
}

#[derive(Debug, Deserialize)]
struct WsParams {
    role: String,
    session: Option<String>,
    token: Option<String>,
    device_key: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    public_key: Option<String>,
    transport_id: Option<String>,
    path_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PairingState {
    Pending,
    Approved,
    Rejected,
}

#[derive(Debug)]
struct VoyagerInfo {
    tx: mpsc::UnboundedSender<Message>,
    device_key: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    public_key: Option<String>,
    transport_id: Option<String>,
    path_id: Option<String>,
    pairing_state: PairingState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DirectCandidate {
    addr: String,
    port: u16,
    scope: String,
    priority: i32,
    source: String,
}

fn generate_session_id(existing: &HashMap<String, Session>) -> String {
    const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    loop {
        let id: String = (0..6)
            .map(|_| {
                let idx = rng.gen_range(0..CHARSET.len());
                CHARSET[idx] as char
            })
            .collect();
        if !existing.contains_key(&id) {
            return id;
        }
    }
}

#[derive(Debug, Deserialize)]
struct AdminParams {
    token: Option<String>,
}

#[derive(Debug, Serialize)]
struct SessionStatus {
    session: String,
    horizon_connected: bool,
    voyager_count: usize,
}

#[derive(Debug, Serialize)]
struct SessionsResponse {
    sessions: Vec<SessionStatus>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let token = std::env::var("WORMHOLE_TOKEN")
        .ok()
        .filter(|v| !v.is_empty());
    if token.is_some() {
        info!("wormhole token auth enabled");
    } else {
        warn!("wormhole token auth disabled");
    }
    let state = AppState {
        sessions: Arc::new(Mutex::new(HashMap::new())),
        token,
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/sessions", get(list_sessions))
        .route("/sessions/:id", get(get_session).delete(close_session))
        .route("/ws", get(ws_handler))
        .route("/wg-relay", get(wg_relay_stub))
        .with_state(state);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(6666);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!("wormhole listening on {addr}");

    tokio::spawn(run_udp_netcheck_listener(port));

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .unwrap();
}

async fn run_udp_netcheck_listener(port: u16) {
    let bind_addr = SocketAddr::from(([0, 0, 0, 0], port));
    let socket = match UdpSocket::bind(bind_addr).await {
        Ok(socket) => socket,
        Err(error) => {
            warn!(port, error = %error, "failed to bind wormhole UDP netcheck listener");
            return;
        }
    };
    info!(port, "wormhole UDP netcheck listening");

    let mut buf = [0u8; 2048];
    loop {
        let (len, remote_addr) = match socket.recv_from(&mut buf).await {
            Ok(result) => result,
            Err(error) => {
                warn!(error = %error, "wormhole UDP netcheck recv failed");
                continue;
            }
        };

        let payload = match std::str::from_utf8(&buf[..len]) {
            Ok(text) => text,
            Err(_) => continue,
        };
        let Ok(value) = serde_json::from_str::<Value>(payload) else {
            continue;
        };
        if value.get("type").and_then(|entry| entry.as_str()) != Some("netcheck") {
            continue;
        }

        let nonce = value
            .get("nonce")
            .and_then(|entry| entry.as_str())
            .unwrap_or_default();
        let response = serde_json::json!({
            "v": 1,
            "type": "netcheck_response",
            "nonce": nonce,
            "observedAddr": remote_addr.ip().to_string(),
            "observedPort": remote_addr.port(),
        })
        .to_string();

        if let Err(error) = socket.send_to(response.as_bytes(), remote_addr).await {
            warn!(error = %error, remote_addr = %remote_addr, "wormhole UDP netcheck send failed");
        }
    }
}

async fn health() -> &'static str {
    "ok"
}

/// Stub route for WireGuard relay — returns 200 OK as a readiness gate.
/// Phase 3 will replace this with the actual relay negotiation logic.
async fn wg_relay_stub() -> impl IntoResponse {
    (axum::http::StatusCode::OK, "wg-relay stub")
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    ConnectInfo(remote_addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
) -> impl IntoResponse {
    let observed_addr = effective_remote_addr(&headers, remote_addr);
    let role = match params.role.as_str() {
        "horizon" => Role::Horizon,
        "voyager" => Role::Voyager,
        _ => return (axum::http::StatusCode::BAD_REQUEST, "invalid role").into_response(),
    };

    // Voyager must provide session ID, Horizon can omit it to get one assigned
    let session = params.session.clone().filter(|s| !s.trim().is_empty());
    if role == Role::Voyager && session.is_none() {
        return (axum::http::StatusCode::BAD_REQUEST, "missing session").into_response();
    }

    if let Some(required) = state.token.as_deref() {
        match params.token.as_deref() {
            Some(token) if token == required => {}
            _ => {
                return (axum::http::StatusCode::UNAUTHORIZED, "invalid token").into_response();
            }
        }
    }

    let device_key = params.device_key.clone();
    let device_name = params.device_name.clone();
    let device_type = params.device_type.clone();
    let public_key = params.public_key.clone();
    let transport_id = params.transport_id.clone();
    let path_id = params.path_id.clone();
    ws.on_upgrade(move |socket| {
        handle_socket(
            state,
            role,
            session,
            device_key,
            device_name,
            device_type,
            public_key,
            transport_id,
            path_id,
            observed_addr,
            socket,
        )
    })
}

fn effective_remote_addr(headers: &HeaderMap, remote_addr: SocketAddr) -> SocketAddr {
    let forwarded_ip = headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse::<IpAddr>().ok())
        .or_else(|| {
            headers
                .get("x-real-ip")
                .and_then(|value| value.to_str().ok())
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .and_then(|value| value.parse::<IpAddr>().ok())
        });

    match forwarded_ip {
        Some(ip) if ip != remote_addr.ip() => SocketAddr::new(ip, 0),
        Some(ip) => SocketAddr::new(ip, remote_addr.port()),
        None => remote_addr,
    }
}

fn parse_direct_candidates(value: &Value, key: &str) -> Vec<DirectCandidate> {
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

fn observed_candidate(remote_addr: SocketAddr, source: &str) -> Option<DirectCandidate> {
    if remote_addr.port() == 0 {
        return None;
    }
    Some(DirectCandidate {
        addr: remote_addr.ip().to_string(),
        port: remote_addr.port(),
        scope: "public_observed".to_string(),
        priority: 180,
        source: source.to_string(),
    })
}

fn observed_ip_candidate(
    remote_ip: IpAddr,
    port: Option<u16>,
    scope: &str,
    priority: i32,
    source: &str,
) -> Option<DirectCandidate> {
    let port = port?;
    if port == 0 {
        return None;
    }
    Some(DirectCandidate {
        addr: remote_ip.to_string(),
        port,
        scope: scope.to_string(),
        priority,
        source: source.to_string(),
    })
}

fn merge_candidates(
    base: &[DirectCandidate],
    extra: impl IntoIterator<Item = DirectCandidate>,
) -> Vec<DirectCandidate> {
    let mut merged = base.to_vec();
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

fn has_scope(candidates: &[DirectCandidate], scope: &str) -> bool {
    candidates.iter().any(|candidate| candidate.scope == scope)
}

fn parse_candidate_ip(addr: &str) -> Option<IpAddr> {
    addr.trim().parse::<IpAddr>().ok()
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

fn hairpin_likely(
    horizon_observed_addr: Option<SocketAddr>,
    voyager_candidates: &[DirectCandidate],
) -> bool {
    let Some(horizon_ip) = horizon_observed_addr.map(|addr| addr.ip()) else {
        return false;
    };
    voyager_candidates.iter().any(|candidate| {
        matches!(candidate.scope.as_str(), "public_observed" | "last_known")
            && parse_candidate_ip(&candidate.addr) == Some(horizon_ip)
    })
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

fn record_observed_candidate(
    store: &mut Vec<DirectCandidate>,
    remote_addr: SocketAddr,
    source: &str,
) -> Option<DirectCandidate> {
    let candidate = observed_candidate(remote_addr, source)?;
    for existing in store.iter_mut() {
        if existing.scope == "public_observed" {
            existing.scope = "last_known".to_string();
            existing.priority = 120;
        }
    }
    if let Some(existing) = store
        .iter_mut()
        .find(|existing| existing.addr == candidate.addr && existing.port == candidate.port)
    {
        existing.scope = "public_observed".to_string();
        existing.priority = 180;
        existing.source = source.to_string();
    } else {
        store.push(candidate.clone());
    }
    store.sort_by(|a, b| b.priority.cmp(&a.priority));
    if store.len() > 8 {
        store.truncate(8);
    }
    Some(candidate)
}

async fn list_sessions(
    State(state): State<AppState>,
    Query(params): Query<AdminParams>,
) -> impl IntoResponse {
    if !token_valid(&state, params.token.as_deref()) {
        return (axum::http::StatusCode::UNAUTHORIZED, "invalid token").into_response();
    }

    let sessions = state.sessions.lock().await;
    let response = SessionsResponse {
        sessions: sessions
            .iter()
            .map(|(session_id, session)| SessionStatus {
                session: session_id.clone(),
                horizon_connected: session.horizon.is_some(),
                voyager_count: session.voyagers.len(),
            })
            .collect(),
    };
    axum::Json(response).into_response()
}

async fn get_session(
    State(state): State<AppState>,
    Query(params): Query<AdminParams>,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    if !token_valid(&state, params.token.as_deref()) {
        return (axum::http::StatusCode::UNAUTHORIZED, "invalid token").into_response();
    }

    let sessions = state.sessions.lock().await;
    let Some(session) = sessions.get(&session_id) else {
        return (axum::http::StatusCode::NOT_FOUND, "not found").into_response();
    };

    axum::Json(SessionStatus {
        session: session_id,
        horizon_connected: session.horizon.is_some(),
        voyager_count: session.voyagers.len(),
    })
    .into_response()
}

async fn close_session(
    State(state): State<AppState>,
    Query(params): Query<AdminParams>,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    if !token_valid(&state, params.token.as_deref()) {
        return (axum::http::StatusCode::UNAUTHORIZED, "invalid token").into_response();
    }

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.remove(&session_id) else {
        return (axum::http::StatusCode::NOT_FOUND, "not found").into_response();
    };

    if let Some(horizon) = session.horizon.as_ref() {
        let _ = horizon.send(Message::Close(None));
    }
    for voyager in session.voyagers {
        let _ = voyager.tx.send(Message::Close(None));
    }

    (axum::http::StatusCode::OK, "closed").into_response()
}

async fn handle_socket(
    state: AppState,
    role: Role,
    session_param: Option<String>,
    device_key: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    public_key: Option<String>,
    transport_id: Option<String>,
    path_id: Option<String>,
    remote_addr: SocketAddr,
    socket: WebSocket,
) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Determine session ID: use provided one or generate for Horizon
    let (session_id, custom_session, session_in_use) = {
        let mut sessions = state.sessions.lock().await;
        let (id, is_custom) = match (&role, &session_param) {
            (Role::Horizon, None) => (generate_session_id(&sessions), false),
            (Role::Horizon, Some(s)) => {
                // Custom session ID provided by Horizon
                // Check if already in use by another Horizon
                if let Some(existing) = sessions.get(s) {
                    if existing.horizon.is_some() {
                        // Session is in use, will send error
                        (s.clone(), true)
                    } else {
                        (s.clone(), true)
                    }
                } else {
                    (s.clone(), true)
                }
            }
            (Role::Voyager, Some(s)) => (s.clone(), false),
            (Role::Voyager, None) => unreachable!(), // Already validated in ws_handler
        };

        // Check if custom session is already in use by another Horizon
        let in_use = if role == Role::Horizon && is_custom {
            if let Some(existing) = sessions.get(&id) {
                existing.horizon.is_some()
            } else {
                false
            }
        } else {
            false
        };

        if !in_use {
            let session = sessions.entry(id.clone()).or_insert_with(Session::new);
            if is_custom {
                session.custom_session = true;
            }
            match role {
                Role::Horizon => {
                    if session.horizon.is_some() {
                        warn!(session_id = %id, "horizon replaced existing connection");
                    }
                    session.horizon = Some(tx.clone());
                }
                Role::Voyager => {
                    let voyager_info = VoyagerInfo {
                        tx: tx.clone(),
                        device_key: device_key.clone(),
                        device_name: device_name.clone(),
                        device_type: device_type.clone(),
                        public_key: public_key.clone(),
                        transport_id: transport_id.clone(),
                        path_id: path_id.clone(),
                        pairing_state: PairingState::Pending,
                    };
                    session.voyagers.push(voyager_info);
                }
            }
        }
        (id, is_custom, in_use)
    };

    // Handle session_in_use error for Horizon with custom session
    if session_in_use {
        let error_msg = serde_json::json!({
            "v": 1,
            "type": "error",
            "code": "session_in_use",
            "message": "Session ID is already in use"
        });
        let _ = sender.send(Message::Text(error_msg.to_string())).await;
        return;
    }

    // Store the observed remote address for Horizon
    if role == Role::Horizon {
        let mut sessions = state.sessions.lock().await;
        if let Some(session) = sessions.get_mut(&session_id) {
            session.horizon_observed_addr = Some(remote_addr);
        }
    }

    info!(
        session_id = %session_id,
        ?role,
        device_key = ?device_key,
        device_name = ?device_name,
        device_type = ?device_type,
        has_public_key = public_key.is_some(),
        remote_addr = %remote_addr,
        "client connected"
    );

    // Send session_assigned message to Horizon
    if role == Role::Horizon {
        let assign_msg = serde_json::json!({
            "v": 1,
            "type": "session_assigned",
            "sessionId": session_id,
            "custom": custom_session
        });
        if sender
            .send(Message::Text(assign_msg.to_string()))
            .await
            .is_err()
        {
            warn!(session_id = %session_id, "failed to send session_assigned");
            cleanup_connection(state, role, &session_id, &tx).await;
            return;
        }
    }

    // For Voyager, send voyager_connect notification to Horizon
    if role == Role::Voyager {
        let connect_msg = serde_json::json!({
            "v": 1,
            "type": "voyager_connect",
            "deviceKey": device_key,
            "deviceName": device_name.clone().unwrap_or_else(|| "Unknown Device".to_string()),
            "deviceType": device_type,
            "publicKey": public_key,
            "transportId": transport_id,
            "pathId": path_id,
        });
        let mut sessions = state.sessions.lock().await;
        if let Some(session) = sessions.get_mut(&session_id) {
            if let Some(horizon) = session.horizon.as_ref() {
                let _ = horizon.send(Message::Text(connect_msg.to_string()));
            } else {
                // No Horizon connected, auto-reject the pairing
                drop(sessions);
                let reject_msg = serde_json::json!({
                    "v": 1,
                    "type": "pairing_result",
                    "approved": false,
                    "reason": "horizon_offline"
                });
                let _ = sender.send(Message::Text(reject_msg.to_string())).await;
                cleanup_connection(state, role, &session_id, &tx).await;
                return;
            }
        }
    }

    let session_id_for_send = session_id.clone();
    let state_for_send = state.clone();
    let tx_for_send = tx.clone();
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(msg).await.is_err() {
                break;
            }
        }
        cleanup_connection(state_for_send, role, &session_id_for_send, &tx_for_send).await;
    });

    while let Some(Ok(msg)) = receiver.next().await {
        route_message(
            state.clone(),
            role,
            &session_id,
            msg,
            Some(tx.clone()),
            remote_addr,
        )
        .await;
    }

    cleanup_connection(state.clone(), role, &session_id, &tx).await;
    send_task.abort();
    info!(session_id = %session_id, ?role, "client disconnected");
}

async fn route_message(
    state: AppState,
    role: Role,
    session_id: &str,
    msg: Message,
    origin: Option<mpsc::UnboundedSender<Message>>,
    remote_addr: SocketAddr,
) {
    if let Message::Text(text) = &msg {
        if let Ok(value) = serde_json::from_str::<Value>(text) {
            if value.get("type").and_then(|v| v.as_str()) == Some("ping") {
                if let Some(origin) = origin.as_ref() {
                    let pong = serde_json::json!({
                        "v": 1,
                        "type": "pong",
                    });
                    let _ = origin.send(Message::Text(pong.to_string()));
                }
                return;
            }
        }
    }

    if let Message::Ping(payload) = &msg {
        if let Some(origin) = origin.as_ref() {
            let _ = origin.send(Message::Pong(payload.clone()));
        }
        return;
    }

    if matches!(msg, Message::Pong(_)) {
        return;
    }

    if role == Role::Voyager {
        log_delete_probe(&msg, session_id);
        log_resize_probe(&msg, session_id);
    }

    // Handle control messages from Horizon
    if role == Role::Horizon {
        if let Message::Text(text) = &msg {
            if let Ok(value) = serde_json::from_str::<Value>(text) {
                if let Some(msg_type) = value.get("type").and_then(|v| v.as_str()) {
                    match msg_type {
                        "pairing_response" => {
                            handle_pairing_response(state.clone(), session_id, &value).await;
                            return;
                        }
                        "endpoint_register" => {
                            handle_endpoint_register(
                                state.clone(),
                                session_id,
                                &value,
                                remote_addr,
                                origin.as_ref(),
                            )
                            .await;
                            return;
                        }
                        "direct_candidates_update" => {
                            handle_endpoint_register(
                                state.clone(),
                                session_id,
                                &value,
                                remote_addr,
                                origin.as_ref(),
                            )
                            .await;
                            return;
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    // Handle endpoint_request from Voyager
    if role == Role::Voyager {
        if let Message::Text(text) = &msg {
            if let Ok(value) = serde_json::from_str::<Value>(text) {
                if let Some(msg_type) = value.get("type").and_then(|v| v.as_str()) {
                    match msg_type {
                        "endpoint_request" | "endpoint_probe_request" => {
                            handle_endpoint_request(
                                state.clone(),
                                session_id,
                                &value,
                                remote_addr,
                                origin.as_ref(),
                            )
                            .await;
                            return;
                        }
                        "peer_endpoint" | "direct_candidates_update" => {
                            handle_voyager_direct_candidates_update(
                                state.clone(),
                                session_id,
                                &value,
                                remote_addr,
                            )
                            .await;
                            return;
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };

    match role {
        Role::Horizon => {
            // Only send to approved voyagers
            session.voyagers.retain(|v| {
                if v.pairing_state == PairingState::Approved {
                    v.tx.send(msg.clone()).is_ok()
                } else {
                    true // Keep pending/rejected voyagers in list for now
                }
            });
        }
        Role::Voyager => {
            // Check if this voyager is approved and capture transport metadata.
            let mut approved_transport_id: Option<String> = None;
            let mut approved_path_id: Option<String> = None;
            let is_approved = session.voyagers.iter().any(|v| {
                if let Some(origin_tx) = origin.as_ref() {
                    let same = v.tx.same_channel(origin_tx);
                    let approved = v.pairing_state == PairingState::Approved;
                    if same && approved {
                        approved_transport_id = v.transport_id.clone();
                        approved_path_id = v.path_id.clone();
                    }
                    same && approved
                } else {
                    false
                }
            });

            if !is_approved {
                // Voyager not yet approved, drop the message
                return;
            }

            if let Some(horizon) = session.horizon.as_ref() {
                let outbound = inject_transport_metadata(
                    msg,
                    approved_transport_id.as_deref(),
                    approved_path_id.as_deref(),
                );
                if horizon.send(outbound).is_err() {
                    session.horizon = None;
                }
            } else {
                if let Some(origin) = origin.as_ref() {
                    if let Some(reply) = build_no_horizon_reply(&msg) {
                        let _ = origin.send(reply);
                    }
                }
            }
        }
    }
}

async fn handle_pairing_response(state: AppState, session_id: &str, value: &Value) {
    let device_key = value.get("deviceKey").and_then(|v| v.as_str());
    let approved = value
        .get("approved")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let assigned_key = value.get("assignedKey").and_then(|v| v.as_str());
    let horizon_public_key = value.get("publicKey").and_then(|v| v.as_str());

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };

    // Target the newest pending Voyager connection for this device key.
    // Reconnect storms can leave older approved connections in the session,
    // and those should not absorb the pairing_result meant for the active socket.
    let voyager = if let Some(key) = device_key {
        session.voyagers.iter_mut().rev().find(|v| {
            v.pairing_state == PairingState::Pending
                && (v.device_key.as_deref() == Some(key) || v.device_key.is_none())
        })
    } else {
        session
            .voyagers
            .iter_mut()
            .rev()
            .find(|v| v.pairing_state == PairingState::Pending)
    };

    let Some(voyager) = voyager else {
        return;
    };

    if approved {
        voyager.pairing_state = PairingState::Approved;
        if let Some(key) = assigned_key {
            voyager.device_key = Some(key.to_string());
        }
        let result_msg = serde_json::json!({
            "v": 1,
            "type": "pairing_result",
            "approved": true,
            "assignedKey": assigned_key,
            "publicKey": horizon_public_key
        });
        let _ = voyager.tx.send(Message::Text(result_msg.to_string()));
        info!(session_id = %session_id, device_key = ?voyager.device_key, has_horizon_public_key = horizon_public_key.is_some(), "voyager pairing approved");
    } else {
        voyager.pairing_state = PairingState::Rejected;
        let result_msg = serde_json::json!({
            "v": 1,
            "type": "pairing_result",
            "approved": false
        });
        let _ = voyager.tx.send(Message::Text(result_msg.to_string()));
        // Close the connection for rejected voyager
        let _ = voyager.tx.send(Message::Close(None));
        info!(session_id = %session_id, device_key = ?device_key, "voyager pairing rejected");
    }
}

/// Horizon registers its WG public key and UDP port.
/// Wormhole stores these and replies with the observed public IP.
async fn handle_endpoint_register(
    state: AppState,
    session_id: &str,
    value: &Value,
    remote_addr: SocketAddr,
    origin: Option<&mpsc::UnboundedSender<Message>>,
) {
    let wg_public_key = value.get("wgPublicKey").and_then(|v| v.as_str());
    let wg_udp_port = value
        .get("wgUdpPort")
        .and_then(|v| v.as_u64())
        .map(|v| v as u16);
    let advertised = parse_direct_candidates(value, "horizonCandidates");

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };
    if let Some(key) = wg_public_key {
        session.wg_public_key = Some(key.to_string());
    }
    if let Some(port) = wg_udp_port {
        session.wg_udp_port = Some(port);
    }
    session.horizon_observed_addr = Some(remote_addr);
    let _latest_observed = record_observed_candidate(
        &mut session.horizon_observed_endpoints,
        remote_addr,
        "wormhole_observed",
    );
    session.horizon_candidates =
        merge_candidates(&advertised, session.horizon_observed_endpoints.clone());
    let nat_mapping_behavior = classify_nat_mapping_behavior(&session.horizon_observed_endpoints);
    let direct_reachability_score = compute_direct_reachability_score(
        &session.horizon_candidates,
        &[],
        nat_mapping_behavior,
        false,
    );

    info!(
        session_id = %session_id,
        wg_public_key = ?wg_public_key,
        wg_udp_port = ?wg_udp_port,
        observed_addr = %remote_addr,
        candidate_count = session.horizon_candidates.len(),
        "horizon endpoint registered"
    );

    // Reply with observed public IP
    if let Some(origin) = origin {
        let reply = serde_json::json!({
            "v": 1,
            "type": "endpoint_registered",
            "observedAddr": remote_addr.ip().to_string(),
            "observedPort": remote_addr.port(),
            "observedEndpoints": session.horizon_observed_endpoints,
            "natMappingBehavior": nat_mapping_behavior,
            "hairpinLikely": false,
            "directReachabilityScore": direct_reachability_score,
        });
        let _ = origin.send(Message::Text(reply.to_string()));
    }
}

/// Voyager requests Horizon's WG endpoint info.
/// Wormhole replies with stored info and also notifies Horizon of the Voyager's endpoint.
async fn handle_endpoint_request(
    state: AppState,
    session_id: &str,
    value: &Value,
    remote_addr: SocketAddr,
    origin: Option<&mpsc::UnboundedSender<Message>>,
) {
    let request_type = value
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("endpoint_request");
    let voyager_wg_public_key = value.get("wgPublicKey").and_then(|v| v.as_str());
    let voyager_wg_udp_port = value
        .get("wgUdpPort")
        .and_then(|v| v.as_u64())
        .map(|v| v as u16);
    let voyager_device_key = value.get("deviceKey").and_then(|v| v.as_str());
    let voyager_candidates = merge_candidates(
        &parse_direct_candidates(value, "voyagerCandidates"),
        observed_ip_candidate(
            remote_addr.ip(),
            voyager_wg_udp_port.or_else(|| Some(remote_addr.port())),
            if voyager_wg_udp_port.is_some() {
                "last_known"
            } else {
                "public_observed"
            },
            if voyager_wg_udp_port.is_some() {
                90
            } else {
                100
            },
            if voyager_wg_udp_port.is_some() {
                "wormhole_observed_ip"
            } else {
                "wormhole_observed"
            },
        ),
    );
    let observed_port = voyager_wg_udp_port.unwrap_or(remote_addr.port());

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };
    session.punch_epoch = session.punch_epoch.saturating_add(1);
    let punch_epoch = session.punch_epoch;
    let horizon_candidates = if session.horizon_candidates.is_empty() {
        merge_candidates(&[], session.horizon_observed_endpoints.clone())
    } else {
        session.horizon_candidates.clone()
    };
    let nat_mapping_behavior = classify_nat_mapping_behavior(&session.horizon_observed_endpoints);
    let hairpin_likely = hairpin_likely(session.horizon_observed_addr, &voyager_candidates);
    let direct_reachability_score = compute_direct_reachability_score(
        &horizon_candidates,
        &voyager_candidates,
        nat_mapping_behavior,
        hairpin_likely,
    );

    // Send Horizon's endpoint info to the requesting Voyager
    if let Some(origin) = origin {
        let (netcheck_host, netcheck_port) = configured_netcheck_endpoint();
        let response_type = if request_type == "endpoint_probe_request" {
            "endpoint_probe_response"
        } else {
            "endpoint_info"
        };
        let reply = serde_json::json!({
            "v": 1,
            "type": response_type,
            "wgPublicKey": session.wg_public_key,
            "wgUdpPort": session.wg_udp_port,
            "netcheckHost": netcheck_host,
            "netcheckPort": netcheck_port,
            "horizonAddr": session.horizon_observed_addr.map(|a| a.ip().to_string()),
            "horizonPort": session.horizon_observed_addr.map(|a| a.port()),
            "horizonCandidates": horizon_candidates,
            "observedEndpoints": session.horizon_observed_endpoints,
            "natMappingBehavior": nat_mapping_behavior,
            "hairpinLikely": hairpin_likely,
            "directReachabilityScore": direct_reachability_score,
            "punchEpoch": punch_epoch,
        });
        let _ = origin.send(Message::Text(reply.to_string()));
    }

    // Notify Horizon of this Voyager's endpoint (so Horizon can prepare for hole-punch)
    if let Some(horizon) = session.horizon.as_ref() {
        let direct_update = serde_json::json!({
            "v": 1,
            "type": "direct_candidates_update",
            "deviceKey": voyager_device_key,
            "wgPublicKey": voyager_wg_public_key,
            "wgUdpPort": voyager_wg_udp_port,
            "observedAddr": remote_addr.ip().to_string(),
            "observedPort": observed_port,
            "voyagerCandidates": voyager_candidates,
            "punchEpoch": punch_epoch,
        });
        let _ = horizon.send(Message::Text(direct_update.to_string()));
        let peer_msg = serde_json::json!({
            "v": 1,
            "type": "peer_endpoint",
            "deviceKey": voyager_device_key,
            "wgPublicKey": voyager_wg_public_key,
            "wgUdpPort": voyager_wg_udp_port,
            "observedAddr": remote_addr.ip().to_string(),
            "observedPort": observed_port,
            "voyagerCandidates": voyager_candidates,
            "punchEpoch": punch_epoch,
        });
        let _ = horizon.send(Message::Text(peer_msg.to_string()));
    }

    info!(
        session_id = %session_id,
        voyager_device_key = ?voyager_device_key,
        voyager_has_wg_public_key = voyager_wg_public_key.is_some(),
        voyager_candidate_count = voyager_candidates.len(),
        punch_epoch,
        remote_addr = %remote_addr,
        "voyager endpoint request handled"
    );
}

async fn handle_voyager_direct_candidates_update(
    state: AppState,
    session_id: &str,
    value: &Value,
    remote_addr: SocketAddr,
) {
    let voyager_wg_public_key = value.get("wgPublicKey").and_then(|v| v.as_str());
    let voyager_wg_udp_port = value
        .get("wgUdpPort")
        .and_then(|v| v.as_u64())
        .map(|v| v as u16);
    let voyager_device_key = value.get("deviceKey").and_then(|v| v.as_str());
    let voyager_candidates = merge_candidates(
        &parse_direct_candidates(value, "voyagerCandidates"),
        observed_ip_candidate(
            remote_addr.ip(),
            voyager_wg_udp_port.or_else(|| Some(remote_addr.port())),
            if voyager_wg_udp_port.is_some() {
                "last_known"
            } else {
                "public_observed"
            },
            if voyager_wg_udp_port.is_some() {
                90
            } else {
                100
            },
            if voyager_wg_udp_port.is_some() {
                "wormhole_observed_ip"
            } else {
                "wormhole_observed"
            },
        ),
    );
    let observed_port = voyager_wg_udp_port.unwrap_or(remote_addr.port());

    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };
    session.punch_epoch = session.punch_epoch.saturating_add(1);
    let punch_epoch = session.punch_epoch;

    if let Some(horizon) = session.horizon.as_ref() {
        let direct_update = serde_json::json!({
            "v": 1,
            "type": "direct_candidates_update",
            "deviceKey": voyager_device_key,
            "wgPublicKey": voyager_wg_public_key,
            "wgUdpPort": voyager_wg_udp_port,
            "observedAddr": remote_addr.ip().to_string(),
            "observedPort": observed_port,
            "voyagerCandidates": voyager_candidates,
            "punchEpoch": punch_epoch,
        });
        let _ = horizon.send(Message::Text(direct_update.to_string()));
    }

    info!(
        session_id = %session_id,
        voyager_device_key = ?voyager_device_key,
        voyager_has_wg_public_key = voyager_wg_public_key.is_some(),
        voyager_candidate_count = voyager_candidates.len(),
        punch_epoch,
        remote_addr = %remote_addr,
        "voyager direct candidates updated"
    );
}

fn log_delete_probe(msg: &Message, session_id: &str) {
    match msg {
        Message::Binary(data) => {
            if let Some(bytes) = extract_stdin_payload(data) {
                if bytes.iter().any(|b| *b == 0x08 || *b == 0x7f) {
                    let hex = bytes
                        .iter()
                        .map(|b| format!("{:02x}", b))
                        .collect::<Vec<_>>()
                        .join(" ");
                    info!(session_id = %session_id, bytes = %hex, "wormhole stdin delete bytes (binary)");
                }
            }
        }
        Message::Text(text) => {
            if text.contains('\u{8}') || text.contains('\u{7f}') {
                info!(session_id = %session_id, "wormhole stdin delete bytes (text)");
            }
        }
        _ => {}
    }
}

fn extract_stdin_payload(data: &[u8]) -> Option<&[u8]> {
    if data.len() < 4 {
        return None;
    }
    if data[0] != 1 {
        return None;
    }
    if data[1] != 1 {
        return None;
    }
    let session_len = ((data[2] as usize) << 8) | data[3] as usize;
    let header_len = 4 + session_len;
    if data.len() < header_len {
        return None;
    }
    Some(&data[header_len..])
}

fn log_resize_probe(msg: &Message, session_id: &str) {
    let Message::Binary(data) = msg else {
        return;
    };
    if data.len() < 4 {
        return;
    }
    if data[0] != 1 || data[1] != 3 {
        return;
    }
    let session_len = ((data[2] as usize) << 8) | data[3] as usize;
    let header_len = 4 + session_len;
    if data.len() < header_len + 4 {
        return;
    }
    let payload = &data[header_len..header_len + 4];
    let rows = ((payload[0] as u16) << 8) | payload[1] as u16;
    let cols = ((payload[2] as u16) << 8) | payload[3] as u16;
    info!(session_id = %session_id, rows = rows, cols = cols, "wormhole resize");
}

async fn cleanup_connection(
    state: AppState,
    role: Role,
    session_id: &str,
    tx: &mpsc::UnboundedSender<Message>,
) {
    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };

    match role {
        Role::Horizon => {
            if let Some(horizon) = session.horizon.as_ref() {
                if horizon.same_channel(tx) {
                    session.horizon = None;
                }
            }
        }
        Role::Voyager => {
            // Find disconnecting voyager metadata before removing.
            let disconnecting = session.voyagers.iter().find(|v| v.tx.same_channel(tx));
            let disconnecting_key = disconnecting.and_then(|v| v.device_key.clone());
            let disconnecting_transport_id = disconnecting.and_then(|v| v.transport_id.clone());
            let disconnecting_path_id = disconnecting.and_then(|v| v.path_id.clone());

            session.voyagers.retain(|v| !v.tx.same_channel(tx));

            // Notify Horizon about the disconnect
            if let Some(horizon) = session.horizon.as_ref() {
                let disconnect_msg = serde_json::json!({
                    "v": 1,
                    "type": "voyager_disconnect",
                    "deviceKey": disconnecting_key,
                    "transportId": disconnecting_transport_id,
                    "pathId": disconnecting_path_id
                });
                let _ = horizon.send(Message::Text(disconnect_msg.to_string()));
            }
        }
    }

    if !session.has_live_connections() {
        sessions.remove(session_id);
    }
}

fn build_no_horizon_reply(msg: &Message) -> Option<Message> {
    let Message::Text(text) = msg else {
        return None;
    };
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return None;
    };
    let Value::Object(map) = value else {
        return None;
    };
    let Some(Value::String(typ)) = map.get("type") else {
        return None;
    };
    let is_control = matches!(
        typ.as_str(),
        "list"
            | "create"
            | "close"
            | "stdin"
            | "resize"
            | "group_list"
            | "group_create"
            | "group_rename"
            | "group_delete"
            | "group_reorder"
            | "group_delete_with_sessions"
            | "group_move_session"
            | "session_rename"
    );
    if !is_control {
        return None;
    }
    Some(Message::Text(
        serde_json::json!({
            "v": 1,
            "type": "error",
            "code": "horizon_offline",
            "message": "Horizon is not connected for this session"
        })
        .to_string(),
    ))
}

fn inject_transport_metadata(
    msg: Message,
    transport_id: Option<&str>,
    path_id: Option<&str>,
) -> Message {
    let Message::Text(text) = msg else {
        return msg;
    };
    let Ok(mut value) = serde_json::from_str::<Value>(&text) else {
        return Message::Text(text);
    };
    let Value::Object(map) = &mut value else {
        return Message::Text(text);
    };

    if let Some(transport_id) = transport_id {
        map.entry("transportId".to_string())
            .or_insert_with(|| Value::String(transport_id.to_string()));
    }
    if let Some(path_id) = path_id {
        map.entry("pathId".to_string())
            .or_insert_with(|| Value::String(path_id.to_string()));
    }

    Message::Text(value.to_string())
}

fn token_valid(state: &AppState, token: Option<&str>) -> bool {
    match state.token.as_deref() {
        Some(required) => token == Some(required),
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

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
    fn record_observed_candidate_rolls_previous_endpoint_to_last_known() {
        let mut store = Vec::new();
        let first = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(1, 2, 3, 4), 1111));
        let second = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(1, 2, 3, 4), 2222));

        record_observed_candidate(&mut store, first, "wormhole_observed");
        record_observed_candidate(&mut store, second, "wormhole_observed");

        assert_eq!(store.len(), 2);
        assert_eq!(store[0].scope, "public_observed");
        assert_eq!(store[0].port, 2222);
        assert_eq!(store[1].scope, "last_known");
        assert_eq!(store[1].port, 1111);
        assert_eq!(classify_nat_mapping_behavior(&store), "port_variant");
    }

    #[test]
    fn direct_reachability_score_rewards_lan_and_hairpin() {
        let horizon = vec![
            candidate("192.168.1.10", 51820, "lan", 250),
            candidate("1.2.3.4", 51820, "public_observed", 180),
        ];
        let voyager = vec![
            candidate("192.168.1.20", 25000, "lan", 250),
            candidate("1.2.3.4", 25000, "public_observed", 180),
        ];

        let hairpin = hairpin_likely(
            Some(SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::new(1, 2, 3, 4),
                51820,
            ))),
            &voyager,
        );
        let score = compute_direct_reachability_score(&horizon, &voyager, "stable", hairpin);

        assert!(hairpin);
        assert!(score >= 90);
    }
}
