use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::Arc;
use std::time::Instant;

use tokio::net::UdpSocket;
use tracing::{debug, info, warn};

/// Minimum size of a valid DNS message (header only).
const DNS_HEADER_SIZE: usize = 12;

/// How long to keep a query-ID mapping before considering it stale.
const QUERY_TTL_SECS: u64 = 10;

/// Monotonic counter for remapping DNS query IDs to prevent collisions
/// between different clients that may use the same query ID.
static NEXT_QID: AtomicU16 = AtomicU16::new(1);

/// Entry tracking which client sent a particular DNS query.
struct PendingQuery {
    client_addr: SocketAddr,
    original_qid: u16,
    timestamp: Instant,
}

/// Extract the 16-bit query ID from the first two bytes of a DNS message.
fn dns_query_id(buf: &[u8]) -> Option<u16> {
    if buf.len() < DNS_HEADER_SIZE {
        return None;
    }
    Some(u16::from_be_bytes([buf[0], buf[1]]))
}

/// Rewrite the query ID in the first two bytes of a DNS message.
fn set_dns_query_id(buf: &mut [u8], qid: u16) {
    if buf.len() >= 2 {
        let bytes = qid.to_be_bytes();
        buf[0] = bytes[0];
        buf[1] = bytes[1];
    }
}

/// Run a simple DNS forwarder that listens on `listen_addr` (e.g., "10.13.37.1:53")
/// and forwards queries to `upstream` (e.g., the system's DNS resolver).
///
/// Each incoming query is tracked by its DNS query ID so that the upstream response
/// can be routed back to the correct client. Stale mappings are cleaned up
/// periodically (entries older than 10 seconds).
pub async fn run_dns_forwarder(
    listen_addr: SocketAddr,
    upstream: SocketAddr,
) -> Result<(), String> {
    run_dns_forwarder_until(listen_addr, upstream, None).await
}

pub async fn run_dns_forwarder_until(
    listen_addr: SocketAddr,
    upstream: SocketAddr,
    shutdown: Option<Arc<AtomicBool>>,
) -> Result<(), String> {
    let socket = UdpSocket::bind(listen_addr)
        .await
        .map_err(|e| format!("dns bind failed on {}: {}", listen_addr, e))?;

    info!(
        "DNS forwarder listening on {}, upstream {}",
        listen_addr, upstream
    );

    let upstream_socket = UdpSocket::bind("0.0.0.0:0")
        .await
        .map_err(|e| format!("dns upstream socket failed: {}", e))?;

    let mut buf = vec![0u8; 4096];
    let mut upstream_buf = vec![0u8; 4096];

    // Map remapped-query-ID -> original (client_addr, original_qid)
    let mut pending: HashMap<u16, PendingQuery> = HashMap::new();
    let mut cleanup_interval =
        tokio::time::interval(std::time::Duration::from_secs(QUERY_TTL_SECS));
    cleanup_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut shutdown_poll = tokio::time::interval(std::time::Duration::from_millis(200));
    shutdown_poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            // Receive query from a VPN client
            result = socket.recv_from(&mut buf) => {
                match result {
                    Ok((len, client_addr)) => {
                        if let Some(original_qid) = dns_query_id(&buf[..len]) {
                            // Remap query ID to avoid collisions between clients
                            let remapped_qid = NEXT_QID.fetch_add(1, Ordering::Relaxed);
                            debug!("DNS query id=0x{:04X} from {} -> remapped 0x{:04X}", original_qid, client_addr, remapped_qid);

                            pending.insert(remapped_qid, PendingQuery {
                                client_addr,
                                original_qid,
                                timestamp: Instant::now(),
                            });

                            // Rewrite the query ID before forwarding
                            set_dns_query_id(&mut buf[..len], remapped_qid);

                            if let Err(e) = upstream_socket.send_to(&buf[..len], upstream).await {
                                warn!("DNS forward to upstream failed: {}", e);
                            }
                        } else {
                            warn!("DNS packet from {} too short ({} bytes), ignoring", client_addr, len);
                        }
                    }
                    Err(e) => {
                        warn!("DNS recv error: {}", e);
                    }
                }
            }

            // Receive response from the upstream resolver
            result = upstream_socket.recv_from(&mut upstream_buf) => {
                match result {
                    Ok((len, _upstream_addr)) => {
                        if let Some(remapped_qid) = dns_query_id(&upstream_buf[..len]) {
                            if let Some(entry) = pending.remove(&remapped_qid) {
                                debug!(
                                    "DNS response id=0x{:04X} -> restoring 0x{:04X}, forwarding to {}",
                                    remapped_qid, entry.original_qid, entry.client_addr
                                );
                                // Restore the original query ID before sending back to client
                                set_dns_query_id(&mut upstream_buf[..len], entry.original_qid);

                                if let Err(e) = socket.send_to(&upstream_buf[..len], entry.client_addr).await {
                                    warn!("DNS reply to {} failed: {}", entry.client_addr, e);
                                }
                            } else {
                                debug!("DNS response id=0x{:04X} has no pending client (stale/duplicate), dropping", remapped_qid);
                            }
                        } else {
                            warn!("DNS upstream response too short ({} bytes), ignoring", len);
                        }
                    }
                    Err(e) => {
                        warn!("DNS upstream recv error: {}", e);
                    }
                }
            }

            // M-5: Periodic cleanup of stale pending queries via timer
            _ = cleanup_interval.tick() => {
                let before = pending.len();
                pending.retain(|_qid, entry| entry.timestamp.elapsed().as_secs() < QUERY_TTL_SECS);
                let removed = before - pending.len();
                if removed > 0 {
                    debug!("DNS forwarder: cleaned up {} stale pending queries", removed);
                }
            }

            _ = shutdown_poll.tick(), if shutdown.is_some() => {
                if shutdown
                    .as_ref()
                    .is_some_and(|flag| flag.load(Ordering::SeqCst))
                {
                    info!("DNS forwarder shutting down on {}", listen_addr);
                    return Ok(());
                }
            }
        }
    }
}

/// Detect the system's DNS resolver address.
///
/// - **macOS**: Parses `scutil --dns` output for `nameserver` entries; falls back to
///   `/etc/resolv.conf`.
/// - **Linux**: Parses `/etc/resolv.conf` for `nameserver` lines.
/// - **Fallback**: Returns `8.8.8.8:53` if nothing else works.
pub fn detect_system_dns() -> SocketAddr {
    // Try platform-specific detection first
    if let Some(addr) = platform_detect_dns() {
        return addr;
    }

    // Universal fallback: parse /etc/resolv.conf
    if let Some(addr) = parse_resolv_conf() {
        return addr;
    }

    // Last resort
    let fallback: SocketAddr = "8.8.8.8:53".parse().unwrap();
    warn!("could not detect system DNS, using fallback {}", fallback);
    fallback
}

/// Platform-specific DNS detection (macOS: scutil --dns).
#[cfg(target_os = "macos")]
fn platform_detect_dns() -> Option<SocketAddr> {
    use std::process::Command;

    let output = Command::new("scutil").arg("--dns").output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    for line in stdout.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("nameserver[") {
            // Lines look like: "nameserver[0] : 192.168.1.1"
            if let Some(addr_part) = rest.split(':').nth(1) {
                let addr_str = addr_part.trim();
                if let Ok(ip) = addr_str.parse::<std::net::IpAddr>() {
                    let sa = SocketAddr::new(ip, 53);
                    info!("detected system DNS from scutil: {}", sa);
                    return Some(sa);
                }
            }
        }
    }

    // Fall through to resolv.conf
    None
}

/// Platform-specific DNS detection (Linux: /etc/resolv.conf only).
#[cfg(target_os = "linux")]
fn platform_detect_dns() -> Option<SocketAddr> {
    // Linux relies on resolv.conf; no extra tool needed.
    None
}

/// Fallback for unsupported platforms.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_detect_dns() -> Option<SocketAddr> {
    None
}

/// Parse `/etc/resolv.conf` for the first `nameserver` entry.
fn parse_resolv_conf() -> Option<SocketAddr> {
    let contents = std::fs::read_to_string("/etc/resolv.conf").ok()?;
    for line in contents.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("nameserver") {
            let addr_str = rest.trim();
            if let Ok(ip) = addr_str.parse::<std::net::IpAddr>() {
                let sa = SocketAddr::new(ip, 53);
                info!("detected system DNS from /etc/resolv.conf: {}", sa);
                return Some(sa);
            }
        }
    }
    None
}
