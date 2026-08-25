//! Voyager VPN helper — client-side privileged helper.
//!
//! Creates a TUN device, configures client IP/routes, and passes the TUN fd
//! to the calling process via Unix socket + SCM_RIGHTS.
//!
//! Unlike horizon-vpn-helper (server-side), this does NOT set up:
//! - Loopback aliases
//! - NAT / IP forwarding
//! - DNS forwarder

#[path = "../tun_device.rs"]
mod tun_device;
#[path = "../vpn_helper_protocol.rs"]
mod vpn_helper_protocol;

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use tracing::{error, info, warn};
use vpn_helper_protocol::{
    HelperRequest, HelperResponse, HELPER_ALREADY_ACTIVE_MESSAGE, PROTOCOL_VERSION,
};

#[derive(Default)]
struct ActiveVpnState {
    interface_name: Option<String>,
    subnet: Option<String>,
    client_ip: Option<String>,
    bridge_stop: Option<Arc<AtomicBool>>,
    bridge_thread: Option<JoinHandle<()>>,
}

fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let args = parse_args(std::env::args().skip(1).collect());
    if let Err(error) = run(args.socket_path, args.pid_path) {
        error!("{error}");
        std::process::exit(1);
    }
}

fn run(socket_path: PathBuf, pid_path: PathBuf) -> Result<(), String> {
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create socket directory: {e}"))?;
    }
    if let Some(parent) = pid_path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("failed to create pid directory: {e}"))?;
    }
    if socket_path.exists() {
        fs::remove_file(&socket_path).map_err(|e| format!("failed to remove stale socket: {e}"))?;
    }
    if pid_path.exists() {
        fs::remove_file(&pid_path).map_err(|e| format!("failed to remove stale pid file: {e}"))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .map_err(|e| format!("failed to bind socket {}: {e}", socket_path.display()))?;
    vpn_helper_protocol::restrict_helper_socket(&socket_path)?;
    fs::write(&pid_path, format!("{}\n", std::process::id()))
        .map_err(|e| format!("failed to write pid file: {e}"))?;

    info!("voyager-vpn-helper listening on {}", socket_path.display());
    let state = Arc::new(Mutex::new(ActiveVpnState::default()));
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle_client(stream, &state) {
                    warn!("helper request failed: {error}");
                }
            }
            Err(error) => warn!("helper accept failed: {error}"),
        }
    }

    Ok(())
}

fn handle_client(stream: UnixStream, state: &Arc<Mutex<ActiveVpnState>>) -> Result<(), String> {
    let mut reader = BufReader::new(
        stream
            .try_clone()
            .map_err(|e| format!("clone stream: {e}"))?,
    );
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|e| format!("read request: {e}"))?;
    if line.trim().is_empty() {
        return Err("received empty request".to_string());
    }

    let request: HelperRequest =
        serde_json::from_str(&line).map_err(|e| format!("invalid request: {e}"))?;
    if request.version() != PROTOCOL_VERSION {
        send_response(
            &stream,
            &HelperResponse::error(format!(
                "protocol mismatch: expected v{}, got v{}",
                PROTOCOL_VERSION,
                request.version()
            )),
            None,
        )?;
        return Ok(());
    }

    match request {
        HelperRequest::StartVpn {
            server_ip: client_ip, // caller passes client IP as server_ip field
            subnet,
            netmask,
            app_port: _,
            ..
        } => {
            {
                let state = state.lock().map_err(|_| "lock failed".to_string())?;
                if state.interface_name.is_some() {
                    send_response(
                        &stream,
                        &HelperResponse::error(HELPER_ALREADY_ACTIVE_MESSAGE),
                        None,
                    )?;
                    return Ok(());
                }
            }

            let tun =
                tun_device::create_tun(None).map_err(|e| format!("failed to create TUN: {e}"))?;
            info!("created TUN device {}", tun.name);
            let interface_name = tun.name.clone();

            // Configure as client: local=clientIp, peer=10.13.37.1, subnet route
            configure_client_tun(&tun.name, &client_ip, &netmask)?;

            // Add subnet route
            let subnet_net = subnet.split('/').next().unwrap_or("10.13.37.0");
            let _ = Command::new("route")
                .args(["add", "-net", &subnet, "-interface", &tun.name])
                .output();
            info!(
                "configured TUN: {} -> 10.13.37.1, route {}",
                client_ip, subnet
            );

            // Pass raw TUN fd directly to client (no socketpair bridge).
            // Client handles 4-byte AF header read/write itself.
            if let Err(error) = send_response(
                &stream,
                &HelperResponse::started(interface_name.clone()),
                Some(tun.fd),
            ) {
                cleanup_vpn(Some(interface_name), Some(subnet.clone()), None, None);
                return Err(error);
            }
            std::mem::forget(tun); // Client owns the TUN fd now

            {
                let mut state = state.lock().map_err(|_| "lock failed".to_string())?;
                state.interface_name = Some(interface_name);
                state.subnet = Some(subnet);
                state.client_ip = Some(client_ip);
            }
        }
        HelperRequest::StopVpn { .. } => {
            let (interface_name, subnet, bridge_stop, bridge_thread) = {
                let mut state = state.lock().map_err(|_| "lock failed".to_string())?;
                (
                    state.interface_name.take(),
                    state.subnet.take(),
                    state.bridge_stop.take(),
                    state.bridge_thread.take(),
                )
            };
            cleanup_vpn(interface_name, subnet, bridge_stop, bridge_thread);
            send_response(&stream, &HelperResponse::stopped(), None)?;
        }
        HelperRequest::DisableWsRedirect { .. } => {
            send_response(&stream, &HelperResponse::ws_redirect_disabled(), None)?;
        }
    }

    Ok(())
}

fn configure_client_tun(iface: &str, client_ip: &str, netmask: &str) -> Result<(), String> {
    // Point-to-point: local=client_ip, remote=10.13.37.1 (server VPN IP)
    let output = Command::new("ifconfig")
        .args([iface, client_ip, "10.13.37.1", "netmask", netmask, "up"])
        .output()
        .map_err(|e| format!("ifconfig failed: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ifconfig failed: {}", stderr.trim()));
    }
    Ok(())
}

fn cleanup_vpn(
    interface_name: Option<String>,
    _subnet: Option<String>,
    bridge_stop: Option<Arc<AtomicBool>>,
    bridge_thread: Option<JoinHandle<()>>,
) {
    if let Some(stop) = bridge_stop {
        stop.store(true, Ordering::SeqCst);
    }
    if let Some(handle) = bridge_thread {
        let _ = handle.join();
    }
    if let Some(iface) = interface_name {
        let _ = Command::new("ifconfig").args([&iface, "down"]).output();
    }
}

// --- Shared helpers (same as horizon-vpn-helper) ---

fn send_response(
    stream: &UnixStream,
    response: &HelperResponse,
    fd: Option<RawFd>,
) -> Result<(), String> {
    let payload = serde_json::to_vec(response).map_err(|e| format!("serialize response: {e}"))?;
    let mut iov = libc::iovec {
        iov_base: payload.as_ptr() as *mut libc::c_void,
        iov_len: payload.len(),
    };
    let control_len = if fd.is_some() {
        unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as _) as usize }
    } else {
        0
    };
    let mut control = vec![0u8; control_len];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if let Some(fd) = fd {
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = control_len as _;
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&msg);
            if header.is_null() {
                return Err("CMSG_FIRSTHDR returned null".to_string());
            }
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as _);
            let data = libc::CMSG_DATA(header) as *mut RawFd;
            *data = fd;
        }
    }
    let sent = unsafe { libc::sendmsg(stream.as_raw_fd(), &msg, 0) };
    if sent < 0 {
        return Err(format!(
            "sendmsg failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn spawn_packet_bridge(
    tun_fd: RawFd,
    helper_fd: RawFd,
    stop: Arc<AtomicBool>,
    interface_name: String,
    state: Arc<Mutex<ActiveVpnState>>,
) -> Result<JoinHandle<()>, String> {
    thread::Builder::new()
        .name("voyager-vpn-bridge".to_string())
        .spawn(move || {
            run_packet_bridge(tun_fd, helper_fd, stop, interface_name.clone());
            // Auto-cleanup when bridge exits (app disconnected)
            if let Ok(mut s) = state.lock() {
                if s.interface_name.as_deref() == Some(&interface_name) {
                    info!("bridge auto-cleanup for {}", interface_name);
                    let _ = std::process::Command::new("ifconfig")
                        .args([&interface_name, "down"])
                        .output();
                    s.interface_name = None;
                    s.subnet = None;
                    s.client_ip = None;
                    s.bridge_stop = None;
                    s.bridge_thread = None;
                }
            }
        })
        .map_err(|e| format!("spawn bridge thread: {e}"))
}

fn run_packet_bridge(
    tun_fd: RawFd,
    helper_fd: RawFd,
    stop: Arc<AtomicBool>,
    interface_name: String,
) {
    let mut tun_buf = [0u8; 4096];
    let mut bridge_buf = [0u8; 4096];
    info!(interface = %interface_name, tun_fd, helper_fd, "bridge started");

    while !stop.load(Ordering::SeqCst) {
        let mut poll_fds = [
            libc::pollfd {
                fd: tun_fd,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: helper_fd,
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let poll_result = unsafe { libc::poll(poll_fds.as_mut_ptr(), 2, 200) };
        if poll_result < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            warn!("bridge poll failed for {}: {}", interface_name, error);
            break;
        }
        if poll_result == 0 {
            continue;
        }

        if (poll_fds[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)) != 0
            || (poll_fds[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)) != 0
        {
            info!("bridge terminating on poll error for {}", interface_name);
            break;
        }

        // TUN → daemon (strip 4-byte AF header)
        if (poll_fds[0].revents & libc::POLLIN) != 0 {
            let n = unsafe { libc::read(tun_fd, tun_buf.as_mut_ptr() as _, tun_buf.len()) };
            if n > 4 {
                let ip_len = n as usize - 4;
                tun_buf.copy_within(4..n as usize, 0);
                let sent = unsafe { libc::send(helper_fd, tun_buf.as_ptr() as _, ip_len, 0) };
                if sent < 0 {
                    let e = std::io::Error::last_os_error();
                    warn!(interface = %interface_name, "bridge send to daemon failed: {e}");
                    break;
                }
            } else if n < 0 {
                let e = std::io::Error::last_os_error();
                warn!(interface = %interface_name, "tun read error: {e}");
            }
        }

        // Daemon → TUN (prepend 4-byte AF header)
        if (poll_fds[1].revents & libc::POLLIN) != 0 {
            let n =
                unsafe { libc::recv(helper_fd, bridge_buf.as_mut_ptr() as _, bridge_buf.len(), 0) };
            if n > 0 {
                let n = n as usize;
                let af: u32 = if (bridge_buf[0] >> 4) == 6 {
                    libc::AF_INET6 as u32
                } else {
                    libc::AF_INET as u32
                };
                let mut prefixed = Vec::with_capacity(4 + n);
                prefixed.extend_from_slice(&af.to_ne_bytes());
                prefixed.extend_from_slice(&bridge_buf[..n]);
                let _ = unsafe { libc::write(tun_fd, prefixed.as_ptr() as _, prefixed.len()) };
            } else if n == 0 {
                info!("bridge daemon socket closed for {}", interface_name);
                break;
            }
        }
    }

    close_fd(helper_fd);
    close_fd(tun_fd);
    info!("bridge exited for {}", interface_name);
}

fn create_bridge_socketpair() -> Result<(RawFd, RawFd), String> {
    let mut fds = [0; 2];
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) } < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok((fds[0], fds[1]))
}

fn close_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

struct ParsedArgs {
    socket_path: PathBuf,
    pid_path: PathBuf,
}

fn parse_args(args: Vec<String>) -> ParsedArgs {
    let mut iter = args.into_iter();
    let mut socket_path: Option<PathBuf> = None;
    let mut pid_path: Option<PathBuf> = None;
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--socket" => {
                socket_path = iter.next().map(PathBuf::from);
            }
            "--pid-file" => {
                pid_path = iter.next().map(PathBuf::from);
            }
            _ => {}
        }
    }
    ParsedArgs {
        socket_path: socket_path.unwrap_or_else(default_socket_path),
        pid_path: pid_path.unwrap_or_else(default_pid_path),
    }
}

fn default_pid_path() -> PathBuf {
    resolve_home()
        .join(".blackhole")
        .join("voyager")
        .join("vpn-helper.pid")
}

fn default_socket_path() -> PathBuf {
    resolve_home()
        .join(".blackhole")
        .join("voyager")
        .join("vpn-helper.sock")
}

fn resolve_home() -> PathBuf {
    std::env::var("HOME")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}
