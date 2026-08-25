use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
#[cfg(unix)]
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::tun_device::TunTransport;
use tunnel::{IpPool, TunnelResult, WgConfig, WgTunnel};

#[cfg(not(unix))]
type RawFd = i32;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default WireGuard listen port.
const DEFAULT_PORT: u16 = 51820;

/// Buffer size for packet read/write operations (bytes).
const BUF_SIZE: usize = 2048;

/// Server IP inside the VPN subnet (10.13.37.1).
const SERVER_IP: Ipv4Addr = Ipv4Addr::new(10, 13, 37, 1);

/// VPN subnet in CIDR notation.
const SUBNET: &str = "10.13.37.0/24";

/// Default MTU advertised to clients.
const MTU: u16 = 1420;

/// Timer tick interval for WireGuard keepalives / handshake retries.
const TIMER_TICK: Duration = Duration::from_millis(250);
const DIRECT_PROBE_INTERVAL: Duration = Duration::from_secs(1);
const DIRECT_PROBE_WINDOW: Duration = Duration::from_secs(30);

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Information returned to a client after a successful peer addition.
pub struct VpnAssignment {
    pub client_ip: String,
    pub server_ip: String,
    pub subnet: String,
    pub dns: Vec<String>,
    pub mtu: u16,
}

/// A single connected WireGuard peer.
pub struct WgPeer {
    pub tunnel: WgTunnel,
    pub public_key: String,
    pub addr: SocketAddr,
    pub candidate_endpoints: Vec<SocketAddr>,
    pub device_key: Option<String>,
    pub client_ip: Ipv4Addr,
    pub direct_probe_until: Option<Instant>,
    pub next_direct_probe_at: Instant,
}

/// WireGuard server that manages peers, the UDP transport, and TUN I/O.
///
/// This struct is self-contained and does **not** reference `AppState` directly.
/// The daemon wires it into the broader application by calling [`WgServer::new`]
/// and [`WgServer::run`] from an appropriate task.
pub struct WgServer {
    private_key: String,
    /// Primary peer storage, keyed by WireGuard public key.
    peers: HashMap<String, WgPeer>,
    /// Reverse lookup: socket address → public key (for UDP dispatch).
    addr_to_pubkey: HashMap<SocketAddr, String>,
    ip_pool: IpPool,
    udp: Arc<UdpSocket>,
    tun_fd: RawFd,
    tun_transport: TunTransport,
    server_ip: Ipv4Addr,
}

enum InboundPacket {
    KnownPeer {
        public_key: String,
        result: TunnelResult,
    },
    Unknown,
}

impl Drop for WgServer {
    fn drop(&mut self) {
        #[cfg(unix)]
        if self.tun_fd >= 0 {
            unsafe {
                libc::close(self.tun_fd);
            }
            self.tun_fd = -1;
        }
    }
}

// ---------------------------------------------------------------------------
// Async TUN helpers (unix only)
// ---------------------------------------------------------------------------

/// Wrapper around a raw TUN file descriptor that implements async read/write
/// via `tokio::io::unix::AsyncFd`.
#[cfg(unix)]
struct AsyncTun {
    inner: tokio::io::unix::AsyncFd<TunRawFd>,
    transport: TunTransport,
}

/// Newtype so we can implement `AsRawFd` without orphan-rule issues.
#[cfg(unix)]
struct TunRawFd(RawFd);

#[cfg(unix)]
impl std::os::unix::io::AsRawFd for TunRawFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

#[cfg(unix)]
impl AsyncTun {
    fn new(fd: RawFd, transport: TunTransport) -> Result<Self, String> {
        let async_fd = tokio::io::unix::AsyncFd::new(TunRawFd(fd))
            .map_err(|e| format!("failed to register TUN fd with tokio: {e}"))?;
        Ok(Self {
            inner: async_fd,
            transport,
        })
    }

    /// Read a packet from the TUN device into `buf`.
    /// Returns the number of IP packet bytes read, or an error.
    ///
    /// On macOS, utun prepends a 4-byte protocol header (AF_INET / AF_INET6).
    /// We strip this header so the caller receives a raw IP packet.
    async fn read(&self, buf: &mut [u8]) -> Result<usize, String> {
        loop {
            let mut guard = self
                .inner
                .readable()
                .await
                .map_err(|e| format!("tun readable wait: {e}"))?;

            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        buf.as_mut_ptr() as *mut libc::c_void,
                        buf.len(),
                    )
                };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(result) => {
                    let n = result.map_err(|e| format!("tun read: {e}"))?;
                    #[cfg(target_os = "macos")]
                    if self.transport == TunTransport::NativeTun {
                        // Strip the 4-byte AF header that macOS utun prepends.
                        if n <= 4 {
                            return Ok(0);
                        }
                        buf.copy_within(4..n, 0);
                        return Ok(n - 4);
                    }
                    return Ok(n);
                }
                Err(_would_block) => continue,
            }
        }
    }

    /// Write a packet to the TUN device from `buf`.
    /// Returns the number of bytes written, or an error.
    ///
    /// On macOS, utun expects a 4-byte AF header before the IP packet.
    /// We prepend AF_INET (2) or AF_INET6 (30) based on the IP version.
    async fn write(&self, buf: &[u8]) -> Result<usize, String> {
        #[cfg(target_os = "macos")]
        let prefixed_write_buf = if self.transport == TunTransport::NativeTun {
            if buf.is_empty() {
                return Ok(0);
            }
            // Determine AF from IP version nibble
            let af: u32 = if (buf[0] >> 4) == 6 {
                libc::AF_INET6 as u32
            } else {
                libc::AF_INET as u32
            };
            let mut prefixed = Vec::with_capacity(4 + buf.len());
            prefixed.extend_from_slice(&af.to_be_bytes());
            prefixed.extend_from_slice(buf);
            Some(prefixed)
        } else {
            None
        };

        loop {
            let mut guard = self
                .inner
                .writable()
                .await
                .map_err(|e| format!("tun writable wait: {e}"))?;

            #[cfg(target_os = "macos")]
            let data = prefixed_write_buf.as_deref().unwrap_or(buf);
            #[cfg(not(target_os = "macos"))]
            let data = buf;

            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        data.as_ptr() as *const libc::c_void,
                        data.len(),
                    )
                };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(result) => return result.map_err(|e| format!("tun write: {e}")),
                Err(_would_block) => continue,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// WgServer implementation
// ---------------------------------------------------------------------------

impl WgServer {
    fn is_direct_probe_window_active(peer: &WgPeer, now: Instant) -> bool {
        peer.direct_probe_until
            .is_some_and(|deadline| now <= deadline)
    }

    fn preferred_endpoint(
        endpoint: Option<SocketAddr>,
        candidate_endpoints: &[SocketAddr],
    ) -> Option<SocketAddr> {
        endpoint.or_else(|| candidate_endpoints.first().copied())
    }

    fn remove_peer_internal(&mut self, peer_public_key: &str, release_ip: bool) {
        if let Some(peer) = self.peers.remove(peer_public_key) {
            self.addr_to_pubkey.remove(&peer.addr);
            if release_ip {
                if let Some(dk) = &peer.device_key {
                    self.ip_pool.release(dk);
                } else {
                    self.ip_pool.release(peer_public_key);
                }
            }
            info!(
                peer_public_key = peer_public_key,
                client_ip = %peer.client_ip,
                release_ip = release_ip,
                "removed WireGuard peer"
            );
        }
    }

    /// Create a new WireGuard server.
    ///
    /// * `private_key` - Base64-encoded X25519 private key for this server.
    /// * `listen_port` - UDP port to listen on. Pass `0` to use [`DEFAULT_PORT`].
    /// * `tun_fd`      - Raw file descriptor of an already-opened TUN device or helper-backed packet socket.
    pub async fn new(
        private_key: String,
        listen_port: u16,
        tun_fd: RawFd,
        tun_transport: TunTransport,
    ) -> Result<Self, String> {
        let port = if listen_port == 0 {
            DEFAULT_PORT
        } else {
            listen_port
        };

        let bind_addr: SocketAddr = format!("0.0.0.0:{port}")
            .parse()
            .map_err(|e| format!("invalid bind address: {e}"))?;

        let udp = UdpSocket::bind(bind_addr)
            .await
            .map_err(|e| format!("failed to bind UDP socket on port {port}: {e}"))?;

        info!(port = port, "WireGuard server listening on UDP");

        Ok(Self {
            private_key,
            peers: HashMap::new(),
            addr_to_pubkey: HashMap::new(),
            ip_pool: IpPool::new(),
            udp: Arc::new(udp),
            tun_fd,
            tun_transport,
            server_ip: SERVER_IP,
        })
    }

    /// Return the actual local UDP address the server is bound to.
    pub fn local_addr(&self) -> Result<SocketAddr, String> {
        self.udp
            .local_addr()
            .map_err(|e| format!("failed to get local addr: {e}"))
    }

    /// Return the server's IP inside the VPN subnet.
    pub fn server_ip(&self) -> Ipv4Addr {
        self.server_ip
    }

    /// Add a peer by WireGuard public key, allocate a VPN IP, and return the
    /// assignment details the client needs to configure its interface.
    ///
    /// * `peer_public_key` - Base64-encoded X25519 public key of the peer.
    /// * `device_key`      - Optional opaque identifier used for IP-pool persistence.
    /// * `endpoint`        - Optional known UDP endpoint of the peer (if behind NAT,
    ///                       this may be updated when the first packet arrives).
    pub fn add_peer(
        &mut self,
        peer_public_key: &str,
        device_key: Option<&str>,
        endpoint: Option<SocketAddr>,
        candidate_endpoints: &[SocketAddr],
    ) -> Result<VpnAssignment, String> {
        // If this public key is already registered, return the existing assignment.
        if let Some(peer) = self.peers.get_mut(peer_public_key) {
            let mut merged_candidates = peer.candidate_endpoints.clone();
            for candidate in candidate_endpoints {
                if !merged_candidates.contains(candidate) {
                    merged_candidates.push(*candidate);
                }
            }
            if let Some(preferred) = endpoint.or_else(|| merged_candidates.first().copied()) {
                self.addr_to_pubkey.remove(&peer.addr);
                peer.addr = preferred;
                self.addr_to_pubkey
                    .insert(preferred, peer.public_key.clone());
            }
            peer.candidate_endpoints = merged_candidates;
            peer.direct_probe_until = Some(Instant::now() + DIRECT_PROBE_WINDOW);
            peer.next_direct_probe_at = Instant::now();
            return Ok(VpnAssignment {
                client_ip: peer.client_ip.to_string(),
                server_ip: self.server_ip.to_string(),
                subnet: SUBNET.to_string(),
                dns: vec![self.server_ip.to_string()],
                mtu: MTU,
            });
        }

        // Allocate an IP from the pool.
        let pool_key = device_key.unwrap_or(peer_public_key);
        let client_ip = self
            .ip_pool
            .allocate(pool_key)
            .ok_or_else(|| "IP pool exhausted".to_string())?;

        // Replacing the WireGuard key for the same device should not leave stale
        // peers around with the same VPN IP. Those stale peers make relay/direct
        // routing ambiguous because TUN egress only keys on client_ip.
        if let Some(device_key) = device_key {
            let stale_keys: Vec<String> = self
                .peers
                .iter()
                .filter(|(pk, peer)| {
                    pk.as_str() != peer_public_key && peer.device_key.as_deref() == Some(device_key)
                })
                .map(|(pk, _)| pk.clone())
                .collect();
            if !stale_keys.is_empty() {
                info!(
                    device_key = device_key,
                    replacement_peer_public_key = peer_public_key,
                    stale_peer_count = stale_keys.len(),
                    "removing stale WireGuard peers for device before adding replacement key"
                );
            }
            for stale_key in stale_keys {
                self.remove_peer_internal(&stale_key, false);
            }
        }

        // Create the WireGuard tunnel for this peer.
        let preferred_endpoint = Self::preferred_endpoint(endpoint, candidate_endpoints);
        let config = WgConfig {
            private_key: self.private_key.clone(),
            peer_public_key: peer_public_key.to_string(),
            preshared_key: None,
            keepalive_secs: Some(25),
            endpoint: preferred_endpoint.map(|ep| ep.to_string()),
        };
        let tunnel = WgTunnel::new(&config)?;

        // Use the provided endpoint or a placeholder (updated on first packet).
        let addr = preferred_endpoint
            .unwrap_or_else(|| SocketAddr::new(std::net::IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0));

        let pk = peer_public_key.to_string();
        let peer = WgPeer {
            tunnel,
            public_key: pk.clone(),
            addr,
            candidate_endpoints: candidate_endpoints.to_vec(),
            device_key: device_key.map(|s| s.to_string()),
            client_ip,
            direct_probe_until: Some(Instant::now() + DIRECT_PROBE_WINDOW),
            next_direct_probe_at: Instant::now(),
        };

        // Update reverse lookup if endpoint is known
        if addr.port() != 0 {
            self.addr_to_pubkey.insert(addr, pk.clone());
        }
        self.peers.insert(pk, peer);

        info!(
            peer_public_key = peer_public_key,
            client_ip = %client_ip,
            "added WireGuard peer"
        );

        Ok(VpnAssignment {
            client_ip: client_ip.to_string(),
            server_ip: self.server_ip.to_string(),
            subnet: SUBNET.to_string(),
            dns: vec![self.server_ip.to_string()],
            mtu: MTU,
        })
    }

    /// Remove a peer by its WireGuard public key.
    ///
    /// Releases the allocated VPN IP back to the pool.
    pub fn remove_peer(&mut self, peer_public_key: &str) {
        self.remove_peer_internal(peer_public_key, true);
    }

    /// Main event loop. Runs until the provided `CancellationToken`-style
    /// signal or an unrecoverable error. In practice the caller cancels via
    /// `tokio::select!` or dropping the task.
    ///
    /// The loop performs three interleaved operations:
    /// 1. **UDP recv** -- decapsulate incoming WireGuard packets and write
    ///    plaintext IP packets to the TUN device.
    /// 2. **TUN read** -- read plaintext packets from the TUN, route them to
    ///    the correct peer, encapsulate, and send over UDP.
    /// 3. **Timer tick** -- call `update_timers` on every tunnel so keepalives
    ///    and handshake retries are sent on schedule.
    #[cfg(unix)]
    pub async fn run(&mut self) -> Result<(), String> {
        let tun = AsyncTun::new(self.tun_fd, self.tun_transport)?;
        let mut timer = tokio::time::interval(TIMER_TICK);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        let mut udp_buf = [0u8; BUF_SIZE];
        let mut tun_buf = [0u8; BUF_SIZE];
        let mut dst_buf = [0u8; BUF_SIZE];

        info!("WireGuard event loop started");

        loop {
            tokio::select! {
                // ---------------------------------------------------------
                // UDP recv -> decapsulate -> write TUN
                // ---------------------------------------------------------
                result = self.udp.recv_from(&mut udp_buf) => {
                    match result {
                        Ok((n, src_addr)) => {
                            self.handle_udp_packet(&udp_buf[..n], src_addr, &mut dst_buf, &tun).await;
                        }
                        Err(e) => {
                            warn!(error = %e, "UDP recv error");
                        }
                    }
                }

                // ---------------------------------------------------------
                // TUN read -> encapsulate -> send UDP
                // ---------------------------------------------------------
                result = tun.read(&mut tun_buf) => {
                    match result {
                        Ok(n) if n > 0 => {
                            self.handle_tun_packet(&tun_buf[..n], &mut dst_buf).await;
                        }
                        Ok(_) => {
                            // Zero-length read; ignore.
                        }
                        Err(e) => {
                            warn!(error = %e, "TUN read error");
                        }
                    }
                }

                // ---------------------------------------------------------
                // Timer tick -> update timers for each peer
                // ---------------------------------------------------------
                _ = timer.tick() => {
                    self.handle_timer_tick(&mut dst_buf).await;
                }
            }
        }
    }

    /// Same as [`run`] but also listens for peer add/remove commands from
    /// an `mpsc` channel. This allows the HTTP/wormhole layer to dynamically
    /// register peers while the event loop is running.
    #[cfg(unix)]
    pub async fn run_with_peer_commands(
        &mut self,
        mut peer_rx: mpsc::UnboundedReceiver<super::WgPeerCommand>,
    ) -> Result<(), String> {
        let tun = AsyncTun::new(self.tun_fd, self.tun_transport)?;
        let mut timer = tokio::time::interval(TIMER_TICK);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        let mut udp_buf = [0u8; BUF_SIZE];
        let mut tun_buf = [0u8; BUF_SIZE];
        let mut dst_buf = [0u8; BUF_SIZE];

        info!("WireGuard event loop started (with peer commands)");

        loop {
            tokio::select! {
                result = self.udp.recv_from(&mut udp_buf) => {
                    match result {
                        Ok((n, src_addr)) => {
                            self.handle_udp_packet(&udp_buf[..n], src_addr, &mut dst_buf, &tun).await;
                        }
                        Err(e) => {
                            warn!(error = %e, "UDP recv error");
                        }
                    }
                }

                result = tun.read(&mut tun_buf) => {
                    match result {
                        Ok(n) if n > 0 => {
                            self.handle_tun_packet(&tun_buf[..n], &mut dst_buf).await;
                        }
                        Ok(_) => {}
                        Err(e) => {
                            warn!(error = %e, "TUN read error");
                        }
                    }
                }

                _ = timer.tick() => {
                    self.handle_timer_tick(&mut dst_buf).await;
                }

                cmd = peer_rx.recv() => {
                    match cmd {
                        Some(super::WgPeerCommand::AddPeer { public_key, device_key, endpoint, candidate_endpoints, reply_tx }) => {
                            let result = self.add_peer(
                                &public_key,
                                device_key.as_deref(),
                                endpoint,
                                &candidate_endpoints,
                            );
                            if result.is_ok() {
                                self.kick_peer_handshake(&public_key, &mut dst_buf).await;
                            }
                            let _ = reply_tx.send(result);
                        }
                        None => {
                            // Channel closed — keep running (VPN stays up).
                            info!("peer command channel closed, continuing event loop");
                        }
                    }
                }
            }
        }
    }

    #[cfg(not(unix))]
    pub async fn run_with_peer_commands(
        &mut self,
        _peer_rx: mpsc::UnboundedReceiver<super::WgPeerCommand>,
    ) -> Result<(), String> {
        Err("WireGuard server is not supported on this platform".to_string())
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Process a WireGuard packet received from UDP.
    #[cfg(unix)]
    async fn handle_udp_packet(
        &mut self,
        packet: &[u8],
        src_addr: SocketAddr,
        dst: &mut [u8],
        tun: &AsyncTun,
    ) {
        let inbound = if let Some(pk) = self.addr_to_pubkey.get(&src_addr).cloned() {
            let Some(peer) = self.peers.get_mut(&pk) else {
                return;
            };
            match peer.tunnel.decapsulate(packet, dst) {
                Ok(result) => InboundPacket::KnownPeer {
                    public_key: pk,
                    result,
                },
                Err(error) => {
                    warn!(error = %error, "tunnel decapsulate failed");
                    InboundPacket::Unknown
                }
            }
        } else {
            self.find_peer_for_packet(packet, src_addr, dst)
        };

        let InboundPacket::KnownPeer {
            public_key: pk,
            result,
        } = inbound
        else {
            debug!(src = %src_addr, "dropping UDP packet from unknown peer");
            return;
        };

        let Some(peer) = self.peers.get_mut(&pk) else {
            return;
        };
        let peer_addr = peer.addr;
        if peer.direct_probe_until.take().is_some() {
            info!(
                peer_public_key = %pk,
                peer = %src_addr,
                "accepted direct WireGuard traffic; ending direct probe window"
            );
        }

        match result {
            TunnelResult::WriteToTun(n) => {
                if let Err(e) = tun.write(&dst[..n]).await {
                    warn!(error = %e, "failed to write decapsulated packet to TUN");
                }
            }
            TunnelResult::WriteToNetwork(n) => {
                let _ = peer;
                // Response packet (e.g., handshake response) — send back.
                self.send_network_packet(&dst[..n], Some(peer_addr)).await;
                // The tunnel may have more data queued (e.g., after handshake
                // completion it may immediately produce decrypted buffered data).
                self.drain_tunnel(&pk.clone(), dst, tun).await;
            }
            TunnelResult::Done => {}
            TunnelResult::Err(msg) => {
                debug!(error = %msg, src = %src_addr, "decapsulate error");
            }
        }
    }

    /// Process a WireGuard packet received from the Wormhole relay.
    /// Try every registered peer to find one that can decrypt the packet.
    /// If found, update the peer's endpoint to the new source address and
    /// return the peer's public key.
    fn find_peer_for_packet(
        &mut self,
        packet: &[u8],
        new_addr: SocketAddr,
        dst: &mut [u8],
    ) -> InboundPacket {
        // Collect keys to avoid borrow issues.
        let keys: Vec<String> = self.peers.keys().cloned().collect();

        for pk in keys {
            let Some(peer) = self.peers.get_mut(&pk) else {
                continue;
            };
            match peer.tunnel.decapsulate(packet, dst) {
                Ok(TunnelResult::Done) | Ok(TunnelResult::Err(_)) => continue,
                Ok(result) => {
                    // This peer accepted the packet. Update its endpoint.
                    let old_addr = peer.addr;
                    debug!(
                        old_addr = %old_addr,
                        new_addr = %new_addr,
                        "peer endpoint roamed"
                    );
                    // Remove old reverse mapping and insert new one.
                    self.addr_to_pubkey.remove(&old_addr);
                    peer.addr = new_addr;
                    self.addr_to_pubkey.insert(new_addr, pk.clone());
                    return InboundPacket::KnownPeer {
                        public_key: pk,
                        result,
                    };
                }
                Err(_) => continue,
            }
        }
        InboundPacket::Unknown
    }

    /// After a handshake completes the tunnel may have buffered decrypted
    /// packets. Drain them to the TUN device.
    #[cfg(unix)]
    async fn drain_tunnel(&mut self, peer_pk: &str, dst: &mut [u8], tun: &AsyncTun) {
        // Feed an empty slice to get any queued data.
        let empty: &[u8] = &[];
        loop {
            let Some(peer) = self.peers.get_mut(peer_pk) else {
                return;
            };
            let peer_addr = peer.addr;
            let result = peer.tunnel.decapsulate(empty, dst);
            let _ = peer;
            match result {
                Ok(TunnelResult::WriteToTun(n)) => {
                    if let Err(e) = tun.write(&dst[..n]).await {
                        warn!(error = %e, "drain: failed to write to TUN");
                    }
                }
                Ok(TunnelResult::WriteToNetwork(n)) => {
                    self.send_network_packet(&dst[..n], Some(peer_addr)).await;
                }
                _ => break,
            }
        }
    }

    /// Process a plaintext IP packet read from the TUN device.
    ///
    /// Inspects the destination IPv4 address to find the matching peer,
    /// encapsulates, and sends the encrypted packet over UDP.
    async fn handle_tun_packet(&mut self, packet: &[u8], dst: &mut [u8]) {
        // IPv4: destination address is at bytes 16..20.
        if packet.len() < 20 {
            return;
        }
        let src_ip = Ipv4Addr::new(packet[12], packet[13], packet[14], packet[15]);
        let dest_ip = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);

        // Find the peer that owns this VPN IP.
        let peer_pk = self
            .peers
            .iter()
            .find(|(_, p)| p.client_ip == dest_ip)
            .map(|(pk, _)| pk.clone());

        let Some(pk) = peer_pk else {
            debug!(dest = %dest_ip, "no peer for TUN packet destination");
            return;
        };

        let Some(peer) = self.peers.get_mut(&pk) else {
            return;
        };
        let peer_addr = peer.addr;
        info!(
            src_ip = %src_ip,
            dest_ip = %dest_ip,
            packet_len = packet.len(),
            peer_public_key = %pk,
            client_ip = %peer.client_ip,
            transport = ?self.tun_transport,
            "processing plaintext packet read from TUN"
        );

        match peer.tunnel.encapsulate(packet, dst) {
            Ok(TunnelResult::WriteToNetwork(n)) => {
                info!(
                    src_ip = %src_ip,
                    dest_ip = %dest_ip,
                    plaintext_len = packet.len(),
                    encrypted_len = n,
                    peer_public_key = %pk,
                    client_ip = %peer.client_ip,
                    "encapsulated TUN packet for WireGuard peer"
                );
                let _ = peer;
                self.send_network_packet(&dst[..n], Some(peer_addr)).await;
            }
            Ok(TunnelResult::Done) => {}
            Ok(TunnelResult::Err(msg)) => {
                debug!(error = %msg, "encapsulate error");
            }
            Ok(TunnelResult::WriteToTun(_)) => {
                debug!("unexpected WriteToTun during encapsulate");
            }
            Err(e) => {
                warn!(error = %e, "tunnel encapsulate failed");
            }
        }
    }

    /// Tick timers on every registered tunnel. This drives keepalives and
    /// handshake retransmissions.
    async fn handle_timer_tick(&mut self, dst: &mut [u8]) {
        // Collect keys to avoid mutable borrow conflicts.
        let keys: Vec<String> = self.peers.keys().cloned().collect();
        let now = Instant::now();
        let mut peers_to_probe = Vec::new();
        let mut timer_packets = Vec::new();

        for pk in keys {
            let Some(peer) = self.peers.get_mut(&pk) else {
                continue;
            };
            let peer_addr = peer.addr;
            match peer.tunnel.update_timers(dst) {
                Ok(TunnelResult::WriteToNetwork(n)) => {
                    timer_packets.push((dst[..n].to_vec(), peer_addr));
                }
                Ok(TunnelResult::Done) => {}
                Ok(TunnelResult::Err(msg)) => {
                    debug!(error = %msg, peer = %peer.addr, "timer error");
                }
                Ok(TunnelResult::WriteToTun(_)) => {}
                Err(e) => {
                    warn!(error = %e, "update_timers failed");
                }
            }

            if Self::is_direct_probe_window_active(peer, now) && now >= peer.next_direct_probe_at {
                peer.next_direct_probe_at = now + DIRECT_PROBE_INTERVAL;
                peers_to_probe.push(pk);
            }
        }

        for (packet, peer_addr) in timer_packets {
            self.send_network_packet(&packet, Some(peer_addr)).await;
        }

        for pk in peers_to_probe {
            self.kick_peer_handshake(&pk, dst).await;
        }
    }

    async fn kick_peer_handshake(&mut self, peer_pk: &str, dst: &mut [u8]) {
        let Some(peer) = self.peers.get_mut(peer_pk) else {
            return;
        };
        let direct_targets = if peer.candidate_endpoints.is_empty() {
            if peer.addr.port() != 0 {
                vec![peer.addr]
            } else {
                Vec::new()
            }
        } else {
            peer.candidate_endpoints.clone()
        };
        match peer.tunnel.force_handshake(dst) {
            Ok(TunnelResult::WriteToNetwork(n)) => {
                let packet = dst[..n].to_vec();
                let _ = peer;
                for addr in direct_targets {
                    if let Err(error) = self.udp.send_to(&packet, addr).await {
                        warn!(error = %error, peer = %addr, peer_public_key = peer_pk, "failed to send direct handshake probe");
                    } else {
                        info!(peer = %addr, peer_public_key = peer_pk, "sent direct handshake probe to candidate");
                    }
                }
            }
            Ok(TunnelResult::Done) => {}
            Ok(TunnelResult::Err(msg)) => {
                debug!(peer_public_key = peer_pk, error = %msg, "force_handshake returned protocol error");
            }
            Ok(TunnelResult::WriteToTun(_)) => {
                debug!(
                    peer_public_key = peer_pk,
                    "force_handshake unexpectedly produced plaintext"
                );
            }
            Err(error) => {
                warn!(peer_public_key = peer_pk, error = %error, "failed to force handshake for peer");
            }
        }
    }

    async fn send_network_packet(&self, packet: &[u8], direct_addr: Option<SocketAddr>) {
        if let Some(addr) = direct_addr.filter(|addr| addr.port() != 0) {
            if let Err(e) = self.udp.send_to(packet, addr).await {
                warn!(error = %e, peer = %addr, "failed to send WireGuard packet over UDP");
            }
        } else {
            debug!("dropping WireGuard packet because no direct path is available");
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    use std::os::fd::IntoRawFd;
    use std::os::unix::net::UnixDatagram as StdUnixDatagram;

    use tokio::sync::oneshot;
    use tunnel::generate_keypair;

    fn build_ipv4_packet(src: Ipv4Addr, dst: Ipv4Addr, payload: &[u8]) -> Vec<u8> {
        let total_len = 20 + payload.len();
        let mut packet = vec![0u8; total_len];
        packet[0] = 0x45; // IPv4, header len 20
        packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
        packet[8] = 64; // TTL
        packet[9] = 6; // TCP
        packet[12..16].copy_from_slice(&src.octets());
        packet[16..20].copy_from_slice(&dst.octets());
        packet[20..].copy_from_slice(payload);
        packet
    }

    fn packet_socket_fd() -> RawFd {
        let (server_socket, peer_socket) =
            StdUnixDatagram::pair().expect("failed to create packet socket pair");
        server_socket
            .set_nonblocking(true)
            .expect("failed to set server socket nonblocking");
        peer_socket
            .set_nonblocking(true)
            .expect("failed to set peer socket nonblocking");
        drop(peer_socket);
        server_socket.into_raw_fd()
    }

    async fn build_test_server(private_key: String) -> WgServer {
        let tun_fd = packet_socket_fd();
        let probe_socket = std::net::UdpSocket::bind("127.0.0.1:0")
            .expect("failed to allocate ephemeral UDP port for test");
        let listen_port = probe_socket
            .local_addr()
            .expect("failed to read ephemeral UDP port")
            .port();
        drop(probe_socket);

        WgServer::new(private_key, listen_port, tun_fd, TunTransport::PacketSocket)
            .await
            .expect("failed to create test WG server")
    }

    async fn recv_udp_packet(socket: &tokio::net::UdpSocket) -> Result<Vec<u8>, String> {
        let mut packet = vec![0u8; BUF_SIZE];
        let len = tokio::time::timeout(Duration::from_secs(1), socket.recv(&mut packet))
            .await
            .map_err(|_| "timed out waiting for direct UDP packet".to_string())?
            .map_err(|error| format!("direct UDP recv failed: {error}"))?;
        packet.truncate(len);
        Ok(packet)
    }

    async fn complete_direct_handshake(
        server: &mut WgServer,
        client_socket: &tokio::net::UdpSocket,
        client_addr: SocketAddr,
        client_tunnel: &mut WgTunnel,
        tun: &AsyncTun,
    ) -> Result<(), String> {
        let mut server_dst = [0u8; BUF_SIZE];
        let mut client_dst = [0u8; BUF_SIZE];
        let mut pending_packets = Vec::new();

        match client_tunnel.force_handshake(&mut client_dst)? {
            TunnelResult::WriteToNetwork(n) => pending_packets.push(client_dst[..n].to_vec()),
            other => {
                return Err(format!(
                    "expected forced direct handshake to write network packet, got {:?}",
                    other
                ));
            }
        }

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            while let Some(packet) = pending_packets.pop() {
                server
                    .handle_udp_packet(&packet, client_addr, &mut server_dst, tun)
                    .await;
            }

            if client_tunnel
                .stats()
                .time_since_last_handshake_secs
                .is_some()
            {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err("timed out completing direct handshake".to_string());
            }

            let packet = recv_udp_packet(client_socket).await?;
            match client_tunnel.decapsulate(&packet, &mut client_dst)? {
                TunnelResult::WriteToNetwork(n) => {
                    pending_packets.push(client_dst[..n].to_vec());
                }
                TunnelResult::WriteToTun(_) | TunnelResult::Done => {}
                TunnelResult::Err(error) => {
                    return Err(format!(
                        "client decapsulate failed during direct handshake: {error}"
                    ));
                }
            }
        }
    }

    #[test]
    fn preferred_endpoint_uses_explicit_endpoint_or_first_candidate() {
        let candidate_a: SocketAddr = "127.0.0.1:40001".parse().unwrap();
        let candidate_b: SocketAddr = "127.0.0.1:40002".parse().unwrap();
        let explicit: SocketAddr = "127.0.0.1:49999".parse().unwrap();

        assert_eq!(
            WgServer::preferred_endpoint(None, &[candidate_a, candidate_b]),
            Some(candidate_a)
        );
        assert_eq!(
            WgServer::preferred_endpoint(Some(explicit), &[candidate_a, candidate_b]),
            Some(explicit)
        );
        assert_eq!(WgServer::preferred_endpoint(None, &[]), None);
    }

    #[tokio::test]
    async fn add_peer_refresh_renews_probe_window_and_merges_candidates() {
        let (_, server_private_key) = generate_keypair();
        let (client_public_key, _) = generate_keypair();
        let mut server = build_test_server(server_private_key).await;
        let candidate_a: SocketAddr = "127.0.0.1:40001".parse().unwrap();
        let candidate_b: SocketAddr = "127.0.0.1:40002".parse().unwrap();

        server
            .add_peer(
                &client_public_key,
                Some("voyager-device"),
                Some(candidate_a),
                &[candidate_a],
            )
            .expect("initial add_peer should succeed");
        let (first_deadline, first_next_probe_at) = {
            let peer = server
                .peers
                .get(&client_public_key)
                .expect("peer should exist after initial add");
            (
                peer.direct_probe_until
                    .expect("initial direct probe window"),
                peer.next_direct_probe_at,
            )
        };

        tokio::time::sleep(Duration::from_millis(10)).await;

        server
            .add_peer(
                &client_public_key,
                Some("voyager-device"),
                Some(candidate_b),
                &[candidate_a, candidate_b],
            )
            .expect("refresh add_peer should succeed");

        let peer = server
            .peers
            .get(&client_public_key)
            .expect("peer should remain registered");
        assert_eq!(peer.addr, candidate_b);
        assert_eq!(peer.candidate_endpoints, vec![candidate_a, candidate_b]);
        assert!(
            peer.direct_probe_until
                .expect("refreshed direct probe window")
                > first_deadline
        );
        assert!(peer.next_direct_probe_at > first_next_probe_at);
    }

    #[tokio::test]
    async fn accepted_direct_udp_packet_clears_probe_window() {
        let (server_public_key, server_private_key) = generate_keypair();
        let (client_public_key, client_private_key) = generate_keypair();
        let mut server = build_test_server(server_private_key).await;
        let client_addr: SocketAddr = "127.0.0.1:41001".parse().unwrap();

        server
            .add_peer(
                &client_public_key,
                Some("voyager-device"),
                Some(client_addr),
                &[client_addr],
            )
            .expect("add_peer should succeed");

        let mut client_tunnel = WgTunnel::new(&WgConfig {
            private_key: client_private_key,
            peer_public_key: server_public_key,
            preshared_key: None,
            keepalive_secs: Some(25),
            endpoint: Some(
                server
                    .local_addr()
                    .expect("server local addr should exist")
                    .to_string(),
            ),
        })
        .expect("failed to create client tunnel");
        let mut handshake = [0u8; BUF_SIZE];
        let handshake_len = match client_tunnel
            .force_handshake(&mut handshake)
            .expect("force_handshake should succeed")
        {
            TunnelResult::WriteToNetwork(n) => n,
            other => panic!("expected handshake packet, got {other:?}"),
        };

        let tun_fd = unsafe { libc::dup(server.tun_fd) };
        assert!(tun_fd >= 0, "failed to dup tun fd for test");
        let tun = AsyncTun::new(tun_fd, TunTransport::PacketSocket)
            .expect("failed to create async tun for test");
        let mut dst = [0u8; BUF_SIZE];
        server
            .handle_udp_packet(&handshake[..handshake_len], client_addr, &mut dst, &tun)
            .await;

        let peer = server
            .peers
            .get(&client_public_key)
            .expect("peer should still exist");
        assert!(
            peer.direct_probe_until.is_none(),
            "accepted direct UDP traffic should end the probe window"
        );
    }
}
