use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use serde_json::{json, Value};

use crate::tun_device::TunTransport;

pub const VPN_SERVER_V4: Ipv4Addr = Ipv4Addr::new(10, 13, 37, 1);
/// Outside the WG assignment pool (`.2`–`.253`); never handed to a Voyager peer.
pub const VPN_PROBE_CLIENT_V4: Ipv4Addr = Ipv4Addr::new(10, 13, 37, 254);
pub const VPN_TCP_PROBE_PATH: &str = "/vpn-tcp-probe";
const VPN_SUBNET_PREFIX: [u8; 3] = [10, 13, 37];
const TCP_SYN: u8 = 0x02;
const TCP_ACK: u8 = 0x10;
const TCP_PSH: u8 = 0x08;
const TCP_RST: u8 = 0x04;
const MAX_TUN_IO_ATTEMPTS: u32 = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VpnTcpDeliveryMode {
    Rdr,
    ExplicitBind,
}

pub fn vpn_tcp_delivery_mode() -> VpnTcpDeliveryMode {
    match std::env::var("HORIZON_VPN_TCP_DELIVERY") {
        Ok(value) if value.eq_ignore_ascii_case("explicit-bind") => {
            VpnTcpDeliveryMode::ExplicitBind
        }
        _ => VpnTcpDeliveryMode::Rdr,
    }
}

pub fn uses_pf_rdr(mode: VpnTcpDeliveryMode) -> bool {
    matches!(mode, VpnTcpDeliveryMode::Rdr)
}

pub fn uses_explicit_bind(mode: VpnTcpDeliveryMode) -> bool {
    matches!(mode, VpnTcpDeliveryMode::ExplicitBind)
}

pub fn is_vpn_subnet_ip(ip: IpAddr) -> bool {
    matches!(ip, IpAddr::V4(v4) if v4.octets()[0..3] == VPN_SUBNET_PREFIX)
}

pub fn is_vpn_server_ip(ip: IpAddr) -> bool {
    ip == IpAddr::V4(VPN_SERVER_V4)
}

/// Prefer the 10.13.37.0/24 source check. Loopback ConnectInfo is not Direct
/// unless the socket was the explicit 10.13.37.1 listener.
pub fn classify_vpn_peer(remote: SocketAddr, local: SocketAddr) -> bool {
    classify_vpn_peer_ips(remote.ip(), local.ip())
}

pub fn classify_vpn_peer_ips(remote: IpAddr, local: IpAddr) -> bool {
    if is_vpn_subnet_ip(remote) {
        return true;
    }
    if remote.is_loopback() {
        return is_vpn_server_ip(local);
    }
    is_vpn_server_ip(local)
}

/// Fail over when the utun probe got no accept, or pf presented the source as loopback.
pub fn rdr_probe_requires_failover(remote: Option<SocketAddr>) -> bool {
    match remote {
        None => true,
        Some(addr) => addr.ip().is_loopback(),
    }
}

pub fn host_info_json(host_name: &str, vpn_peer: bool, remote: SocketAddr) -> Value {
    json!({
        "type": "host_info",
        "hostName": host_name,
        "vpnPeer": vpn_peer,
        "remoteAddr": remote.to_string(),
    })
}

pub fn vpn_ws_fallback_addr(
    primary_bind: IpAddr,
    port: u16,
    vpn_ws_bind: Option<IpAddr>,
    secondary: Option<SocketAddr>,
) -> Option<SocketAddr> {
    if let Some(addr) = secondary {
        return Some(addr);
    }
    let vpn_bind = vpn_ws_bind?;
    if vpn_bind == primary_bind {
        return None;
    }
    Some(SocketAddr::new(vpn_bind, port))
}

#[derive(Debug, Clone, Copy)]
pub struct TunTcpSession {
    pub src: Ipv4Addr,
    pub dst: Ipv4Addr,
    pub sport: u16,
    pub dport: u16,
    pub seq: u32,
    pub ack: u32,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub async fn tun_tcp_handshake(
    tun_fd: i32,
    transport: TunTransport,
    src: Ipv4Addr,
    dst: Ipv4Addr,
    sport: u16,
    dport: u16,
    timeout: Duration,
) -> Result<TunTcpSession, String> {
    let syn = ipv4_tcp_segment(src, dst, sport, dport, 1, 0, TCP_SYN, &[]);
    tun_write_all(tun_fd, transport, &syn, timeout).await?;

    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timed out waiting for TCP SYN-ACK via TUN".to_string());
        }
        let packet = match tun_read_ip(tun_fd, transport, remaining).await? {
            Some(packet) => packet,
            None => continue,
        };
        let Some(tcp) = parse_ipv4_tcp(&packet) else {
            continue;
        };
        if tcp.dport != sport || tcp.sport != dport {
            continue;
        }
        if (tcp.flags & (TCP_SYN | TCP_ACK)) != (TCP_SYN | TCP_ACK) {
            continue;
        }
        let session = TunTcpSession {
            src,
            dst,
            sport,
            dport,
            seq: 2,
            ack: tcp.seq.wrapping_add(1),
        };
        let ack = ipv4_tcp_segment(
            src,
            dst,
            sport,
            dport,
            session.seq,
            session.ack,
            TCP_ACK,
            &[],
        );
        tun_write_all(tun_fd, transport, &ack, remaining).await?;
        return Ok(session);
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub async fn tun_tcp_send(
    tun_fd: i32,
    transport: TunTransport,
    session: &mut TunTcpSession,
    payload: &[u8],
    timeout: Duration,
) -> Result<(), String> {
    let packet = ipv4_tcp_segment(
        session.src,
        session.dst,
        session.sport,
        session.dport,
        session.seq,
        session.ack,
        TCP_ACK | TCP_PSH,
        payload,
    );
    tun_write_all(tun_fd, transport, &packet, timeout).await?;
    session.seq = session.seq.wrapping_add(payload.len() as u32);
    Ok(())
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub async fn tun_tcp_rst(
    tun_fd: i32,
    transport: TunTransport,
    session: &TunTcpSession,
    timeout: Duration,
) -> Result<(), String> {
    let packet = ipv4_tcp_segment(
        session.src,
        session.dst,
        session.sport,
        session.dport,
        session.seq,
        session.ack,
        TCP_RST | TCP_ACK,
        &[],
    );
    tun_write_all(tun_fd, transport, &packet, timeout).await
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub async fn tun_drain(tun_fd: i32, transport: TunTransport, timeout: Duration) {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return;
        }
        match tun_read_ip(tun_fd, transport, remaining.min(Duration::from_millis(20))).await {
            Ok(Some(_)) | Ok(None) => continue,
            Err(_) => return,
        }
    }
}

pub fn vpn_probe_http_get(host: &str) -> Vec<u8> {
    format!("GET {VPN_TCP_PROBE_PATH} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
        .into_bytes()
}

fn ipv4_tcp_segment(
    src: Ipv4Addr,
    dst: Ipv4Addr,
    sport: u16,
    dport: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: &[u8],
) -> Vec<u8> {
    let total = 20 + 20 + payload.len();
    let mut ip = vec![0x45, 0x00];
    ip.extend_from_slice(&(total as u16).to_be_bytes());
    ip.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 64, 6, 0x00, 0x00]);
    ip.extend_from_slice(&src.octets());
    ip.extend_from_slice(&dst.octets());
    let ip_sum = internet_checksum(&ip);
    ip[10..12].copy_from_slice(&ip_sum.to_be_bytes());

    let mut tcp = Vec::new();
    tcp.extend_from_slice(&sport.to_be_bytes());
    tcp.extend_from_slice(&dport.to_be_bytes());
    tcp.extend_from_slice(&seq.to_be_bytes());
    tcp.extend_from_slice(&ack.to_be_bytes());
    tcp.extend_from_slice(&[0x50, flags]);
    tcp.extend_from_slice(&65535u16.to_be_bytes());
    tcp.extend_from_slice(&0u16.to_be_bytes());
    tcp.extend_from_slice(&0u16.to_be_bytes());
    tcp.extend_from_slice(payload);
    let tcp_sum = tcp_checksum(src, dst, &tcp);
    tcp[16..18].copy_from_slice(&tcp_sum.to_be_bytes());

    ip.extend_from_slice(&tcp);
    ip
}

struct ParsedTcp {
    sport: u16,
    dport: u16,
    seq: u32,
    flags: u8,
}

fn parse_ipv4_tcp(packet: &[u8]) -> Option<ParsedTcp> {
    if packet.len() < 40 {
        return None;
    }
    if packet[0] >> 4 != 4 {
        return None;
    }
    let ihl = ((packet[0] & 0x0f) as usize) * 4;
    if ihl < 20 || packet.len() < ihl + 20 {
        return None;
    }
    if packet[9] != 6 {
        return None;
    }
    let tcp = &packet[ihl..];
    Some(ParsedTcp {
        sport: u16::from_be_bytes([tcp[0], tcp[1]]),
        dport: u16::from_be_bytes([tcp[2], tcp[3]]),
        seq: u32::from_be_bytes([tcp[4], tcp[5], tcp[6], tcp[7]]),
        flags: tcp[13],
    })
}

fn internet_checksum(header: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for chunk in header.chunks(2) {
        let word = if chunk.len() == 2 {
            u16::from_be_bytes([chunk[0], chunk[1]])
        } else {
            u16::from_be_bytes([chunk[0], 0])
        };
        sum += u32::from(word);
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !sum as u16
}

fn tcp_checksum(src: Ipv4Addr, dst: Ipv4Addr, tcp: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut pseudo = Vec::from(src.octets());
    pseudo.extend_from_slice(&dst.octets());
    pseudo.extend_from_slice(&[0, 6]);
    pseudo.extend_from_slice(&(tcp.len() as u16).to_be_bytes());
    for chunk in pseudo.chunks(2).chain(tcp.chunks(2)) {
        let word = if chunk.len() == 2 {
            u16::from_be_bytes([chunk[0], chunk[1]])
        } else {
            u16::from_be_bytes([chunk[0], 0])
        };
        sum += u32::from(word);
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !sum as u16
}

fn frame_outbound(transport: TunTransport, ip: &[u8]) -> Vec<u8> {
    #[cfg(target_os = "macos")]
    if transport == TunTransport::NativeTun {
        let mut prefixed = Vec::with_capacity(4 + ip.len());
        prefixed.extend_from_slice(&(libc::AF_INET as u32).to_ne_bytes());
        prefixed.extend_from_slice(ip);
        return prefixed;
    }
    let _ = transport;
    ip.to_vec()
}

fn frame_inbound<'a>(transport: TunTransport, buf: &'a [u8]) -> Option<&'a [u8]> {
    #[cfg(target_os = "macos")]
    if transport == TunTransport::NativeTun {
        if buf.len() <= 4 {
            return None;
        }
        return Some(&buf[4..]);
    }
    let _ = transport;
    Some(buf)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn write_fd_all_bounded(fd: i32, buf: &[u8]) -> Result<bool, String> {
    let mut offset = 0;
    let mut attempts = 0;
    while offset < buf.len() {
        attempts += 1;
        if attempts > MAX_TUN_IO_ATTEMPTS {
            return Err("tun write exceeded retry bound".to_string());
        }
        let n = unsafe {
            libc::write(
                fd,
                buf[offset..].as_ptr() as *const libc::c_void,
                buf.len() - offset,
            )
        };
        if n < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == ErrorKind::WouldBlock || err.kind() == ErrorKind::Interrupted {
                return Ok(false);
            }
            return Err(err.to_string());
        }
        if n == 0 {
            return Err("tun write returned 0".to_string());
        }
        offset += n as usize;
    }
    Ok(true)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
async fn tun_write_all(
    tun_fd: i32,
    transport: TunTransport,
    ip: &[u8],
    timeout: Duration,
) -> Result<(), String> {
    let framed = frame_outbound(transport, ip);
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        match write_fd_all_bounded(tun_fd, &framed)? {
            true => return Ok(()),
            false => {
                if tokio::time::Instant::now() >= deadline {
                    return Err("tun write timed out".to_string());
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
async fn tun_read_ip(
    tun_fd: i32,
    transport: TunTransport,
    timeout: Duration,
) -> Result<Option<Vec<u8>>, String> {
    let deadline = tokio::time::Instant::now() + timeout;
    let mut buf = [0u8; 4096];
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err("tun read timed out".to_string());
        }
        let n = unsafe { libc::read(tun_fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == ErrorKind::WouldBlock || err.kind() == ErrorKind::Interrupted {
                tokio::time::sleep(Duration::from_millis(5)).await;
                continue;
            }
            return Err(err.to_string());
        }
        if n == 0 {
            return Ok(None);
        }
        return Ok(frame_inbound(transport, &buf[..n as usize]).map(|p| p.to_vec()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddrV4;

    fn addr(ip: [u8; 4], port: u16) -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::new(ip[0], ip[1], ip[2], ip[3]),
            port,
        ))
    }

    #[test]
    fn rdr_and_explicit_bind_are_mutually_exclusive() {
        assert!(uses_pf_rdr(VpnTcpDeliveryMode::Rdr));
        assert!(!uses_explicit_bind(VpnTcpDeliveryMode::Rdr));
        assert!(!uses_pf_rdr(VpnTcpDeliveryMode::ExplicitBind));
        assert!(uses_explicit_bind(VpnTcpDeliveryMode::ExplicitBind));
    }

    #[test]
    fn classify_vpn_peer_prefers_slash24_source() {
        let remote = addr([10, 13, 37, 2], 50000);
        let local_loopback = addr([127, 0, 0, 1], 9527);
        let local_wildcard = addr([0, 0, 0, 0], 9527);
        assert!(classify_vpn_peer(remote, local_loopback));
        assert!(classify_vpn_peer(remote, local_wildcard));
    }

    #[test]
    fn classify_vpn_peer_loopback_is_not_direct_on_primary() {
        let remote = addr([127, 0, 0, 1], 50000);
        let local = addr([127, 0, 0, 1], 9527);
        assert!(!classify_vpn_peer(remote, local));
    }

    #[test]
    fn classify_vpn_peer_uses_listener_identity_on_explicit_bind() {
        let remote = addr([127, 0, 0, 1], 50000);
        let local = addr([10, 13, 37, 1], 9527);
        assert!(classify_vpn_peer(remote, local));

        let remote_lan = addr([192, 168, 1, 20], 50000);
        assert!(classify_vpn_peer(remote_lan, local));
    }

    #[test]
    fn classify_vpn_peer_physical_nic_is_not_direct() {
        let remote = addr([192, 168, 1, 20], 50000);
        let local = addr([192, 168, 1, 10], 9527);
        assert!(!classify_vpn_peer(remote, local));
    }

    #[test]
    fn failover_when_probe_has_no_accept() {
        assert!(rdr_probe_requires_failover(None));
    }

    #[test]
    fn failover_when_probe_accept_source_is_loopback() {
        assert!(rdr_probe_requires_failover(Some(addr(
            [127, 0, 0, 1],
            50000
        ))));
    }

    #[test]
    fn no_failover_when_probe_accept_is_slash24() {
        assert!(!rdr_probe_requires_failover(Some(addr(
            [10, 13, 37, 2],
            50000
        ))));
    }

    #[test]
    fn measured_in_tunnel_accept_sets_host_info_vpn_peer_true() {
        let remote = addr([10, 13, 37, 7], 54012);
        let local = addr([10, 13, 37, 1], 9527);
        let vpn_peer = classify_vpn_peer(remote, local);
        assert!(vpn_peer);
        let payload = host_info_json("Horizon", vpn_peer, remote);
        assert_eq!(payload["vpnPeer"], true);
        assert_eq!(payload["remoteAddr"], "10.13.37.7:54012");
    }

    #[test]
    fn host_info_includes_vpn_peer_and_remote_addr() {
        let payload = host_info_json("Horizon", true, addr([10, 13, 37, 2], 4242));
        assert_eq!(payload["type"], "host_info");
        assert_eq!(payload["hostName"], "Horizon");
        assert_eq!(payload["vpnPeer"], true);
        assert_eq!(payload["remoteAddr"], "10.13.37.2:4242");

        let nic = host_info_json("Horizon", false, addr([192, 168, 1, 20], 9));
        assert_eq!(nic["vpnPeer"], false);
        assert_eq!(nic["remoteAddr"], "192.168.1.20:9");
    }

    #[test]
    fn fallback_addr_forces_vpn_ip_when_primary_is_unspecified() {
        let primary = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
        let vpn = IpAddr::V4(VPN_SERVER_V4);
        assert_eq!(
            vpn_ws_fallback_addr(primary, 9527, Some(vpn), None),
            Some(SocketAddr::new(vpn, 9527))
        );
        assert_eq!(
            vpn_ws_fallback_addr(
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                9527,
                Some(vpn),
                Some(SocketAddr::new(vpn, 9527)),
            ),
            Some(SocketAddr::new(vpn, 9527))
        );
    }

    #[test]
    fn probe_client_is_outside_wg_assignment_pool() {
        assert_eq!(VPN_PROBE_CLIENT_V4.octets()[3], 254);
        assert_ne!(VPN_PROBE_CLIENT_V4, Ipv4Addr::new(10, 13, 37, 2));
    }

    #[test]
    fn probe_http_targets_dedicated_route() {
        let req = vpn_probe_http_get("10.13.37.1");
        let text = String::from_utf8(req).unwrap();
        assert!(text.starts_with("GET /vpn-tcp-probe HTTP/1.1"));
        assert!(!text.contains("/health"));
        assert!(!text.contains("/ws"));
    }

    #[test]
    fn parse_ipv4_tcp_reads_syn_ack_ports() {
        let packet = ipv4_tcp_segment(
            VPN_SERVER_V4,
            VPN_PROBE_CLIENT_V4,
            9527,
            49152,
            99,
            2,
            TCP_SYN | TCP_ACK,
            &[],
        );
        let parsed = parse_ipv4_tcp(&packet).expect("tcp");
        assert_eq!(parsed.sport, 9527);
        assert_eq!(parsed.dport, 49152);
        assert_eq!(parsed.seq, 99);
        assert_eq!(parsed.flags & (TCP_SYN | TCP_ACK), TCP_SYN | TCP_ACK);
    }
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod delivery_harness {
    use super::*;
    use crate::tun_device::TunTransport;

    fn harness_enabled() -> bool {
        std::env::var("HORIZON_VPN_TCP_HARNESS").is_ok()
    }

    fn harness_fail(reason: impl std::fmt::Display) -> ! {
        panic!("HORIZON_VPN_TCP_HARNESS=1 but in-tunnel TCP probe failed: {reason}");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn macos_utun_tcp_handshake_records_remote_addr() {
        if !harness_enabled() {
            eprintln!(
                "measured remote_addr: skipped (set HORIZON_VPN_TCP_HARNESS=1 to handshake TCP through utun)"
            );
            return;
        }
        record_measured_remote_addr(TunTransport::NativeTun, true).await;
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn linux_kernel_tcp_delivery_records_remote_addr() {
        if !harness_enabled() {
            eprintln!(
                "measured remote_addr: skipped (set HORIZON_VPN_TCP_HARNESS=1 for kernel TUN delivery)"
            );
            return;
        }
        record_measured_remote_addr(TunTransport::NativeTun, false).await;
    }

    async fn record_measured_remote_addr(transport: TunTransport, install_rdr: bool) {
        let listener = tokio::net::TcpListener::bind("0.0.0.0:0")
            .await
            .unwrap_or_else(|err| harness_fail(format!("bind harness listener: {err}")));
        let local = listener
            .local_addr()
            .unwrap_or_else(|err| harness_fail(format!("listener local_addr: {err}")));
        let tun = crate::tun_device::create_tun(None)
            .unwrap_or_else(|err| harness_fail(format!("create_tun: {err}")));
        crate::tun_device::configure_tun(&tun, &VPN_SERVER_V4.to_string(), "255.255.255.0")
            .unwrap_or_else(|err| harness_fail(format!("configure_tun: {err}")));

        if install_rdr {
            if let Err(err) = crate::nat::setup_nat(
                "10.13.37.0/24",
                None,
                Some((
                    &VPN_SERVER_V4.to_string(),
                    local.port(),
                    Some(tun.name.as_str()),
                )),
            ) {
                eprintln!("harness rdr install failed (continuing with kernel delivery): {err}");
            }
        }

        let accept = tokio::spawn(async move {
            tokio::time::timeout(Duration::from_secs(3), listener.accept()).await
        });
        let handshake = tun_tcp_handshake(
            tun.fd,
            transport,
            VPN_PROBE_CLIENT_V4,
            VPN_SERVER_V4,
            49152,
            local.port(),
            Duration::from_secs(2),
        )
        .await;
        let session = match handshake {
            Ok(session) => session,
            Err(err) => {
                let _ = accept.await;
                harness_fail(format!("handshake: {err}"));
            }
        };

        match accept.await {
            Ok(Ok(Ok((stream, remote)))) => {
                let local_addr = stream.local_addr().ok();
                eprintln!(
                    "measured remote_addr={remote} local_addr={local_addr:?} vpn_peer={}",
                    classify_vpn_peer(remote, local_addr.unwrap_or(local))
                );
                if remote.to_string().is_empty() {
                    harness_fail("accept succeeded without remote_addr");
                }
            }
            Ok(Ok(Err(err))) => harness_fail(format!("accept: {err}")),
            Ok(Err(_)) => harness_fail("no accept within timeout"),
            Err(err) => harness_fail(format!("join accept task: {err}")),
        }

        let _ = tun_tcp_rst(tun.fd, transport, &session, Duration::from_millis(200)).await;
        tun_drain(tun.fd, transport, Duration::from_millis(100)).await;

        if install_rdr {
            let _ = crate::nat::teardown_nat();
        }
    }
}
