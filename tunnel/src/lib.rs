pub mod config;
pub mod ffi;
pub mod holepunch;
pub mod ip_pool;
pub mod tunnel;

pub use config::{VpnConfig, WgConfig};
pub use holepunch::{HolePunchMachine, HolePunchState};
pub use ip_pool::IpPool;
pub use tunnel::{TunnelResult, WgTunnel};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use x25519_dalek::{PublicKey, StaticSecret};

/// Generate a new X25519 keypair.
///
/// Returns `(public_key, private_key)` as base64-encoded strings.
pub fn generate_keypair() -> (String, String) {
    let secret = StaticSecret::random_from_rng(rand::thread_rng());
    let public = PublicKey::from(&secret);

    let pub_b64 = BASE64.encode(public.as_bytes());
    let priv_b64 = BASE64.encode(secret.to_bytes());

    (pub_b64, priv_b64)
}
