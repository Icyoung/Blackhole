#[path = "../dns_forwarder.rs"]
mod dns_forwarder;
#[path = "../nat.rs"]
mod nat;
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
    HelperRequest, HelperResponse, DEFAULT_SOCKET_NAME, HELPER_ALREADY_ACTIVE_MESSAGE,
    PROTOCOL_VERSION,
};

#[derive(Default)]
struct ActiveVpnState {
    interface_name: Option<String>,
    subnet: Option<String>,
    server_ip: Option<String>,
    ws_redirect: bool,
    bridge_stop: Option<Arc<AtomicBool>>,
    bridge_thread: Option<JoinHandle<()>>,
    dns_stop: Option<Arc<AtomicBool>>,
    dns_thread: Option<JoinHandle<()>>,
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
            .map_err(|e| format!("failed to create helper socket directory: {e}"))?;
    }
    if let Some(parent) = pid_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create helper pid directory: {e}"))?;
    }
    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .map_err(|e| format!("failed to remove stale helper socket: {e}"))?;
    }
    if pid_path.exists() {
        fs::remove_file(&pid_path)
            .map_err(|e| format!("failed to remove stale helper pid file: {e}"))?;
    }

    let listener = UnixListener::bind(&socket_path).map_err(|e| {
        format!(
            "failed to bind helper socket {}: {e}",
            socket_path.display()
        )
    })?;
    vpn_helper_protocol::restrict_helper_socket(&socket_path)?;
    fs::write(&pid_path, format!("{}\n", std::process::id()))
        .map_err(|e| format!("failed to write helper pid file: {e}"))?;

    info!("horizon-vpn-helper listening on {}", socket_path.display());
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
            .map_err(|e| format!("failed to clone helper stream: {e}"))?,
    );
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|e| format!("failed to read helper request: {e}"))?;
    if line.trim().is_empty() {
        return Err("helper received an empty request".to_string());
    }

    let request: HelperRequest =
        serde_json::from_str(&line).map_err(|e| format!("invalid helper request: {e}"))?;
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
            server_ip,
            subnet,
            netmask,
            app_port,
            ws_redirect,
            ..
        } => {
            {
                let state = state
                    .lock()
                    .map_err(|_| "failed to lock helper state".to_string())?;
                if state.interface_name.is_some() {
                    send_response(
                        &stream,
                        &HelperResponse::error(HELPER_ALREADY_ACTIVE_MESSAGE),
                        None,
                    )?;
                    return Ok(());
                }
            }

            let tun = tun_device::create_tun(None)
                .map_err(|e| format!("failed to create helper TUN device: {e}"))?;
            info!("helper created TUN device {}", tun.name);
            let interface_name = tun.name.clone();

            tun_device::configure_tun(&tun, &server_ip, &netmask)
                .map_err(|e| format!("failed to configure helper TUN: {e}"))?;
            // Note: loopback alias intentionally NOT set. The daemon binds on
            // 0.0.0.0 so it already accepts connections on the TUN interface.
            // Adding a loopback alias for server_ip causes reply packets to
            // route through lo0 instead of TUN, breaking VPN client connectivity.

            if let Err(error) = nat::enable_ip_forwarding() {
                warn!("helper failed to enable IP forwarding: {error}");
            }
            let mut rdr_installed = ws_redirect && app_port != 0;
            let local_ws_redirect = if rdr_installed {
                Some((server_ip.as_str(), app_port, Some(interface_name.as_str())))
            } else {
                None
            };
            if let Err(error) = nat::setup_nat(&subnet, None, local_ws_redirect) {
                if rdr_installed {
                    error!("helper failed to setup NAT/rdr: {error}");
                    rdr_installed = false;
                } else {
                    warn!("helper failed to setup NAT: {error}");
                }
            }

            let dns_upstream = dns_forwarder::detect_system_dns();
            let dns_stop = Arc::new(AtomicBool::new(false));
            let dns_thread =
                spawn_dns_forwarder(server_ip.clone(), dns_upstream, dns_stop.clone())?;

            let (daemon_fd, helper_fd) = create_bridge_socketpair()
                .map_err(|e| format!("failed to create helper bridge socketpair: {e}"))?;
            let bridge_stop = Arc::new(AtomicBool::new(false));
            let bridge_thread = spawn_packet_bridge(
                tun.fd,
                helper_fd,
                bridge_stop.clone(),
                interface_name.clone(),
            )?;
            if let Err(error) = send_response(
                &stream,
                &HelperResponse::started_with_redirect(interface_name.clone(), rdr_installed),
                Some(daemon_fd),
            ) {
                bridge_stop.store(true, Ordering::SeqCst);
                dns_stop.store(true, Ordering::SeqCst);
                let _ = bridge_thread.join();
                let _ = dns_thread.join();
                close_fd(daemon_fd);
                cleanup_active_vpn(
                    Some(interface_name),
                    Some(subnet.clone()),
                    Some(server_ip.clone()),
                    None,
                    None,
                    None,
                    None,
                );
                return Err(error);
            }
            close_fd(daemon_fd);
            std::mem::forget(tun);

            {
                let mut state = state
                    .lock()
                    .map_err(|_| "failed to lock helper state".to_string())?;
                state.interface_name = Some(interface_name);
                state.subnet = Some(subnet);
                state.server_ip = Some(server_ip);
                state.ws_redirect = rdr_installed;
                state.bridge_stop = Some(bridge_stop);
                state.bridge_thread = Some(bridge_thread);
                state.dns_stop = Some(dns_stop);
                state.dns_thread = Some(dns_thread);
            }
        }
        HelperRequest::StopVpn { .. } => {
            let (
                interface_name,
                subnet,
                server_ip,
                bridge_stop,
                bridge_thread,
                dns_stop,
                dns_thread,
            ) = {
                let mut state = state
                    .lock()
                    .map_err(|_| "failed to lock helper state".to_string())?;
                state.ws_redirect = false;
                (
                    state.interface_name.take(),
                    state.subnet.take(),
                    state.server_ip.take(),
                    state.bridge_stop.take(),
                    state.bridge_thread.take(),
                    state.dns_stop.take(),
                    state.dns_thread.take(),
                )
            };

            cleanup_active_vpn(
                interface_name,
                subnet,
                server_ip,
                bridge_stop,
                bridge_thread,
                dns_stop,
                dns_thread,
            );
            send_response(&stream, &HelperResponse::stopped(), None)?;
        }
        HelperRequest::DisableWsRedirect { .. } => {
            let subnet = {
                let mut state = state
                    .lock()
                    .map_err(|_| "failed to lock helper state".to_string())?;
                if state.interface_name.is_none() {
                    None
                } else {
                    state.ws_redirect = false;
                    state.subnet.clone()
                }
            };
            match subnet {
                Some(subnet) => {
                    if let Err(error) = nat::setup_nat(&subnet, None, None) {
                        send_response(&stream, &HelperResponse::error(error), None)?;
                        return Ok(());
                    }
                    send_response(&stream, &HelperResponse::ws_redirect_disabled(), None)?;
                }
                None => {
                    send_response(
                        &stream,
                        &HelperResponse::error("VPN helper is not active"),
                        None,
                    )?;
                }
            }
        }
    }

    Ok(())
}

fn send_response(
    stream: &UnixStream,
    response: &HelperResponse,
    fd: Option<RawFd>,
) -> Result<(), String> {
    let payload =
        serde_json::to_vec(response).map_err(|e| format!("serialize helper response: {e}"))?;
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
                return Err("failed to allocate helper control message".to_string());
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
            "failed to send helper response: {}",
            std::io::Error::last_os_error()
        ));
    }

    Ok(())
}

fn cleanup_active_vpn(
    interface_name: Option<String>,
    subnet: Option<String>,
    server_ip: Option<String>,
    bridge_stop: Option<Arc<AtomicBool>>,
    bridge_thread: Option<JoinHandle<()>>,
    dns_stop: Option<Arc<AtomicBool>>,
    dns_thread: Option<JoinHandle<()>>,
) {
    if let Some(stop) = bridge_stop {
        stop.store(true, Ordering::SeqCst);
    }
    if let Some(handle) = bridge_thread {
        let _ = handle.join();
    }
    if let Some(stop) = dns_stop {
        stop.store(true, Ordering::SeqCst);
    }
    if let Some(handle) = dns_thread {
        let _ = handle.join();
    }
    if let Some(interface_name) = interface_name {
        let _ = Command::new("ifconfig")
            .args([&interface_name, "down"])
            .output();
    }
    if subnet.is_some() {
        let _ = nat::teardown_nat();
    }
}

fn ensure_loopback_alias(server_ip: &str) -> Result<(), String> {
    let output = Command::new("ifconfig")
        .args([
            "lo0",
            "alias",
            server_ip,
            server_ip,
            "netmask",
            "0xffffffff",
        ])
        .output()
        .map_err(|e| format!("failed to run `ifconfig lo0 alias`: {e}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("File exists") {
        return Ok(());
    }

    Err(format!(
        "ifconfig lo0 alias failed (exit {}): {}",
        output.status.code().unwrap_or(-1),
        stderr.trim()
    ))
}

fn remove_loopback_alias(server_ip: &str) -> Result<(), String> {
    let output = Command::new("ifconfig")
        .args(["lo0", "-alias", server_ip])
        .output()
        .map_err(|e| format!("failed to run `ifconfig lo0 -alias`: {e}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("Can't assign requested address") {
        return Ok(());
    }

    Err(format!(
        "ifconfig lo0 -alias failed (exit {}): {}",
        output.status.code().unwrap_or(-1),
        stderr.trim()
    ))
}

fn spawn_dns_forwarder(
    server_ip: String,
    upstream: std::net::SocketAddr,
    stop: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, String> {
    thread::Builder::new()
        .name("horizon-vpn-dns".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    warn!("failed to build helper DNS runtime: {}", error);
                    return;
                }
            };
            let listen_addr: std::net::SocketAddr = match format!("{server_ip}:53").parse() {
                Ok(addr) => addr,
                Err(error) => {
                    warn!("invalid helper DNS listen addr: {}", error);
                    return;
                }
            };

            if let Err(error) = runtime.block_on(dns_forwarder::run_dns_forwarder_until(
                listen_addr,
                upstream,
                Some(stop),
            )) {
                warn!("helper DNS forwarder error: {}", error);
            }
        })
        .map_err(|e| format!("failed to spawn helper DNS thread: {e}"))
}

fn spawn_packet_bridge(
    tun_fd: RawFd,
    helper_fd: RawFd,
    stop: Arc<AtomicBool>,
    interface_name: String,
) -> Result<JoinHandle<()>, String> {
    thread::Builder::new()
        .name("horizon-vpn-bridge".to_string())
        .spawn(move || run_packet_bridge(tun_fd, helper_fd, stop, interface_name))
        .map_err(|e| format!("failed to spawn helper bridge thread: {e}"))
}

fn run_packet_bridge(
    tun_fd: RawFd,
    helper_fd: RawFd,
    stop: Arc<AtomicBool>,
    interface_name: String,
) {
    let mut tun_buf = [0u8; 4096];
    let mut bridge_buf = [0u8; 4096];
    let mut utun_to_daemon_packets: u64 = 0;
    let mut daemon_to_utun_packets: u64 = 0;

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

        let poll_result = unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, 200) };
        if poll_result < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            warn!(
                "helper bridge poll failed for {}: {}",
                interface_name, error
            );
            break;
        }
        if poll_result == 0 {
            continue;
        }

        if has_terminal_poll_error(poll_fds[0].revents)
            || has_terminal_poll_error(poll_fds[1].revents)
        {
            warn!(
                "helper bridge terminating after poll error for {}",
                interface_name
            );
            break;
        }

        if (poll_fds[0].revents & libc::POLLIN) != 0 {
            match read_utun_packet(tun_fd, &mut tun_buf) {
                Ok(Some(n)) => {
                    utun_to_daemon_packets += 1;
                    if utun_to_daemon_packets <= 5 {
                        info!(
                            interface = %interface_name,
                            direction = "utun_to_daemon",
                            packet_index = utun_to_daemon_packets,
                            packet_len = n,
                            summary = %describe_ip_packet(&tun_buf[..n]),
                            "helper bridge forwarded packet"
                        );
                    }
                    if let Err(error) = send_bridge_packet(helper_fd, &tun_buf[..n]) {
                        warn!(
                            "helper bridge failed sending utun packet for {}: {}",
                            interface_name, error
                        );
                        break;
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        "helper bridge failed reading utun packet for {}: {}",
                        interface_name, error
                    );
                    break;
                }
            }
        }

        if (poll_fds[1].revents & libc::POLLIN) != 0 {
            match recv_bridge_packet(helper_fd, &mut bridge_buf) {
                Ok(Some(n)) => {
                    daemon_to_utun_packets += 1;
                    if daemon_to_utun_packets <= 5 {
                        info!(
                            interface = %interface_name,
                            direction = "daemon_to_utun",
                            packet_index = daemon_to_utun_packets,
                            packet_len = n,
                            summary = %describe_ip_packet(&bridge_buf[..n]),
                            "helper bridge forwarded packet"
                        );
                    }
                    if let Err(error) = write_utun_packet(tun_fd, &bridge_buf[..n]) {
                        warn!(
                            "helper bridge failed writing daemon packet for {}: {}",
                            interface_name, error
                        );
                        break;
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        "helper bridge failed reading daemon packet for {}: {}",
                        interface_name, error
                    );
                    break;
                }
            }
        }
    }

    close_fd(helper_fd);
    close_fd(tun_fd);
    info!(
        interface = %interface_name,
        utun_to_daemon_packets,
        daemon_to_utun_packets,
        "helper bridge thread exited"
    );
}

fn describe_ip_packet(packet: &[u8]) -> String {
    if packet.is_empty() {
        return "empty".to_string();
    }

    match packet[0] >> 4 {
        4 if packet.len() >= 20 => format!(
            "ipv4 src={}.{}.{}.{} dst={}.{}.{}.{} proto={} len={}",
            packet[12],
            packet[13],
            packet[14],
            packet[15],
            packet[16],
            packet[17],
            packet[18],
            packet[19],
            packet[9],
            packet.len()
        ),
        6 if packet.len() >= 40 => format!("ipv6 next_header={} len={}", packet[6], packet.len()),
        version => format!("unknown_ip_version={} len={}", version, packet.len()),
    }
}

fn create_bridge_socketpair() -> Result<(RawFd, RawFd), String> {
    let mut fds = [0; 2];
    let result = unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) };
    if result < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok((fds[0], fds[1]))
}

fn has_terminal_poll_error(revents: i16) -> bool {
    (revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)) != 0
}

fn read_utun_packet(fd: RawFd, buf: &mut [u8]) -> Result<Option<usize>, String> {
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if n < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::WouldBlock
            || error.kind() == std::io::ErrorKind::Interrupted
        {
            return Ok(None);
        }
        return Err(error.to_string());
    }
    let n = n as usize;
    if n <= 4 {
        return Ok(None);
    }
    buf.copy_within(4..n, 0);
    Ok(Some(n - 4))
}

fn recv_bridge_packet(fd: RawFd, buf: &mut [u8]) -> Result<Option<usize>, String> {
    let n = unsafe { libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
    if n < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::WouldBlock
            || error.kind() == std::io::ErrorKind::Interrupted
        {
            return Ok(None);
        }
        return Err(error.to_string());
    }
    if n == 0 {
        return Err("daemon packet socket closed".to_string());
    }
    Ok(Some(n as usize))
}

fn send_bridge_packet(fd: RawFd, buf: &[u8]) -> Result<(), String> {
    let sent = unsafe { libc::send(fd, buf.as_ptr() as *const libc::c_void, buf.len(), 0) };
    if sent < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    if sent as usize != buf.len() {
        return Err(format!(
            "short bridge packet send: expected {}, wrote {}",
            buf.len(),
            sent
        ));
    }
    Ok(())
}

fn write_utun_packet(fd: RawFd, buf: &[u8]) -> Result<(), String> {
    if buf.is_empty() {
        return Ok(());
    }

    let af: u32 = if (buf[0] >> 4) == 6 {
        libc::AF_INET6 as u32
    } else {
        libc::AF_INET as u32
    };
    let mut prefixed = Vec::with_capacity(4 + buf.len());
    prefixed.extend_from_slice(&af.to_ne_bytes());
    prefixed.extend_from_slice(buf);

    let written =
        unsafe { libc::write(fd, prefixed.as_ptr() as *const libc::c_void, prefixed.len()) };
    if written < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    if written as usize != prefixed.len() {
        return Err(format!(
            "short utun write: expected {}, wrote {}",
            prefixed.len(),
            written
        ));
    }
    Ok(())
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
                if let Some(path) = iter.next() {
                    socket_path = Some(PathBuf::from(path));
                }
            }
            "--pid-file" => {
                if let Some(path) = iter.next() {
                    pid_path = Some(PathBuf::from(path));
                }
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
    default_data_dir().join("vpn-helper.pid")
}

fn default_socket_path() -> PathBuf {
    default_data_dir().join(DEFAULT_SOCKET_NAME)
}

fn default_data_dir() -> PathBuf {
    helper_home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".blackhole")
        .join("horizon")
}

fn helper_home_dir() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("HOME") {
        let trimmed = home.trim();
        if !trimmed.is_empty() && !is_root_home(trimmed) {
            return Some(PathBuf::from(trimmed));
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = macos_console_user_home() {
            return Some(home);
        }
    }
    None
}

fn is_root_home(home: &str) -> bool {
    home == "/var/root" || home == "/root"
}

#[cfg(target_os = "macos")]
fn macos_console_user_home() -> Option<PathBuf> {
    use std::os::unix::fs::MetadataExt;

    let uid = std::fs::metadata("/dev/console").ok()?.uid();
    if uid == 0 {
        return None;
    }
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() {
            return None;
        }
        let dir = (*pw).pw_dir;
        if dir.is_null() {
            return None;
        }
        let home = std::ffi::CStr::from_ptr(dir).to_string_lossy();
        if home.is_empty() || is_root_home(home.as_ref()) {
            return None;
        }
        Some(PathBuf::from(home.as_ref()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_prefers_explicit_paths() {
        let parsed = parse_args(vec![
            "--socket".into(),
            "/tmp/custom.sock".into(),
            "--pid-file".into(),
            "/tmp/custom.pid".into(),
        ]);
        assert_eq!(parsed.socket_path, PathBuf::from("/tmp/custom.sock"));
        assert_eq!(parsed.pid_path, PathBuf::from("/tmp/custom.pid"));
    }

    #[test]
    fn is_root_home_detects_launchd_root() {
        assert!(is_root_home("/var/root"));
        assert!(is_root_home("/root"));
        assert!(!is_root_home("/Users/tester"));
        assert!(!is_root_home("/home/tester"));
    }
}
