use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use boringtun::noise::{Tunn, TunnResult};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::WgConfig;

/// Result type for tunnel encapsulate/decapsulate operations.
/// Maps boringtun's internal TunnResult to a simpler enum.
#[derive(Debug)]
pub enum TunnelResult {
    /// No data to send.
    Done,
    /// An error occurred.
    Err(String),
    /// Data was written to dst and should be sent over the network to the peer.
    WriteToNetwork(usize),
    /// Data was written to dst and should be written to the TUN device.
    WriteToTun(usize),
}

#[derive(Debug, Clone, Copy, Default)]
pub struct TunnelStats {
    pub time_since_last_handshake_secs: Option<u64>,
    pub tx_bytes: u64,
    pub rx_bytes: u64,
    pub estimated_loss: f32,
    pub estimated_rtt_ms: Option<u32>,
}

/// Wrapper around boringtun's Tunn.
///
/// This performs no socket I/O — it only transforms packets between
/// plaintext IP format and encrypted WireGuard format.
pub struct WgTunnel {
    tunn: Box<Tunn>,
}

impl WgTunnel {
    /// Create a new WireGuard tunnel from the given configuration.
    pub fn new(config: &WgConfig) -> Result<Self, String> {
        let private_key_bytes = BASE64
            .decode(&config.private_key)
            .map_err(|e| format!("invalid private key base64: {}", e))?;
        if private_key_bytes.len() != 32 {
            return Err(format!(
                "private key must be 32 bytes, got {}",
                private_key_bytes.len()
            ));
        }
        let mut sk_array = [0u8; 32];
        sk_array.copy_from_slice(&private_key_bytes);
        let static_secret = StaticSecret::from(sk_array);

        let peer_public_bytes = BASE64
            .decode(&config.peer_public_key)
            .map_err(|e| format!("invalid peer public key base64: {}", e))?;
        if peer_public_bytes.len() != 32 {
            return Err(format!(
                "peer public key must be 32 bytes, got {}",
                peer_public_bytes.len()
            ));
        }
        let mut pk_array = [0u8; 32];
        pk_array.copy_from_slice(&peer_public_bytes);
        let peer_public = PublicKey::from(pk_array);

        let preshared_key = match &config.preshared_key {
            Some(psk_b64) => {
                let psk_bytes = BASE64
                    .decode(psk_b64)
                    .map_err(|e| format!("invalid preshared key base64: {}", e))?;
                if psk_bytes.len() != 32 {
                    return Err(format!(
                        "preshared key must be 32 bytes, got {}",
                        psk_bytes.len()
                    ));
                }
                let mut psk_array = [0u8; 32];
                psk_array.copy_from_slice(&psk_bytes);
                Some(psk_array)
            }
            None => None,
        };

        let keepalive = config.keepalive_secs;

        let tunn = Tunn::new(
            static_secret,
            peer_public,
            preshared_key,
            keepalive,
            0,
            None,
        )
        .map_err(|e| format!("failed to create tunnel: {}", e))?;

        Ok(Self {
            tunn: Box::new(tunn),
        })
    }

    /// Encapsulate a plaintext IP packet into a WireGuard packet.
    ///
    /// `src` contains the plaintext IP packet to encapsulate.
    /// `dst` is the buffer where the WireGuard-encrypted packet will be written.
    pub fn encapsulate(&mut self, src: &[u8], dst: &mut [u8]) -> Result<TunnelResult, String> {
        let result = self.tunn.encapsulate(src, dst);
        Ok(map_tunn_result(result))
    }

    /// Decapsulate a WireGuard packet into a plaintext IP packet.
    ///
    /// `src` contains the WireGuard-encrypted packet received from the network.
    /// `dst` is the buffer where the decrypted IP packet will be written.
    pub fn decapsulate(&mut self, src: &[u8], dst: &mut [u8]) -> Result<TunnelResult, String> {
        let result = self.tunn.decapsulate(None, src, dst);
        Ok(map_tunn_result(result))
    }

    /// Tick the internal timers (keepalive, handshake retry, etc.).
    ///
    /// `dst` is a buffer for any packet that needs to be sent as a result
    /// of the timer tick (e.g., a keepalive or handshake initiation).
    pub fn update_timers(&mut self, dst: &mut [u8]) -> Result<TunnelResult, String> {
        let result = self.tunn.update_timers(dst);
        Ok(map_tunn_result(result))
    }

    /// Return a compact snapshot of tunnel health for FFI consumers.
    pub fn stats(&self) -> TunnelStats {
        let (time, tx_bytes, rx_bytes, estimated_loss, estimated_rtt_ms) = self.tunn.stats();
        TunnelStats {
            time_since_last_handshake_secs: time.map(|duration| duration.as_secs()),
            tx_bytes: tx_bytes as u64,
            rx_bytes: rx_bytes as u64,
            estimated_loss,
            estimated_rtt_ms,
        }
    }

    /// Force an immediate handshake initiation packet.
    pub fn force_handshake(&mut self, dst: &mut [u8]) -> Result<TunnelResult, String> {
        Ok(map_tunn_result(
            self.tunn.format_handshake_initiation(dst, true),
        ))
    }
}

/// Map boringtun's TunnResult to our TunnelResult.
fn map_tunn_result(result: TunnResult) -> TunnelResult {
    match result {
        TunnResult::Done => TunnelResult::Done,
        TunnResult::Err(e) => TunnelResult::Err(format!("{:?}", e)),
        TunnResult::WriteToNetwork(buf) => TunnelResult::WriteToNetwork(buf.len()),
        TunnResult::WriteToTunnelV4(buf, _) => TunnelResult::WriteToTun(buf.len()),
        TunnResult::WriteToTunnelV6(buf, _) => TunnelResult::WriteToTun(buf.len()),
    }
}
