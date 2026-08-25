use std::net::IpAddr;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::{
    best_direct_endpoint, classify_nat_mapping_behavior, compute_direct_reachability_score,
    configured_wg_netcheck_endpoint, current_horizon_direct_candidates, encode_json,
    hairpin_likely, merge_direct_candidates, observed_direct_candidate, parse_direct_candidates,
    record_observed_direct_candidate, AppState, DirectCandidate, WgPeerCommand,
};

/// JSON object to encode and send on the socket that delivered the control message.
pub(crate) type VpnReply = mpsc::UnboundedSender<Value>;

const ENDPOINT_REGISTER_FAST_RETRY: Duration = Duration::from_millis(500);
const ENDPOINT_REGISTER_FAST_WINDOW: Duration = Duration::from_secs(10);
const ENDPOINT_REGISTER_SLOW_RETRY: Duration = Duration::from_secs(5);
const ENDPOINT_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

pub(crate) fn is_vpn_control_type(ty: &str) -> bool {
    matches!(
        ty,
        "peer_endpoint"
            | "direct_candidates_update"
            | "endpoint_request"
            | "endpoint_probe_request"
    )
}

pub(crate) fn record_upnp_udp_into(store: &mut Vec<DirectCandidate>, addr: &str, port: u16) {
    record_observed_direct_candidate(store, Some(addr), Some(port), "upnp");
}

pub(crate) async fn record_upnp_udp_endpoint(
    state: &Arc<AppState>,
    external_ip: IpAddr,
    wg_port: u16,
) {
    let mut store = state.wg_observed_endpoints.lock().await;
    record_upnp_udp_into(&mut store, &external_ip.to_string(), wg_port);
}

pub(crate) async fn handle_vpn_control(
    state: &Arc<AppState>,
    value: &Value,
    reply: VpnReply,
) -> bool {
    let Some(ty) = value.get("type").and_then(|v| v.as_str()) else {
        return false;
    };
    if !is_vpn_control_type(ty) {
        return false;
    }

    match ty {
        "peer_endpoint" | "direct_candidates_update" => {
            handle_peer_candidates(state, value, &reply).await;
        }
        "endpoint_request" | "endpoint_probe_request" => {
            handle_endpoint_request(state, value, &reply).await;
        }
        _ => {}
    }
    true
}

async fn handle_peer_candidates(state: &Arc<AppState>, value: &Value, reply: &VpnReply) {
    if let Some(epoch) = value.get("punchEpoch").and_then(|v| v.as_u64()) {
        let last = state.last_punch_epoch.fetch_max(epoch, Ordering::SeqCst);
        if epoch < last {
            info!(
                punch_epoch = epoch,
                last_punch_epoch = last,
                "ignoring stale VPN candidate list"
            );
            return;
        }
    }

    let device_key = value.get("deviceKey").and_then(|v| v.as_str());
    let wg_pub = value.get("wgPublicKey").and_then(|v| v.as_str());
    let observed_addr = value.get("observedAddr").and_then(|v| v.as_str());
    let observed_port = value.get("observedPort").and_then(|v| v.as_u64());
    let voyager_candidates = merge_direct_candidates(
        parse_direct_candidates(value, "voyagerCandidates"),
        observed_direct_candidate(observed_addr, observed_port.map(|port| port as u16)),
    );
    info!(
        "peer endpoint received: device={:?} wg_pub={} addr={}:{} candidate_count={}",
        device_key,
        wg_pub.unwrap_or("none"),
        observed_addr.unwrap_or("?"),
        observed_port.unwrap_or(0),
        voyager_candidates.len(),
    );

    let Some(pub_key) = wg_pub else {
        return;
    };

    let endpoint = best_direct_endpoint(
        &voyager_candidates,
        observed_addr.and_then(|addr| {
            let port = observed_port.unwrap_or(0) as u16;
            format!("{addr}:{port}").parse().ok()
        }),
    );
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    let sent = {
        let tx = state.wg_peer_tx.lock().await;
        if let Some(tx) = tx.as_ref() {
            tx.send(WgPeerCommand::AddPeer {
                public_key: pub_key.to_string(),
                device_key: device_key.map(|s| s.to_string()),
                endpoint,
                candidate_endpoints: voyager_candidates
                    .iter()
                    .filter_map(|candidate| {
                        format!("{}:{}", candidate.addr, candidate.port)
                            .parse()
                            .ok()
                    })
                    .collect(),
                reply_tx,
            })
            .is_ok()
        } else {
            false
        }
    };
    if !sent {
        warn!(
            "peer_endpoint ignored because WG server channel is unavailable: device={:?} wg_pub={}",
            device_key, pub_key,
        );
        return;
    }

    match reply_rx.await {
        Ok(Ok(assignment)) => {
            let server_pub = state.wg_public_key.lock().await.clone();
            let wg_port = *state.wg_udp_port.lock().await;
            let internal_routes = state.wg_internal_routes.lock().await.clone();
            let (netcheck_host, netcheck_port) = configured_wg_netcheck_endpoint(state);
            let horizon_candidates = current_horizon_direct_candidates(state).await;
            let observed_endpoints = state.wg_observed_endpoints.lock().await.clone();
            let horizon_addr = state.wg_observed_addr.lock().await.clone();
            let nat_mapping_behavior = classify_nat_mapping_behavior(&observed_endpoints);
            let hairpin_likely = hairpin_likely(horizon_addr.as_deref(), &voyager_candidates);
            let direct_reachability_score = compute_direct_reachability_score(
                &horizon_candidates,
                &voyager_candidates,
                nat_mapping_behavior,
                hairpin_likely,
            );
            let response = json!({
                "type": "vpn_config",
                "clientIp": assignment.client_ip,
                "serverIp": assignment.server_ip,
                "subnet": assignment.subnet,
                "dns": assignment.dns,
                "internalRoutes": internal_routes,
                "mtu": assignment.mtu,
                "wgPublicKey": server_pub,
                "wgUdpPort": wg_port,
                "horizonAddr": horizon_addr,
                "netcheckHost": netcheck_host,
                "netcheckPort": netcheck_port,
                "horizonCandidates": horizon_candidates,
                "voyagerCandidates": voyager_candidates,
                "observedEndpoints": observed_endpoints,
                "natMappingBehavior": nat_mapping_behavior,
                "hairpinLikely": hairpin_likely,
                "directReachabilityScore": direct_reachability_score,
                "lanPort": state.port,
            });
            let _ = reply.send(response);
            info!(
                "vpn_config sent: device={:?} client_ip={} server_ip={} wg_port={:?}",
                device_key, assignment.client_ip, assignment.server_ip, wg_port,
            );
        }
        _ => {
            warn!(
                "peer_endpoint add_peer failed or channel dropped: device={:?} wg_pub={}",
                device_key, pub_key,
            );
        }
    }
}

async fn handle_endpoint_request(state: &Arc<AppState>, value: &Value, reply: &VpnReply) {
    let device_key = value.get("deviceKey").and_then(|v| v.as_str());
    let wg_pub = value.get("wgPublicKey").and_then(|v| v.as_str());
    let voyager_candidates = parse_direct_candidates(value, "voyagerCandidates");
    let response_type =
        if value.get("type").and_then(|v| v.as_str()) == Some("endpoint_probe_request") {
            "endpoint_probe_response"
        } else {
            "endpoint_info"
        };
    let server_pub = state.wg_public_key.lock().await.clone();
    let wg_port = *state.wg_udp_port.lock().await;
    let horizon_addr = state.wg_observed_addr.lock().await.clone();
    let (netcheck_host, netcheck_port) = configured_wg_netcheck_endpoint(state);
    let horizon_candidates = current_horizon_direct_candidates(state).await;
    let observed_endpoints = state.wg_observed_endpoints.lock().await.clone();
    let nat_mapping_behavior = classify_nat_mapping_behavior(&observed_endpoints);
    let hairpin_likely = hairpin_likely(horizon_addr.as_deref(), &voyager_candidates);
    let direct_reachability_score = compute_direct_reachability_score(
        &horizon_candidates,
        &voyager_candidates,
        nat_mapping_behavior,
        hairpin_likely,
    );
    let response = json!({
        "type": response_type,
        "wgPublicKey": server_pub,
        "wgUdpPort": wg_port,
        "netcheckHost": netcheck_host,
        "netcheckPort": netcheck_port,
        "horizonAddr": horizon_addr,
        "horizonPort": Value::Null,
        "horizonCandidates": horizon_candidates,
        "observedEndpoints": observed_endpoints,
        "natMappingBehavior": nat_mapping_behavior,
        "hairpinLikely": hairpin_likely,
        "directReachabilityScore": direct_reachability_score,
    });
    let _ = reply.send(response);
    info!(
        "direct endpoint_request received: device={:?} has_wg_pub={} horizon_addr={:?} wg_port={:?}",
        device_key,
        wg_pub.is_some(),
        horizon_addr,
        wg_port,
    );
}

fn horizon_endpoint_signature(
    wg_pub: &Option<String>,
    wg_port: Option<u16>,
    candidates: &[DirectCandidate],
) -> String {
    format!(
        "{}|{}|{}",
        wg_pub.as_deref().unwrap_or(""),
        wg_port.unwrap_or(0),
        serde_json::to_string(candidates).unwrap_or_default()
    )
}

/// No-ops until UDP 51820 is listening (`wg_peer_tx`). Returns true if
/// `endpoint_register` was sent or the candidate set was already published.
pub(crate) async fn publish_horizon_endpoint(state: &Arc<AppState>) -> bool {
    publish_horizon_endpoint_inner(state, false).await
}

async fn publish_horizon_endpoint_inner(state: &Arc<AppState>, force: bool) -> bool {
    if state.wg_peer_tx.lock().await.is_none() {
        return false;
    }

    let wg_pub = state.wg_public_key.lock().await.clone();
    let wg_port = *state.wg_udp_port.lock().await;
    let horizon_candidates = current_horizon_direct_candidates(state).await;
    let signature = horizon_endpoint_signature(&wg_pub, wg_port, &horizon_candidates);
    if !force {
        let last = state.last_endpoint_register_sig.lock().await;
        if last.as_ref() == Some(&signature) {
            return true;
        }
    }

    let sender = state.wormhole_sender.lock().await.clone();
    let Some(sender) = sender else {
        return false;
    };

    let payload = json!({
        "type": "endpoint_register",
        "wgPublicKey": wg_pub,
        "wgUdpPort": wg_port,
        "horizonCandidates": horizon_candidates,
    });
    if sender
        .send(tokio_tungstenite::tungstenite::Message::Text(encode_json(
            payload,
        )))
        .is_err()
    {
        return false;
    }
    *state.last_endpoint_register_sig.lock().await = Some(signature);
    true
}

pub(crate) async fn publish_horizon_endpoint_on_wormhole_connect(state: &Arc<AppState>) {
    if publish_horizon_endpoint_inner(state, true).await {
        return;
    }
    schedule_publish_horizon_endpoint(state.clone());
}

pub(crate) fn schedule_publish_horizon_endpoint(state: Arc<AppState>) {
    tokio::spawn(async move {
        if publish_horizon_endpoint(&state).await {
            return;
        }
        if state.wg_peer_tx.lock().await.is_none() {
            return;
        }
        if state
            .endpoint_register_retrying
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        let start = Instant::now();
        loop {
            if publish_horizon_endpoint(&state).await {
                break;
            }
            if state.wg_peer_tx.lock().await.is_none() {
                break;
            }
            let delay = if start.elapsed() < ENDPOINT_REGISTER_FAST_WINDOW {
                ENDPOINT_REGISTER_FAST_RETRY
            } else {
                ENDPOINT_REGISTER_SLOW_RETRY
            };
            tokio::time::sleep(delay).await;
        }
        state
            .endpoint_register_retrying
            .store(false, Ordering::SeqCst);
    });
}

pub(crate) fn spawn_horizon_endpoint_refresh_timer(state: Arc<AppState>) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(ENDPOINT_REFRESH_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let _ = publish_horizon_endpoint(&state).await;
        }
    });
}

pub(crate) fn spawn_upnp_udp_candidate_task(state: Arc<AppState>, wg_port: u16) {
    tokio::spawn(async move {
        let mut first = true;
        loop {
            match crate::upnp::add_port_mapping(wg_port).await {
                Ok(external) => {
                    if first {
                        info!("UPnP: external UDP endpoint {external}");
                    } else {
                        info!("UPnP renewal OK: external={external}:{wg_port}");
                    }
                    record_upnp_udp_endpoint(&state, external, wg_port).await;
                    schedule_publish_horizon_endpoint(state.clone());
                }
                Err(e) => {
                    if first {
                        warn!("UPnP: {e} (external clients may need manual port forwarding)");
                    } else {
                        warn!("UPnP renewal failed: {e}");
                    }
                }
            }
            first = false;
            tokio::time::sleep(Duration::from_secs(crate::upnp::RENEW_INTERVAL_SECS)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
    use std::sync::Arc;

    use serde_json::json;
    use tokio::sync::{broadcast, mpsc, Mutex};

    use crate::{BroadcastMsg, WgPeerCommand, WormholeState};

    fn test_state() -> Arc<AppState> {
        let (lan_tx, _) = broadcast::channel::<BroadcastMsg>(8);
        let (wormhole_tx, _) = broadcast::channel::<BroadcastMsg>(8);
        Arc::new(AppState {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            inject_tasks: Mutex::new(HashMap::new()),
            lan_broadcast: lan_tx,
            wormhole_broadcast: wormhole_tx,
            config_id: None,
            host_name: "test-host".to_string(),
            shell: "/bin/sh".to_string(),
            dev_mode: true,
            bind: IpAddr::V4(Ipv4Addr::LOCALHOST),
            ws_bind_addrs: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            port: 9527,
            wormhole_url: None,
            wormhole_token: None,
            wormhole_requested_session: None,
            wormhole_has_token: false,
            lan_client_count: AtomicUsize::new(0),
            wormhole_subscriber_count: AtomicUsize::new(0),
            wormhole_state: Mutex::new(WormholeState::default()),
            data_dir: std::env::temp_dir(),
            paired_devices: Mutex::new(Vec::new()),
            pending_pairing: Mutex::new(None),
            wormhole_sender: Mutex::new(None),
            groups: Mutex::new(Vec::new()),
            session_names: Mutex::new(HashMap::new()),
            wg_public_key: Mutex::new(Some("server-pub".to_string())),
            wg_udp_port: Mutex::new(Some(51820)),
            wg_observed_addr: Mutex::new(None),
            wg_observed_endpoints: Mutex::new(Vec::new()),
            wg_internal_routes: Mutex::new(vec!["192.168.1.0/24".to_string()]),
            wg_peer_tx: Mutex::new(None),
            last_punch_epoch: AtomicU64::new(0),
            last_endpoint_register_sig: Mutex::new(None),
            endpoint_register_retrying: AtomicBool::new(false),
        })
    }

    fn spawn_add_peer_responder() -> mpsc::UnboundedSender<WgPeerCommand> {
        let (tx, mut rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(cmd) = rx.recv().await {
                match cmd {
                    WgPeerCommand::AddPeer { reply_tx, .. } => {
                        let _ = reply_tx.send(Ok(crate::wg_server::VpnAssignment {
                            client_ip: "10.13.37.2".to_string(),
                            server_ip: "10.13.37.1".to_string(),
                            subnet: "10.13.37.0/24".to_string(),
                            dns: vec!["10.13.37.1".to_string()],
                            mtu: 1420,
                        }));
                    }
                }
            }
        });
        tx
    }

    async fn recv_reply(rx: &mut mpsc::UnboundedReceiver<Value>) -> Value {
        tokio::time::timeout(Duration::from_secs(1), rx.recv())
            .await
            .expect("timed out waiting for vpn reply")
            .expect("reply channel closed")
    }

    fn candidate_update(ty: &str) -> Value {
        json!({
            "v": 1,
            "type": ty,
            "deviceKey": "dev1",
            "wgPublicKey": "peer-pub",
            "voyagerCandidates": [{
                "addr": "192.168.1.20",
                "port": 51820,
                "scope": "lan",
                "priority": 250,
                "source": "peer"
            }]
        })
    }

    #[test]
    fn lan_accepts_direct_candidates_update_and_peer_endpoint() {
        assert!(is_vpn_control_type("direct_candidates_update"));
        assert!(is_vpn_control_type("peer_endpoint"));
        assert!(!is_vpn_control_type("list"));
        assert!(!is_vpn_control_type("session_created"));
    }

    #[test]
    fn upnp_udp_candidate_is_public_observed() {
        let mut store = Vec::new();
        record_upnp_udp_into(&mut store, "8.8.8.8", 51820);
        assert_eq!(store.len(), 1);
        assert_eq!(store[0].addr, "8.8.8.8");
        assert_eq!(store[0].port, 51820);
        assert_eq!(store[0].scope, "public_observed");
        assert_eq!(store[0].source, "upnp");
        assert_eq!(store[0].priority, 180);
    }

    #[test]
    fn netcheck_different_port_demotes_upnp_to_last_known() {
        let mut store = Vec::new();
        record_upnp_udp_into(&mut store, "8.8.8.8", 51820);
        record_observed_direct_candidate(&mut store, Some("8.8.8.8"), Some(12345), "netcheck");
        assert_eq!(store.len(), 2);
        assert_eq!(store[0].scope, "public_observed");
        assert_eq!(store[0].port, 12345);
        assert_eq!(store[0].source, "netcheck");
        assert_eq!(store[1].scope, "last_known");
        assert_eq!(store[1].port, 51820);
        assert_eq!(store[1].source, "upnp");
    }

    #[tokio::test]
    async fn handle_vpn_control_sends_vpn_config_for_candidate_updates() {
        for ty in ["direct_candidates_update", "peer_endpoint"] {
            let state = test_state();
            let peer_tx = spawn_add_peer_responder();
            *state.wg_peer_tx.lock().await = Some(peer_tx);

            let (reply_tx, mut reply_rx) = mpsc::unbounded_channel();
            assert!(
                handle_vpn_control(&state, &candidate_update(ty), reply_tx).await,
                "{ty} should be handled on LAN and WAN"
            );
            let reply = recv_reply(&mut reply_rx).await;
            assert_eq!(
                reply.get("type").and_then(|v| v.as_str()),
                Some("vpn_config")
            );
            assert_eq!(
                reply.get("clientIp").and_then(|v| v.as_str()),
                Some("10.13.37.2")
            );
            assert_eq!(reply.get("lanPort").and_then(|v| v.as_u64()), Some(9527));
            assert!(reply_rx.try_recv().is_err());
        }
    }

    #[tokio::test]
    async fn handle_vpn_control_ignores_stale_punch_epoch() {
        let state = test_state();
        let peer_tx = spawn_add_peer_responder();
        *state.wg_peer_tx.lock().await = Some(peer_tx);
        state.last_punch_epoch.store(5, Ordering::SeqCst);

        let mut value = candidate_update("direct_candidates_update");
        value["punchEpoch"] = json!(4);
        let (reply_tx, mut reply_rx) = mpsc::unbounded_channel();
        assert!(handle_vpn_control(&state, &value, reply_tx).await);
        assert!(
            tokio::time::timeout(Duration::from_millis(150), reply_rx.recv())
                .await
                .ok()
                .flatten()
                .is_none(),
            "stale punch_epoch must not emit vpn_config"
        );
    }

    #[tokio::test]
    async fn publish_horizon_endpoint_noop_without_wg_peer_tx() {
        let state = test_state();
        let (wh_tx, mut wh_rx) = mpsc::unbounded_channel();
        *state.wormhole_sender.lock().await = Some(wh_tx);

        assert!(!publish_horizon_endpoint(&state).await);
        assert!(
            wh_rx.try_recv().is_err(),
            "must not register before UDP 51820 is listening"
        );
    }

    #[tokio::test]
    async fn publish_horizon_endpoint_sends_when_peer_tx_and_wormhole_are_live() {
        let state = test_state();
        let (peer_tx, _peer_rx) = mpsc::unbounded_channel::<WgPeerCommand>();
        *state.wg_peer_tx.lock().await = Some(peer_tx);
        let (wh_tx, mut wh_rx) = mpsc::unbounded_channel();
        *state.wormhole_sender.lock().await = Some(wh_tx);

        assert!(publish_horizon_endpoint(&state).await);
        let msg = tokio::time::timeout(Duration::from_secs(1), wh_rx.recv())
            .await
            .expect("timed out waiting for endpoint_register")
            .expect("wormhole sender closed");
        let tokio_tungstenite::tungstenite::Message::Text(text) = msg else {
            panic!("expected text endpoint_register");
        };
        let value: Value = serde_json::from_str(&text).expect("endpoint_register json");
        assert_eq!(
            value.get("type").and_then(|v| v.as_str()),
            Some("endpoint_register")
        );
        assert_eq!(
            value.get("wgPublicKey").and_then(|v| v.as_str()),
            Some("server-pub")
        );
        assert_eq!(value.get("wgUdpPort").and_then(|v| v.as_u64()), Some(51820));
        assert_eq!(value.get("v").and_then(|v| v.as_i64()), Some(1));
    }
}
