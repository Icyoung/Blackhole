use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
pub const DEFAULT_SOCKET_NAME: &str = "vpn-helper.sock";
pub const HELPER_ALREADY_ACTIVE_MESSAGE: &str = "VPN helper already active";

fn default_true() -> bool {
    true
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HelperRequest {
    StartVpn {
        version: u32,
        server_ip: String,
        subnet: String,
        netmask: String,
        app_port: u16,
        /// When false, skip pf rdr so the daemon can bind 10.13.37.1 explicitly.
        #[serde(default = "default_true")]
        ws_redirect: bool,
    },
    StopVpn {
        version: u32,
    },
    DisableWsRedirect {
        version: u32,
    },
}

impl HelperRequest {
    pub fn start_vpn(server_ip: String, subnet: String, netmask: String, app_port: u16) -> Self {
        Self::start_vpn_with_redirect(server_ip, subnet, netmask, app_port, true)
    }

    pub fn start_vpn_with_redirect(
        server_ip: String,
        subnet: String,
        netmask: String,
        app_port: u16,
        ws_redirect: bool,
    ) -> Self {
        Self::StartVpn {
            version: PROTOCOL_VERSION,
            server_ip,
            subnet,
            netmask,
            app_port,
            ws_redirect,
        }
    }

    pub fn stop_vpn() -> Self {
        Self::StopVpn {
            version: PROTOCOL_VERSION,
        }
    }

    pub fn disable_ws_redirect() -> Self {
        Self::DisableWsRedirect {
            version: PROTOCOL_VERSION,
        }
    }

    pub fn version(&self) -> u32 {
        match self {
            Self::StartVpn { version, .. }
            | Self::StopVpn { version }
            | Self::DisableWsRedirect { version } => *version,
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
    WsRedirectDisabled {
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

    pub fn ws_redirect_disabled() -> Self {
        Self::WsRedirectDisabled {
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
            | Self::WsRedirectDisabled { version }
            | Self::Error { version, .. } => *version,
        }
    }
}

/// Chown the helper control socket to the console/sudo user, then `chmod 0600`.
/// Helper runs as root; without this the daemon cannot connect.
#[cfg(unix)]
pub fn restrict_helper_socket(path: &std::path::Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;

    if let Some((uid, gid)) = helper_socket_owner_ids(path) {
        use std::os::unix::ffi::OsStrExt;
        let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| {
            format!(
                "helper socket path contains interior NUL: {}",
                path.display()
            )
        })?;
        let rc = unsafe { libc::chown(c_path.as_ptr(), uid, gid) };
        if rc != 0 {
            return Err(format!(
                "failed to chown helper socket {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
    } else if unsafe { libc::geteuid() } == 0 {
        return Err(format!(
            "helper is root but could not determine a non-root owner for {}",
            path.display()
        ));
    }

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| {
        format!(
            "failed to set helper socket permissions on {}: {e}",
            path.display()
        )
    })?;
    Ok(())
}

#[cfg(unix)]
pub fn helper_socket_owner_ids(socket_path: &std::path::Path) -> Option<(u32, u32)> {
    if let Some(uid) = parse_u32_env("SUDO_UID").filter(|&uid| uid != 0) {
        let gid = parse_u32_env("SUDO_GID").unwrap_or_else(|| primary_gid(uid));
        return Some((uid, gid));
    }

    if let Some(parent) = socket_path.parent() {
        if let Some((uid, gid)) = dir_owner(parent) {
            if uid != 0 {
                return Some((uid, gid));
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        if let Some((uid, _)) = dir_owner(std::path::Path::new("/dev/console")) {
            if uid != 0 {
                return Some((uid, primary_gid(uid)));
            }
        }
    }

    let uid = unsafe { libc::getuid() };
    if uid != 0 {
        return Some((uid, unsafe { libc::getgid() }));
    }
    None
}

#[cfg(unix)]
fn parse_u32_env(name: &str) -> Option<u32> {
    std::env::var(name).ok()?.parse().ok()
}

#[cfg(unix)]
fn dir_owner(path: &std::path::Path) -> Option<(u32, u32)> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.uid(), meta.gid()))
}

#[cfg(unix)]
fn primary_gid(uid: u32) -> u32 {
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() {
            uid
        } else {
            (*pw).pw_gid
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    #[test]
    fn restrict_helper_socket_sets_0600() {
        let path = std::env::temp_dir().join(format!(
            "horizon-helper-sock-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_file(&path);
        let _listener = UnixListener::bind(&path).expect("bind temp helper socket");
        restrict_helper_socket(&path).expect("restrict helper socket");
        let mode = std::fs::metadata(&path)
            .expect("stat helper socket")
            .permissions()
            .mode()
            & 0o777;
        let _ = std::fs::remove_file(&path);
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn start_vpn_json_defaults_ws_redirect_true() {
        let request = HelperRequest::start_vpn(
            "10.13.37.1".into(),
            "10.13.37.0/24".into(),
            "255.255.255.0".into(),
            9527,
        );
        let json = serde_json::to_value(&request).unwrap();
        assert_eq!(json["ws_redirect"], true);
        assert_eq!(json["app_port"], 9527);

        let parsed: HelperRequest = serde_json::from_str(
            r#"{"type":"start_vpn","version":1,"server_ip":"10.13.37.1","subnet":"10.13.37.0/24","netmask":"255.255.255.0","app_port":9527}"#,
        )
        .unwrap();
        match parsed {
            HelperRequest::StartVpn { ws_redirect, .. } => assert!(ws_redirect),
            other => panic!("unexpected {other:?}"),
        }
    }
}
