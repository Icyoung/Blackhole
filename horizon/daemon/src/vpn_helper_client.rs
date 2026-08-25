use std::env;
#[cfg(unix)]
use std::io::Write;
#[cfg(unix)]
use std::os::fd::{AsRawFd, RawFd};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

#[cfg(not(unix))]
use crate::tun_device::TunDevice;
#[cfg(unix)]
use crate::tun_device::{TunDevice, TunTransport};
use crate::vpn_helper_protocol::{
    HelperRequest, HelperResponse, DEFAULT_SOCKET_NAME, HELPER_ALREADY_ACTIVE_MESSAGE,
    PROTOCOL_VERSION,
};

pub struct PreparedTun {
    pub tun: TunDevice,
    pub session: HelperSession,
}

pub struct HelperSession {
    #[cfg(unix)]
    socket_path: PathBuf,
}

impl HelperSession {
    pub fn stop(self) -> Result<(), String> {
        #[cfg(unix)]
        {
            let response = send_request(&self.socket_path, &HelperRequest::stop_vpn())?;
            match response {
                HelperResponse::Stopped { .. } => Ok(()),
                HelperResponse::Error { message, .. } => Err(message),
                other => Err(format!("unexpected helper response: {:?}", other)),
            }
        }

        #[cfg(not(unix))]
        {
            Err("VPN helper is not supported on this platform".to_string())
        }
    }

    pub fn disable_ws_redirect(&self) -> Result<(), String> {
        #[cfg(unix)]
        {
            let response = send_request(&self.socket_path, &HelperRequest::disable_ws_redirect())?;
            match response {
                HelperResponse::WsRedirectDisabled { .. } => Ok(()),
                HelperResponse::Error { message, .. } => Err(message),
                other => Err(format!("unexpected helper response: {:?}", other)),
            }
        }

        #[cfg(not(unix))]
        {
            Err("VPN helper is not supported on this platform".to_string())
        }
    }
}

pub fn socket_path(data_dir: &Path) -> PathBuf {
    if let Ok(value) = env::var("HORIZON_VPN_HELPER_SOCKET") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    data_dir.join(DEFAULT_SOCKET_NAME)
}

pub fn is_available(data_dir: &Path) -> bool {
    #[cfg(unix)]
    {
        return socket_path(data_dir).exists();
    }

    #[cfg(not(unix))]
    {
        let _ = data_dir;
        false
    }
}

pub fn start_vpn(
    data_dir: &Path,
    server_ip: &str,
    subnet: &str,
    netmask: &str,
    app_port: u16,
    ws_redirect: bool,
) -> Result<PreparedTun, String> {
    #[cfg(unix)]
    {
        let socket_path = socket_path(data_dir);
        match start_vpn_once(
            &socket_path,
            server_ip,
            subnet,
            netmask,
            app_port,
            ws_redirect,
        ) {
            Ok(prepared) => Ok(prepared),
            Err(message) if message == HELPER_ALREADY_ACTIVE_MESSAGE => {
                let response = send_request(&socket_path, &HelperRequest::stop_vpn())?;
                match response {
                    HelperResponse::Stopped { .. } => start_vpn_once(
                        &socket_path,
                        server_ip,
                        subnet,
                        netmask,
                        app_port,
                        ws_redirect,
                    ),
                    HelperResponse::Error { message, .. } => Err(format!(
                        "failed to recover stale helper-backed VPN: {message}"
                    )),
                    other => Err(format!(
                        "unexpected helper response while recovering stale VPN: {:?}",
                        other
                    )),
                }
            }
            Err(message) => Err(message),
        }
    }

    #[cfg(not(unix))]
    {
        let _ = (data_dir, server_ip, subnet, netmask, app_port, ws_redirect);
        Err("VPN helper is not supported on this platform".to_string())
    }
}

#[cfg(unix)]
fn start_vpn_once(
    socket_path: &Path,
    server_ip: &str,
    subnet: &str,
    netmask: &str,
    app_port: u16,
    ws_redirect: bool,
) -> Result<PreparedTun, String> {
    let (response, fd) = send_request_with_optional_fd(
        socket_path,
        &HelperRequest::start_vpn_with_redirect(
            server_ip.to_string(),
            subnet.to_string(),
            netmask.to_string(),
            app_port,
            ws_redirect,
        ),
    )?;

    match response {
        HelperResponse::Started { interface_name, .. } => {
            let fd =
                fd.ok_or_else(|| "helper started VPN without returning a TUN fd".to_string())?;
            set_nonblocking(fd)?;
            Ok(PreparedTun {
                tun: TunDevice {
                    fd,
                    name: interface_name,
                    transport: TunTransport::PacketSocket,
                },
                session: HelperSession {
                    socket_path: socket_path.to_path_buf(),
                },
            })
        }
        HelperResponse::Error { message, .. } => Err(message),
        other => Err(format!("unexpected helper response: {:?}", other)),
    }
}

#[cfg(unix)]
fn send_request(socket_path: &Path, request: &HelperRequest) -> Result<HelperResponse, String> {
    let (response, _) = send_request_with_optional_fd(socket_path, request)?;
    Ok(response)
}

#[cfg(unix)]
fn send_request_with_optional_fd(
    socket_path: &Path,
    request: &HelperRequest,
) -> Result<(HelperResponse, Option<RawFd>), String> {
    let mut stream = UnixStream::connect(socket_path)
        .map_err(|e| format!("failed to connect to helper {}: {e}", socket_path.display()))?;

    let mut payload =
        serde_json::to_vec(request).map_err(|e| format!("serialize helper request: {e}"))?;
    payload.push(b'\n');
    stream
        .write_all(&payload)
        .map_err(|e| format!("failed to write helper request: {e}"))?;

    let mut body = [0u8; 4096];
    let control_len = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as _) as usize };
    let mut control = vec![0u8; control_len];
    let mut iov = libc::iovec {
        iov_base: body.as_mut_ptr() as *mut libc::c_void,
        iov_len: body.len(),
    };
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
    msg.msg_controllen = control_len as _;

    let received = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut msg, 0) };
    if received < 0 {
        return Err(format!(
            "failed to receive helper response: {}",
            std::io::Error::last_os_error()
        ));
    }
    if received == 0 {
        return Err("helper closed the connection without responding".to_string());
    }

    let fd = unsafe { extract_fd(&msg) };
    let response: HelperResponse = serde_json::from_slice(&body[..received as usize])
        .map_err(|e| format!("failed to decode helper response: {e}"))?;

    if response.version() != PROTOCOL_VERSION {
        return Err(format!(
            "helper protocol mismatch: expected v{}, got v{}",
            PROTOCOL_VERSION,
            response.version()
        ));
    }

    Ok((response, fd))
}

#[cfg(unix)]
fn set_nonblocking(fd: RawFd) -> Result<(), String> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            return Err(format!(
                "failed to get helper packet socket flags: {}",
                std::io::Error::last_os_error()
            ));
        }
        if libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err(format!(
                "failed to set helper packet socket nonblocking: {}",
                std::io::Error::last_os_error()
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
unsafe fn extract_fd(msg: &libc::msghdr) -> Option<RawFd> {
    let mut header = libc::CMSG_FIRSTHDR(msg);
    while !header.is_null() {
        if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
            let data = libc::CMSG_DATA(header) as *const RawFd;
            return Some(*data);
        }
        header = libc::CMSG_NXTHDR(msg, header);
    }
    None
}
