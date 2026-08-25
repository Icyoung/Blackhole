use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use serde_json::{json, Value};

pub const VPN_SERVER_V4: Ipv4Addr = Ipv4Addr::new(10, 13, 37, 1);
const VPN_SUBNET_PREFIX: [u8; 3] = [10, 13, 37];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VpnTcpDeliveryMode {
    /// pf rdr on utun → 127.0.0.1:app_port. Primary bind stays 0.0.0.0 / 127.0.0.1.
    Rdr,
    /// Bind 10.13.37.1:app_port after rdr is removed. vpn_peer from listener identity.
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

pub fn host_info_json(host_name: &str, vpn_peer: bool, remote: SocketAddr) -> Value {
    json!({
        "type": "host_info",
        "hostName": host_name,
        "vpnPeer": vpn_peer,
        "remoteAddr": remote.to_string(),
    })
}

/// Secondary VPN websocket bind used for step-2 fallback.
///
/// `secondary_vpn_ws_addr` stays None when the primary bind is 0.0.0.0; fallback
/// still needs 10.13.37.1 so ConnectInfo can use listener identity.
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
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod delivery_harness {
    use super::*;
    use std::io::ErrorKind;
    use std::time::Duration;

    fn harness_enabled() -> bool {
        std::env::var("HORIZON_VPN_TCP_HARNESS").is_ok() || unsafe { libc::geteuid() } == 0
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn write_all_fd(fd: i32, buf: &[u8]) -> Result<(), String> {
        let mut offset = 0;
        while offset < buf.len() {
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
                    continue;
                }
                return Err(err.to_string());
            }
            offset += n as usize;
        }
        Ok(())
    }

    fn ipv4_checksum(header: &[u8]) -> u16 {
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

    fn ipv4_tcp_syn(src: Ipv4Addr, dst: Ipv4Addr, sport: u16, dport: u16) -> Vec<u8> {
        let mut ip = vec![
            0x45, 0x00, 0x00, 40, 0x00, 0x00, 0x00, 0x00, 64, 6, 0x00, 0x00,
        ];
        ip.extend_from_slice(&src.octets());
        ip.extend_from_slice(&dst.octets());
        let ip_sum = ipv4_checksum(&ip);
        ip[10..12].copy_from_slice(&ip_sum.to_be_bytes());

        let mut tcp = Vec::new();
        tcp.extend_from_slice(&sport.to_be_bytes());
        tcp.extend_from_slice(&dport.to_be_bytes());
        tcp.extend_from_slice(&1u32.to_be_bytes());
        tcp.extend_from_slice(&0u32.to_be_bytes());
        tcp.extend_from_slice(&[0x50, 0x02]);
        tcp.extend_from_slice(&65535u16.to_be_bytes());
        tcp.extend_from_slice(&0u16.to_be_bytes());
        tcp.extend_from_slice(&0u16.to_be_bytes());
        let tcp_sum = tcp_checksum(src, dst, &tcp);
        tcp[16..18].copy_from_slice(&tcp_sum.to_be_bytes());

        ip.extend_from_slice(&tcp);
        ip
    }

    #[cfg(target_os = "macos")]
    fn prepend_utun_af_inet(packet: &[u8]) -> Vec<u8> {
        let mut prefixed = Vec::with_capacity(4 + packet.len());
        prefixed.extend_from_slice(&(libc::AF_INET as u32).to_ne_bytes());
        prefixed.extend_from_slice(packet);
        prefixed
    }

    /// TCP SYN through helper/utun to 10.13.37.1:lanPort. Skips without privileges.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn macos_utun_tcp_syn_records_remote_addr() {
        if !harness_enabled() {
            eprintln!(
                "measured remote_addr: skipped (set HORIZON_VPN_TCP_HARNESS=1 to send TCP SYN through utun)"
            );
            return;
        }

        let listener = tokio::net::TcpListener::bind("0.0.0.0:0")
            .await
            .expect("bind harness listener");
        let local = listener.local_addr().expect("listener local_addr");
        let tun = match crate::tun_device::create_tun(None) {
            Ok(tun) => tun,
            Err(err) => {
                eprintln!("measured remote_addr: skipped (create_tun failed: {err})");
                return;
            }
        };
        if let Err(err) =
            crate::tun_device::configure_tun(&tun, &VPN_SERVER_V4.to_string(), "255.255.255.0")
        {
            eprintln!("measured remote_addr: skipped (configure_tun failed: {err})");
            return;
        }

        let syn = ipv4_tcp_syn(
            Ipv4Addr::new(10, 13, 37, 2),
            VPN_SERVER_V4,
            40000,
            local.port(),
        );
        let framed = prepend_utun_af_inet(&syn);
        if let Err(err) = write_all_fd(tun.fd, &framed) {
            eprintln!("measured remote_addr: skipped (utun write failed: {err})");
            return;
        }

        match tokio::time::timeout(Duration::from_secs(2), listener.accept()).await {
            Ok(Ok((stream, remote))) => {
                let local_addr = stream.local_addr().ok();
                eprintln!(
                    "measured remote_addr={remote} local_addr={local_addr:?} vpn_peer={}",
                    classify_vpn_peer(remote, local_addr.unwrap_or(local))
                );
            }
            Ok(Err(err)) => panic!("harness accept failed: {err}"),
            Err(_) => {
                eprintln!(
                    "measured remote_addr: no accept within timeout (rdr may be required; explicit-bind fallback is the step-2 path)"
                );
            }
        }
    }

    /// Linux kernel delivery of in-tunnel TCP; no pf. Skips without privileges.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn linux_kernel_tcp_delivery_records_remote_addr() {
        if !harness_enabled() {
            eprintln!(
                "measured remote_addr: skipped (set HORIZON_VPN_TCP_HARNESS=1 for kernel TUN delivery)"
            );
            return;
        }

        let listener = tokio::net::TcpListener::bind("0.0.0.0:0")
            .await
            .expect("bind harness listener");
        let local = listener.local_addr().expect("listener local_addr");
        let tun = match crate::tun_device::create_tun(None) {
            Ok(tun) => tun,
            Err(err) => {
                eprintln!("measured remote_addr: skipped (create_tun failed: {err})");
                return;
            }
        };
        if let Err(err) =
            crate::tun_device::configure_tun(&tun, &VPN_SERVER_V4.to_string(), "255.255.255.0")
        {
            eprintln!("measured remote_addr: skipped (configure_tun failed: {err})");
            return;
        }

        let syn = ipv4_tcp_syn(
            Ipv4Addr::new(10, 13, 37, 2),
            VPN_SERVER_V4,
            40000,
            local.port(),
        );
        if let Err(err) = write_all_fd(tun.fd, &syn) {
            eprintln!("measured remote_addr: skipped (tun write failed: {err})");
            return;
        }

        match tokio::time::timeout(Duration::from_secs(2), listener.accept()).await {
            Ok(Ok((stream, remote))) => {
                let local_addr = stream.local_addr().ok();
                eprintln!(
                    "measured remote_addr={remote} local_addr={local_addr:?} vpn_peer={}",
                    classify_vpn_peer(remote, local_addr.unwrap_or(local))
                );
            }
            Ok(Err(err)) => panic!("harness accept failed: {err}"),
            Err(_) => {
                eprintln!("measured remote_addr: no accept within timeout");
            }
        }
    }
}
