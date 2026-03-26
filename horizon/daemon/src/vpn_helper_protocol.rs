use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
pub const DEFAULT_SOCKET_NAME: &str = "vpn-helper.sock";
pub const HELPER_ALREADY_ACTIVE_MESSAGE: &str = "VPN helper already active";

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HelperRequest {
    StartVpn {
        version: u32,
        server_ip: String,
        subnet: String,
        netmask: String,
        app_port: u16,
    },
    StopVpn {
        version: u32,
    },
}

impl HelperRequest {
    pub fn start_vpn(server_ip: String, subnet: String, netmask: String, app_port: u16) -> Self {
        Self::StartVpn {
            version: PROTOCOL_VERSION,
            server_ip,
            subnet,
            netmask,
            app_port,
        }
    }

    pub fn stop_vpn() -> Self {
        Self::StopVpn {
            version: PROTOCOL_VERSION,
        }
    }

    pub fn version(&self) -> u32 {
        match self {
            Self::StartVpn { version, .. } | Self::StopVpn { version } => *version,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HelperResponse {
    Started {
        version: u32,
        interface_name: String,
    },
    Stopped {
        version: u32,
    },
    Error {
        version: u32,
        message: String,
    },
}

impl HelperResponse {
    pub fn started(interface_name: String) -> Self {
        Self::Started {
            version: PROTOCOL_VERSION,
            interface_name,
        }
    }

    pub fn stopped() -> Self {
        Self::Stopped {
            version: PROTOCOL_VERSION,
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self::Error {
            version: PROTOCOL_VERSION,
            message: message.into(),
        }
    }

    pub fn version(&self) -> u32 {
        match self {
            Self::Started { version, .. }
            | Self::Stopped { version }
            | Self::Error { version, .. } => *version,
        }
    }
}
