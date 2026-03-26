use std::net::SocketAddr;
use std::time::{Duration, Instant};

/// States of the NAT hole-punching state machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HolePunchState {
    /// No hole-punch attempt in progress.
    Idle,
    /// Exchanging endpoint information via the Wormhole signaling channel.
    Signaling,
    /// Sending WireGuard handshake packets to the peer's public address.
    Probing,
    /// Hole punch succeeded; using direct UDP communication.
    DirectOk,
    /// Hole punch failed; falling back to Wormhole relay.
    RelayFallback,
}

/// NAT hole-punching state machine.
///
/// Manages the lifecycle of a hole-punch attempt:
/// 1. **Signaling** — exchange endpoint info via Wormhole
/// 2. **Probing** — send WG handshakes directly to peer's public endpoint
/// 3. **DirectOk** — direct path established
/// 4. **RelayFallback** — probe timed out, use relay; periodically retry direct
pub struct HolePunchMachine {
    state: HolePunchState,
    local_addr: Option<SocketAddr>,
    peer_public_addr: Option<SocketAddr>,
    peer_local_addrs: Vec<SocketAddr>,
    probe_started_at: Option<Instant>,
    probe_timeout: Duration,
    last_retry_at: Option<Instant>,
    retry_interval: Duration,
}

impl HolePunchMachine {
    /// Create a new hole-punch machine in the Idle state.
    ///
    /// Default probe timeout is 3 seconds; default retry interval is 30 seconds.
    pub fn new() -> Self {
        Self {
            state: HolePunchState::Idle,
            local_addr: None,
            peer_public_addr: None,
            peer_local_addrs: Vec::new(),
            probe_started_at: None,
            probe_timeout: Duration::from_secs(3),
            last_retry_at: None,
            retry_interval: Duration::from_secs(30),
        }
    }

    /// Get a reference to the current state.
    pub fn state(&self) -> &HolePunchState {
        &self.state
    }

    /// Get the local address, if set.
    pub fn local_addr(&self) -> Option<SocketAddr> {
        self.local_addr
    }

    /// Set the local address (our own externally-visible endpoint).
    pub fn set_local_addr(&mut self, addr: SocketAddr) {
        self.local_addr = Some(addr);
    }

    /// Get the peer's public address, if known.
    pub fn peer_public_addr(&self) -> Option<SocketAddr> {
        self.peer_public_addr
    }

    /// Get the peer's local (LAN) addresses.
    pub fn peer_local_addrs(&self) -> &[SocketAddr] {
        &self.peer_local_addrs
    }

    /// Transition from Idle to Signaling.
    /// Call this when starting the endpoint exchange via Wormhole.
    pub fn start_signaling(&mut self) {
        self.state = HolePunchState::Signaling;
        self.peer_public_addr = None;
        self.peer_local_addrs.clear();
        self.probe_started_at = None;
        self.last_retry_at = None;
    }

    /// Record the peer's endpoints received during signaling.
    ///
    /// `public` is the peer's externally-visible (STUN / relay-reported) address.
    /// `local` is a list of the peer's LAN addresses for same-network optimization.
    pub fn set_peer_endpoints(&mut self, public: SocketAddr, local: Vec<SocketAddr>) {
        self.peer_public_addr = Some(public);
        self.peer_local_addrs = local;
    }

    /// Transition from Signaling to Probing.
    /// Call this once endpoint exchange is complete and we are ready to
    /// send WireGuard handshake probes directly to the peer.
    pub fn start_probing(&mut self) {
        self.state = HolePunchState::Probing;
        self.probe_started_at = Some(Instant::now());
    }

    /// Mark the probe as successful — direct UDP path is established.
    /// Transitions to DirectOk.
    pub fn probe_succeeded(&mut self) {
        self.state = HolePunchState::DirectOk;
        self.probe_started_at = None;
    }

    /// Check if the probe has exceeded its timeout.
    ///
    /// If the timeout has elapsed, automatically transitions to RelayFallback
    /// and returns `true`. Otherwise returns `false`.
    pub fn probe_timed_out(&mut self) -> bool {
        if self.state != HolePunchState::Probing {
            return false;
        }
        if let Some(started) = self.probe_started_at {
            if started.elapsed() >= self.probe_timeout {
                self.state = HolePunchState::RelayFallback;
                self.probe_started_at = None;
                self.last_retry_at = Some(Instant::now());
                return true;
            }
        }
        false
    }

    /// Check if we should retry a direct connection.
    ///
    /// Returns `true` when in RelayFallback state and the retry interval
    /// has elapsed since the last retry attempt (or since entering RelayFallback).
    pub fn should_retry_direct(&self) -> bool {
        if self.state != HolePunchState::RelayFallback {
            return false;
        }
        match self.last_retry_at {
            Some(last) => last.elapsed() >= self.retry_interval,
            None => true,
        }
    }

    /// Transition back to Probing from RelayFallback for a retry attempt.
    /// Resets the probe timer and updates the last retry timestamp.
    pub fn start_retry(&mut self) {
        if self.state == HolePunchState::RelayFallback {
            self.state = HolePunchState::Probing;
            self.probe_started_at = Some(Instant::now());
            self.last_retry_at = Some(Instant::now());
        }
    }
}

impl Default for HolePunchMachine {
    fn default() -> Self {
        Self::new()
    }
}
