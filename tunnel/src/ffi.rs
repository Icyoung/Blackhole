//! C-FFI exports for blackhole-wg.
//!
//! Uses an opaque pointer pattern: the tunnel handle is passed as `*mut c_void`.
//! Configuration is passed as a JSON string to avoid cross-language struct
//! alignment issues.
//!
//! Return codes for encapsulate/decapsulate/update_timers:
//!   0  = Done (no data to send)
//!   1  = WriteToNetwork (send dst[..dst_len] to the peer over UDP)
//!   2  = WriteToTun (write dst[..dst_len] to the TUN device)
//!  -1  = Error

use std::ffi::CStr;
use std::os::raw::c_char;
use std::slice;

use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::WgConfig;
use crate::tunnel::{TunnelResult, TunnelStats, WgTunnel};

const BH_WG_DONE: i32 = 0;
const BH_WG_WRITE_TO_NET: i32 = 1;
const BH_WG_WRITE_TO_TUN: i32 = 2;
const BH_WG_ERR: i32 = -1;

#[repr(C)]
pub struct bh_wg_stats {
    pub time_since_last_handshake_secs: i64,
    pub tx_bytes: u64,
    pub rx_bytes: u64,
    pub estimated_loss: f32,
    pub estimated_rtt_ms: i32,
}

/// Create a new WireGuard tunnel from a JSON configuration string.
///
/// The JSON must deserialize to a `WgConfig` struct.
/// Returns an opaque pointer to the tunnel, or null on error.
///
/// # Safety
/// `config_json` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn bh_wg_tunnel_new(config_json: *const c_char) -> *mut std::ffi::c_void {
    if config_json.is_null() {
        tracing::error!("bh_wg_tunnel_new: config_json is null");
        return std::ptr::null_mut();
    }

    let c_str = match CStr::from_ptr(config_json).to_str() {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("bh_wg_tunnel_new: invalid UTF-8 in config_json: {}", e);
            return std::ptr::null_mut();
        }
    };

    let config: WgConfig = match serde_json::from_str(c_str) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("bh_wg_tunnel_new: failed to parse config JSON: {}", e);
            return std::ptr::null_mut();
        }
    };

    match WgTunnel::new(&config) {
        Ok(tunnel) => {
            let boxed = Box::new(tunnel);
            Box::into_raw(boxed) as *mut std::ffi::c_void
        }
        Err(e) => {
            tracing::error!("bh_wg_tunnel_new: failed to create tunnel: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Free a tunnel previously created with `bh_wg_tunnel_new`.
///
/// # Safety
/// `tunnel` must be a valid pointer returned by `bh_wg_tunnel_new`,
/// or null (in which case this is a no-op).
/// After calling this function, the pointer must not be used again.
#[no_mangle]
pub unsafe extern "C" fn bh_wg_tunnel_free(tunnel: *mut std::ffi::c_void) {
    if !tunnel.is_null() {
        let _ = Box::from_raw(tunnel as *mut WgTunnel);
    }
}

/// Encapsulate a plaintext IP packet into a WireGuard packet.
///
/// # Safety
/// - `tunnel` must be a valid pointer from `bh_wg_tunnel_new`.
/// - `src` must point to at least `src_len` readable bytes.
/// - `dst` must point to at least `*dst_len` writable bytes.
/// - `dst_len` is an in/out parameter: on entry it holds the buffer capacity,
///   on exit it holds the number of bytes written.
///
/// Returns: 0=Done, 1=WriteToNetwork, 2=WriteToTun, -1=Error
#[no_mangle]
pub unsafe extern "C" fn bh_wg_encapsulate(
    tunnel: *mut std::ffi::c_void,
    src: *const u8,
    src_len: usize,
    dst: *mut u8,
    dst_len: *mut usize,
) -> i32 {
    if tunnel.is_null() || src.is_null() || dst.is_null() || dst_len.is_null() {
        return BH_WG_ERR;
    }

    let tun = &mut *(tunnel as *mut WgTunnel);
    let src_slice = slice::from_raw_parts(src, src_len);
    let dst_cap = *dst_len;
    let dst_slice = slice::from_raw_parts_mut(dst, dst_cap);

    match tun.encapsulate(src_slice, dst_slice) {
        Ok(result) => map_result_to_ffi(result, dst_len),
        Err(e) => {
            tracing::error!("bh_wg_encapsulate: {}", e);
            *dst_len = 0;
            BH_WG_ERR
        }
    }
}

/// Decapsulate a WireGuard packet into a plaintext IP packet.
///
/// # Safety
/// Same requirements as `bh_wg_encapsulate`.
///
/// Returns: 0=Done, 1=WriteToNetwork, 2=WriteToTun, -1=Error
#[no_mangle]
pub unsafe extern "C" fn bh_wg_decapsulate(
    tunnel: *mut std::ffi::c_void,
    src: *const u8,
    src_len: usize,
    dst: *mut u8,
    dst_len: *mut usize,
) -> i32 {
    if tunnel.is_null() || dst.is_null() || dst_len.is_null() {
        return BH_WG_ERR;
    }

    // Allow src == null when src_len == 0 (drain mode).
    if src.is_null() && src_len != 0 {
        return BH_WG_ERR;
    }

    let tun = &mut *(tunnel as *mut WgTunnel);
    let src_slice = if src.is_null() {
        &[]
    } else {
        slice::from_raw_parts(src, src_len)
    };
    let dst_cap = *dst_len;
    let dst_slice = slice::from_raw_parts_mut(dst, dst_cap);

    match tun.decapsulate(src_slice, dst_slice) {
        Ok(result) => map_result_to_ffi(result, dst_len),
        Err(e) => {
            tracing::error!("bh_wg_decapsulate: {}", e);
            *dst_len = 0;
            BH_WG_ERR
        }
    }
}

/// Tick the tunnel's internal timers (keepalive, handshake retry, etc.).
///
/// # Safety
/// - `tunnel` must be a valid pointer from `bh_wg_tunnel_new`.
/// - `dst` must point to at least `*dst_len` writable bytes.
/// - `dst_len` is in/out: capacity on entry, bytes written on exit.
///
/// Returns: 0=Done, 1=WriteToNetwork, 2=WriteToTun, -1=Error
#[no_mangle]
pub unsafe extern "C" fn bh_wg_update_timers(
    tunnel: *mut std::ffi::c_void,
    dst: *mut u8,
    dst_len: *mut usize,
) -> i32 {
    if tunnel.is_null() || dst.is_null() || dst_len.is_null() {
        return BH_WG_ERR;
    }

    let tun = &mut *(tunnel as *mut WgTunnel);
    let dst_cap = *dst_len;
    let dst_slice = slice::from_raw_parts_mut(dst, dst_cap);

    match tun.update_timers(dst_slice) {
        Ok(result) => map_result_to_ffi(result, dst_len),
        Err(e) => {
            tracing::error!("bh_wg_update_timers: {}", e);
            *dst_len = 0;
            BH_WG_ERR
        }
    }
}

/// Generate a new X25519 keypair.
///
/// Writes 32 bytes to `pub_out` (public key) and 32 bytes to `priv_out`
/// (private key). Both are raw key bytes (not base64-encoded).
///
/// # Safety
/// Both `pub_out` and `priv_out` must point to at least 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn bh_wg_generate_keypair(pub_out: *mut u8, priv_out: *mut u8) {
    if pub_out.is_null() || priv_out.is_null() {
        return;
    }

    let secret = StaticSecret::random_from_rng(rand::thread_rng());
    let public = PublicKey::from(&secret);

    let pub_slice = slice::from_raw_parts_mut(pub_out, 32);
    let priv_slice = slice::from_raw_parts_mut(priv_out, 32);

    pub_slice.copy_from_slice(public.as_bytes());
    priv_slice.copy_from_slice(&secret.to_bytes());
}

/// Fetch a snapshot of tunnel statistics.
///
/// Returns 1 on success and 0 on invalid input.
///
/// # Safety
/// - `tunnel` must be a valid pointer from `bh_wg_tunnel_new`.
/// - `out_stats` must point to writable memory for one `bh_wg_stats`.
#[no_mangle]
pub unsafe extern "C" fn bh_wg_get_stats(
    tunnel: *mut std::ffi::c_void,
    out_stats: *mut bh_wg_stats,
) -> i32 {
    if tunnel.is_null() || out_stats.is_null() {
        return 0;
    }

    let tun = &*(tunnel as *mut WgTunnel);
    let TunnelStats {
        time_since_last_handshake_secs,
        tx_bytes,
        rx_bytes,
        estimated_loss,
        estimated_rtt_ms,
    } = tun.stats();

    *out_stats = bh_wg_stats {
        time_since_last_handshake_secs: time_since_last_handshake_secs
            .map(|value| value as i64)
            .unwrap_or(-1),
        tx_bytes,
        rx_bytes,
        estimated_loss,
        estimated_rtt_ms: estimated_rtt_ms.map(|value| value as i32).unwrap_or(-1),
    };
    1
}

/// Force the tunnel to emit an initial handshake packet.
///
/// # Safety
/// - `tunnel` must be a valid pointer from `bh_wg_tunnel_new`.
/// - `dst` must point to at least `*dst_len` writable bytes.
/// - `dst_len` is in/out: capacity on entry, bytes written on exit.
#[no_mangle]
pub unsafe extern "C" fn bh_wg_force_handshake(
    tunnel: *mut std::ffi::c_void,
    dst: *mut u8,
    dst_len: *mut usize,
) -> i32 {
    if tunnel.is_null() || dst.is_null() || dst_len.is_null() {
        return BH_WG_ERR;
    }

    let tun = &mut *(tunnel as *mut WgTunnel);
    let dst_cap = *dst_len;
    let dst_slice = slice::from_raw_parts_mut(dst, dst_cap);

    match tun.force_handshake(dst_slice) {
        Ok(result) => map_result_to_ffi(result, dst_len),
        Err(e) => {
            tracing::error!("bh_wg_force_handshake: {}", e);
            *dst_len = 0;
            BH_WG_ERR
        }
    }
}

/// Map our TunnelResult to FFI return code and update dst_len.
fn map_result_to_ffi(result: TunnelResult, dst_len: *mut usize) -> i32 {
    unsafe {
        match result {
            TunnelResult::Done => {
                *dst_len = 0;
                BH_WG_DONE
            }
            TunnelResult::Err(e) => {
                tracing::error!("tunnel error: {}", e);
                *dst_len = 0;
                BH_WG_ERR
            }
            TunnelResult::WriteToNetwork(n) => {
                *dst_len = n;
                BH_WG_WRITE_TO_NET
            }
            TunnelResult::WriteToTun(n) => {
                *dst_len = n;
                BH_WG_WRITE_TO_TUN
            }
        }
    }
}
