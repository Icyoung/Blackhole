use serde::{Deserialize, Serialize};

/// VPN server configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnServerConfig {
    /// Enable VPN service.
    pub enabled: bool,
    /// VPN subnet (e.g., "10.13.37.0/24").
    pub subnet: String,
    /// WireGuard listen port.
    pub port: u16,
    /// Internal network routes to advertise to clients (e.g., ["192.168.1.0/24"]).
    #[serde(default)]
    pub internal_routes: Vec<String>,
    /// MTU for the VPN tunnel.
    pub mtu: u16,
}

impl Default for VpnServerConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            subnet: "10.13.37.0/24".to_string(),
            port: 51820,
            internal_routes: Vec::new(),
            mtu: 1280,
        }
    }
}

/// VPN assignment sent to a connecting client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnAssignment {
    pub client_ip: String,
    pub server_ip: String,
    pub subnet: String,
    pub dns: Vec<String>,
    pub internal_routes: Vec<String>,
    pub mtu: u16,
}

/// VPN client status info.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnClientStatus {
    pub device_key: Option<String>,
    pub client_ip: String,
    pub endpoint: String,
    pub last_handshake: Option<String>,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// VPN server runtime status.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStatus {
    pub enabled: bool,
    pub running: bool,
    pub tun_device: Option<String>,
    pub server_ip: String,
    pub subnet: String,
    pub listen_port: u16,
    pub public_key: Option<String>,
    pub client_count: usize,
    pub clients: Vec<VpnClientStatus>,
}

impl Default for VpnStatus {
    fn default() -> Self {
        Self {
            enabled: false,
            running: false,
            tun_device: None,
            server_ip: "10.13.37.1".to_string(),
            subnet: "10.13.37.0/24".to_string(),
            listen_port: 51820,
            public_key: None,
            client_count: 0,
            clients: Vec::new(),
        }
    }
}
