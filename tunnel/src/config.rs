use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WgConfig {
    pub private_key: String,
    pub peer_public_key: String,
    pub preshared_key: Option<String>,
    pub keepalive_secs: Option<u16>,
    pub endpoint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VpnConfig {
    pub client_ip: String,
    pub server_ip: String,
    pub subnet: String,
    pub dns: Vec<String>,
    pub internal_routes: Vec<String>,
    pub mtu: u16,
}
