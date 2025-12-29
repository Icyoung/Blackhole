use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
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
    voyagers: Vec<mpsc::UnboundedSender<Message>>,
}

impl Session {
    fn new() -> Self {
        Self {
            horizon: None,
            voyagers: Vec::new(),
        }
    }
}

#[derive(Clone)]
struct AppState {
    sessions: Arc<Mutex<HashMap<String, Session>>>,
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WsParams {
    role: String,
    session: Option<String>,
    token: Option<String>,
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
    tracing_subscriber::fmt()
        .with_env_filter("info")
        .init();

    let token = std::env::var("WORMHOLE_TOKEN").ok().filter(|v| !v.is_empty());
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
        .with_state(state);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(6666);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!("wormhole listening on {addr}");

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn health() -> &'static str {
    "ok"
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
) -> impl IntoResponse {
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
                return (
                    axum::http::StatusCode::UNAUTHORIZED,
                    "invalid token",
                )
                    .into_response();
            }
        }
    }

    ws.on_upgrade(move |socket| handle_socket(state, role, session, socket))
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
        let _ = voyager.send(Message::Close(None));
    }

    (axum::http::StatusCode::OK, "closed").into_response()
}

async fn handle_socket(state: AppState, role: Role, session_param: Option<String>, socket: WebSocket) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Determine session ID: use provided one or generate for Horizon
    let session_id = {
        let mut sessions = state.sessions.lock().await;
        let id = match (&role, session_param) {
            (Role::Horizon, None) => generate_session_id(&sessions),
            (_, Some(s)) => s,
            (Role::Voyager, None) => unreachable!(), // Already validated in ws_handler
        };

        let session = sessions.entry(id.clone()).or_insert_with(Session::new);
        match role {
            Role::Horizon => {
                if session.horizon.is_some() {
                    warn!(session_id = %id, "horizon replaced existing connection");
                }
                session.horizon = Some(tx.clone());
            }
            Role::Voyager => {
                session.voyagers.push(tx.clone());
            }
        }
        id
    };

    info!(session_id = %session_id, ?role, "client connected");

    // Send session_assigned message to Horizon
    if role == Role::Horizon {
        let assign_msg = serde_json::json!({
            "v": 1,
            "type": "session_assigned",
            "sessionId": session_id
        });
        if sender.send(Message::Text(assign_msg.to_string())).await.is_err() {
            warn!(session_id = %session_id, "failed to send session_assigned");
            cleanup_connection(state, role, &session_id, &tx).await;
            return;
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
        route_message(state.clone(), role, &session_id, msg, Some(tx.clone())).await;
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
) {
    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(session_id) else {
        return;
    };

    match role {
        Role::Horizon => {
            session.voyagers.retain(|tx| tx.send(msg.clone()).is_ok());
        }
        Role::Voyager => {
            if let Some(horizon) = session.horizon.as_ref() {
                if horizon.send(msg).is_err() {
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
            session.voyagers.retain(|voyager_tx| !voyager_tx.same_channel(tx));
        }
    }

    if session.horizon.is_none() && session.voyagers.is_empty() {
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
        "list" | "create" | "close" | "stdin" | "resize"
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

fn token_valid(state: &AppState, token: Option<&str>) -> bool {
    match state.token.as_deref() {
        Some(required) => token == Some(required),
        None => true,
    }
}
