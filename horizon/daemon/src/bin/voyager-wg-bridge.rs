//! Minimal WireGuard client bridge for Voyager macOS.
//!
//! Connects to horizon-vpn-helper to obtain a TUN device, then bridges
//! TUN ↔ WG encap/decap ↔ UDP to a Horizon WG server.
//!
//! Usage:
//!   voyager-wg-bridge \
//!     --helper-socket /tmp/vpn-helper.sock \
//!     --server-addr 192.168.1.219 \
//!     --server-port 51820 \
//!     --private-key <base64> \
//!     --peer-public-key <base64> \
//!     --client-ip 10.13.37.4 \
//!     --server-ip 10.13.37.1

#[path = "../dns_forwarder.rs"]
mod dns_forwarder;
#[path = "../nat.rs"]
mod nat;
#[path = "../tun_device.rs"]
mod tun_device;
#[path = "../vpn_helper_client.rs"]
mod vpn_helper_client;
#[path = "../vpn_helper_protocol.rs"]
mod vpn_helper_protocol;

use std::net::UdpSocket;
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::PathBuf;
use std::{env, fs, io, thread};
use tracing::{error, info};

fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let args: Vec<String> = env::args().collect();
    let get = |name: &str| -> String {
        let pos = args.iter().position(|a| a == name).unwrap_or_else(|| {
            eprintln!("missing {name}");
            std::process::exit(1);
        });
        args.get(pos + 1).cloned().unwrap_or_else(|| {
            eprintln!("missing value for {name}");
            std::process::exit(1);
        })
    };

    let helper_socket = get("--helper-socket");
    let server_addr = get("--server-addr");
    let server_port: u16 = get("--server-port").parse().expect("invalid port");
    let private_key = get("--private-key");
    let peer_public_key = get("--peer-public-key");
    let client_ip = get("--client-ip");
    let server_ip = get("--server-ip");

    // Connect to helper and get TUN
    let data_dir = PathBuf::from(helper_socket).parent().unwrap().to_path_buf();
    let prepared = vpn_helper_client::start_vpn(
        &data_dir,
        &server_ip,
        "10.13.37.0/24",
        "255.255.255.0",
        9527,
    )
    .expect("failed to start VPN via helper");

    info!("TUN device: {} (fd={})", prepared.tun.name, prepared.tun.fd);

    // Configure TUN IP address
    let status = std::process::Command::new("ifconfig")
        .args([
            &prepared.tun.name,
            &client_ip,
            &server_ip,
            "netmask",
            "255.255.255.0",
            "up",
        ])
        .status();
    if let Ok(s) = status {
        if !s.success() {
            error!("ifconfig failed (might need sudo for IP assignment)");
        }
    }

    // Add route
    let _ = std::process::Command::new("route")
        .args([
            "add",
            "-net",
            "10.13.37.0/24",
            "-interface",
            &prepared.tun.name,
        ])
        .status();

    // Create WG tunnel
    let config_json = serde_json::json!({
        "private_key": private_key,
        "peer_public_key": peer_public_key,
    });
    let config_str = config_json.to_string();
    let tunnel = unsafe {
        let ptr =
            tunnel_ffi::bh_wg_tunnel_new(std::ffi::CString::new(config_str).unwrap().as_ptr());
        assert!(!ptr.is_null(), "failed to create WG tunnel");
        ptr
    };

    // Bind UDP socket
    let udp = UdpSocket::bind("0.0.0.0:0").expect("bind UDP");
    udp.connect(format!("{server_addr}:{server_port}"))
        .expect("connect UDP");
    info!("UDP connected to {server_addr}:{server_port}");

    // Send initial handshake
    let mut buf = vec![0u8; 2048];
    let mut len = buf.len();
    let r = unsafe {
        tunnel_ffi::bh_wg_update_timers(tunnel, buf.as_mut_ptr(), &mut len as *mut usize)
    };
    if r == 1 && len > 0 {
        let _ = udp.send(&buf[..len]);
        info!("sent initial handshake");
    }

    // Spawn TUN→WG→UDP thread
    let tun_fd = prepared.tun.fd;
    let udp_send = udp.try_clone().expect("clone UDP");
    let tunnel_ptr = tunnel as usize; // safe to send across threads
    thread::spawn(move || {
        let tunnel = tunnel_ptr as *mut std::ffi::c_void;
        let mut pkt = vec![0u8; 2048];
        let mut enc = vec![0u8; 2048 + 80];
        loop {
            let n = unsafe { libc::read(tun_fd, pkt.as_mut_ptr() as _, pkt.len()) };
            if n <= 0 {
                thread::sleep(std::time::Duration::from_millis(1));
                continue;
            }
            let mut enc_len = enc.len();
            let r = unsafe {
                tunnel_ffi::bh_wg_encapsulate(
                    tunnel,
                    pkt.as_ptr(),
                    n as usize,
                    enc.as_mut_ptr(),
                    &mut enc_len as *mut usize,
                )
            };
            if r == 1 && enc_len > 0 {
                let _ = udp_send.send(&enc[..enc_len]);
            }
        }
    });

    // Spawn timer thread
    let udp_timer = udp.try_clone().expect("clone UDP timer");
    let tunnel_ptr2 = tunnel as usize;
    thread::spawn(move || {
        let tunnel = tunnel_ptr2 as *mut std::ffi::c_void;
        let mut buf = vec![0u8; 2048];
        loop {
            thread::sleep(std::time::Duration::from_millis(250));
            let mut len = buf.len();
            let r = unsafe {
                tunnel_ffi::bh_wg_update_timers(tunnel, buf.as_mut_ptr(), &mut len as *mut usize)
            };
            if r == 1 && len > 0 {
                let _ = udp_timer.send(&buf[..len]);
            }
        }
    });

    // Main thread: UDP→WG→TUN
    let mut pkt = vec![0u8; 2048 + 80];
    let mut dec = vec![0u8; 2048];
    loop {
        let n = match udp.recv(&mut pkt) {
            Ok(n) => n,
            Err(_) => continue,
        };
        let mut dec_len = dec.len();
        let r = unsafe {
            tunnel_ffi::bh_wg_decapsulate(
                tunnel,
                pkt.as_ptr(),
                n,
                dec.as_mut_ptr(),
                &mut dec_len as *mut usize,
            )
        };
        if r == 2 && dec_len > 0 {
            // WRITE_TO_TUN
            unsafe { libc::write(tun_fd, dec.as_ptr() as _, dec_len) };
        } else if r == 1 && dec_len > 0 {
            // WRITE_TO_NET (handshake response)
            let _ = udp.send(&dec[..dec_len]);
            // Drain buffered
            loop {
                let mut d2 = vec![0u8; 2048];
                let mut d2_len = d2.len();
                let r2 = unsafe {
                    tunnel_ffi::bh_wg_decapsulate(
                        tunnel,
                        std::ptr::null(),
                        0,
                        d2.as_mut_ptr(),
                        &mut d2_len as *mut usize,
                    )
                };
                if r2 == 2 && d2_len > 0 {
                    unsafe { libc::write(tun_fd, d2.as_ptr() as _, d2_len) };
                } else if r2 == 1 && d2_len > 0 {
                    let _ = udp.send(&d2[..d2_len]);
                } else {
                    break;
                }
            }
        }
    }
}

// FFI bindings — link against libblackhole_wg
mod tunnel_ffi {
    extern "C" {
        pub fn bh_wg_tunnel_new(config_json: *const std::ffi::c_char) -> *mut std::ffi::c_void;
        pub fn bh_wg_encapsulate(
            tunnel: *mut std::ffi::c_void,
            src: *const u8,
            src_len: usize,
            dst: *mut u8,
            dst_len: *mut usize,
        ) -> i32;
        pub fn bh_wg_decapsulate(
            tunnel: *mut std::ffi::c_void,
            src: *const u8,
            src_len: usize,
            dst: *mut u8,
            dst_len: *mut usize,
        ) -> i32;
        pub fn bh_wg_update_timers(
            tunnel: *mut std::ffi::c_void,
            dst: *mut u8,
            dst_len: *mut usize,
        ) -> i32;
    }
}
