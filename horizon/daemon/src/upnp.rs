//! UPnP IGD port mapping for WireGuard UDP.
//!
//! Automatically maps the WG UDP port on the gateway router so that
//! external clients (e.g. Voyager on 5G) can reach Horizon's WG server.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tracing::{info, warn};

/// Duration of the UPnP lease in seconds.
const LEASE_DURATION_SECS: u32 = 3600;
/// How often to renew the mapping.
const RENEW_INTERVAL_SECS: u64 = 2700;

/// Try to add a UPnP port mapping for the given port and protocol.
/// Returns the external IP if successful.
pub async fn add_port_mapping_proto(
    local_port: u16,
    protocol: igd_next::PortMappingProtocol,
    description: &str,
) -> Result<IpAddr, String> {
    let gateway = igd_next::aio::tokio::search_gateway(Default::default())
        .await
        .map_err(|e| format!("UPnP gateway discovery failed: {e}"))?;

    info!("UPnP gateway found: {}", gateway.addr);

    let external_ip = gateway
        .get_external_ip()
        .await
        .map_err(|e| format!("UPnP get_external_ip failed: {e}"))?;

    let local_ip = get_local_ip_for_gateway(&gateway.addr)?;
    let local_addr = SocketAddr::new(IpAddr::V4(local_ip), local_port);

    gateway
        .add_port(
            protocol,
            local_port,
            local_addr,
            LEASE_DURATION_SECS,
            description,
        )
        .await
        .map_err(|e| format!("UPnP add_port failed: {e}"))?;

    let proto_str = match protocol {
        igd_next::PortMappingProtocol::UDP => "UDP",
        igd_next::PortMappingProtocol::TCP => "TCP",
    };
    info!(
        "UPnP mapped external {}:{}/{} -> {}:{} (lease {}s)",
        external_ip, local_port, proto_str, local_ip, local_port, LEASE_DURATION_SECS
    );

    Ok(external_ip)
}

/// Convenience: map UDP port.
pub async fn add_port_mapping(local_port: u16) -> Result<IpAddr, String> {
    add_port_mapping_proto(local_port, igd_next::PortMappingProtocol::UDP, "Blackhole WireGuard").await
}

/// Convenience: map TCP port.
pub async fn add_tcp_port_mapping(local_port: u16) -> Result<IpAddr, String> {
    add_port_mapping_proto(local_port, igd_next::PortMappingProtocol::TCP, "Blackhole Horizon WebSocket").await
}

/// Remove a previously added UPnP port mapping.
pub async fn remove_port_mapping(port: u16) {
    match igd_next::aio::tokio::search_gateway(Default::default()).await {
        Ok(gateway) => {
            match gateway
                .remove_port(igd_next::PortMappingProtocol::UDP, port)
                .await
            {
                Ok(()) => info!("UPnP removed UDP port mapping {}", port),
                Err(e) => warn!("UPnP remove_port failed: {e}"),
            }
        }
        Err(e) => warn!("UPnP gateway not found for cleanup: {e}"),
    }
}

/// Spawn a background task that maintains the UPnP mapping.
pub fn spawn_renewal_task(local_port: u16) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(RENEW_INTERVAL_SECS)).await;
            match add_port_mapping(local_port).await {
                Ok(ip) => info!("UPnP renewal OK: external={ip}:{local_port}"),
                Err(e) => warn!("UPnP renewal failed: {e}"),
            }
        }
    })
}

fn get_local_ip_for_gateway(
    gateway_addr: &SocketAddr,
) -> Result<Ipv4Addr, String> {
    let socket =
        std::net::UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("bind failed: {e}"))?;
    socket
        .connect(gateway_addr)
        .map_err(|e| format!("connect to gateway failed: {e}"))?;
    match socket.local_addr() {
        Ok(SocketAddr::V4(v4)) => Ok(*v4.ip()),
        Ok(other) => Err(format!("unexpected address type: {other}")),
        Err(e) => Err(format!("local_addr failed: {e}")),
    }
}
