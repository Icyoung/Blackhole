use std::process::Command;
use std::sync::Mutex;
use tracing::{info, warn};

/// Stores the VPN subnet so teardown can reference it without the caller re-supplying it.
static ACTIVE_SUBNET: Mutex<Option<String>> = Mutex::new(None);

/// Set up NAT rules for VPN traffic from the given subnet.
/// Returns Ok(()) on success or Err with description.
pub fn setup_nat(
    vpn_subnet: &str,
    outbound_iface: Option<&str>,
    local_ws_redirect: Option<(&str, u16, Option<&str>)>,
) -> Result<(), String> {
    // Store subnet for teardown
    if let Ok(mut s) = ACTIVE_SUBNET.lock() {
        *s = Some(vpn_subnet.to_string());
    }

    #[cfg(target_os = "macos")]
    {
        setup_nat_macos(vpn_subnet, outbound_iface, local_ws_redirect)
    }
    #[cfg(target_os = "linux")]
    {
        let _ = outbound_iface; // unused on Linux; iptables MASQUERADE picks the iface automatically
        let _ = local_ws_redirect;
        setup_nat_linux(vpn_subnet)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = outbound_iface;
        Err("NAT not supported on this platform".to_string())
    }
}

/// Drop the local WebSocket rdr while keeping masquerade NAT.
pub fn disable_local_ws_redirect() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let subnet = ACTIVE_SUBNET.lock().ok().and_then(|s| s.clone());
        match subnet {
            Some(subnet) => setup_nat(&subnet, None, None),
            None => Ok(()),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(())
    }
}

/// pf rdr that DNATs in-tunnel TCP to the loopback listener. `inbound_iface` must
/// be the TUN name; rdr on lo0 never sees utun packets.
pub fn local_ws_rdr_rule(
    inbound_iface: &str,
    vpn_subnet: &str,
    server_ip: &str,
    app_port: u16,
) -> String {
    format!(
        "rdr pass on {inbound_iface} inet proto tcp from {vpn_subnet} to {server_ip} port {app_port} -> 127.0.0.1 port {app_port}\n"
    )
}

/// Remove NAT rules that were previously installed by `setup_nat`.
pub fn teardown_nat() -> Result<(), String> {
    let _subnet = ACTIVE_SUBNET.lock().ok().and_then(|mut s| s.take());

    #[cfg(target_os = "macos")]
    {
        teardown_nat_macos()
    }
    #[cfg(target_os = "linux")]
    {
        match _subnet {
            Some(s) => teardown_nat_linux(&s),
            None => Err("no active NAT subnet to tear down".to_string()),
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = _subnet;
        Err("NAT not supported on this platform".to_string())
    }
}

/// Enable IP forwarding so the kernel routes packets between interfaces.
pub fn enable_ip_forwarding() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        enable_ip_forwarding_macos()
    }
    #[cfg(target_os = "linux")]
    {
        enable_ip_forwarding_linux()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Err("IP forwarding not supported on this platform".to_string())
    }
}

// ---------------------------------------------------------------------------
// macOS implementation
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
fn detect_default_interface() -> Result<String, String> {
    let output = Command::new("route")
        .args(["-n", "get", "default"])
        .output()
        .map_err(|e| format!("failed to run `route -n get default`: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("interface:") {
            if let Some(iface) = trimmed.strip_prefix("interface:") {
                let iface = iface.trim();
                if !iface.is_empty() {
                    info!("detected default route interface: {}", iface);
                    return Ok(iface.to_string());
                }
            }
        }
    }
    Err("could not detect default route interface from `route -n get default`".to_string())
}

#[cfg(target_os = "macos")]
fn setup_nat_macos(
    vpn_subnet: &str,
    outbound_iface: Option<&str>,
    local_ws_redirect: Option<(&str, u16, Option<&str>)>,
) -> Result<(), String> {
    use std::io::Write;

    let iface = match outbound_iface {
        Some(i) => i.to_string(),
        None => detect_default_interface()?,
    };

    // Ensure pf is enabled (ignore error if already enabled)
    let enable_out = Command::new("pfctl")
        .arg("-e")
        .output()
        .map_err(|e| format!("failed to run `pfctl -e`: {}", e))?;
    if !enable_out.status.success() {
        let stderr = String::from_utf8_lossy(&enable_out.stderr);
        // "pf already enabled" is not a real error
        if !stderr.contains("already enabled") {
            warn!("pfctl -e stderr (may be harmless): {}", stderr.trim());
        }
    }

    // Ensure the "blackhole" anchor is referenced in the main pf.conf so rules
    // loaded into it are actually evaluated.  Read the existing pf.conf, append
    // anchor declarations if missing, and reload.
    ensure_pf_anchor()?;

    // Load NAT rule into the "blackhole" anchor
    let mut rules = format!(
        "nat on {} from {} to any -> ({})\n",
        iface, vpn_subnet, iface
    );
    if let Some((server_ip, app_port, inbound_iface)) = local_ws_redirect {
        match inbound_iface.filter(|iface| !iface.is_empty()) {
            Some(redirect_iface) => {
                let rdr_rule = local_ws_rdr_rule(redirect_iface, vpn_subnet, server_ip, app_port);
                info!("loading pf local redirect rule: {}", rdr_rule.trim());
                rules.push_str(&rdr_rule);
            }
            None => {
                warn!("skipping pf local redirect: inbound TUN iface not provided");
            }
        }
    }
    info!(
        "loading pf rules into anchor 'blackhole': {}",
        rules.trim_end()
    );

    let mut child = Command::new("pfctl")
        .args(["-a", "blackhole", "-f", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn pfctl: {}", e))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(rules.as_bytes())
            .map_err(|e| format!("failed to write pf rule: {}", e))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("pfctl wait failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("pfctl -a blackhole -f - failed: {}", stderr.trim()));
    }

    info!("NAT enabled via pf anchor 'blackhole' on {}", iface);
    Ok(())
}

/// Ensure the main pf.conf includes anchor references for "blackhole".
/// Without these, rules loaded into the anchor are silently ignored.
#[cfg(target_os = "macos")]
fn ensure_pf_anchor() -> Result<(), String> {
    use std::io::Write;

    let pf_conf_path = "/etc/pf.conf";
    let pf_conf = std::fs::read_to_string(pf_conf_path).unwrap_or_default();

    let needs_nat_anchor = !pf_conf.contains("nat-anchor \"blackhole\"");
    let needs_rdr_anchor = !pf_conf.contains("rdr-anchor \"blackhole\"");
    let needs_anchor = !pf_conf.contains("anchor \"blackhole\"");

    if !needs_nat_anchor && !needs_rdr_anchor && !needs_anchor {
        return Ok(());
    }

    // Build a full config that includes our anchor declarations.
    // We insert them right before the first non-anchor, non-comment line.
    let mut lines: Vec<String> = pf_conf.lines().map(|l| l.to_string()).collect();
    let mut insert_idx = lines.len();
    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if !trimmed.is_empty()
            && !trimmed.starts_with('#')
            && !trimmed.starts_with("anchor")
            && !trimmed.starts_with("nat-anchor")
            && !trimmed.starts_with("rdr-anchor")
            && !trimmed.starts_with("load anchor")
            && !trimmed.starts_with("set")
            && !trimmed.starts_with("scrub")
        {
            insert_idx = i;
            break;
        }
    }

    if needs_nat_anchor {
        lines.insert(insert_idx, "nat-anchor \"blackhole\"".to_string());
        insert_idx += 1;
    }
    if needs_rdr_anchor {
        lines.insert(insert_idx, "rdr-anchor \"blackhole\"".to_string());
        insert_idx += 1;
    }
    if needs_anchor {
        lines.insert(insert_idx, "anchor \"blackhole\"".to_string());
    }

    let new_conf = lines.join("\n") + "\n";

    info!(
        "updating {} with blackhole anchor declarations",
        pf_conf_path
    );

    // Reload the main ruleset so pf knows about the anchor
    let mut child = Command::new("pfctl")
        .args(["-f", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn pfctl for anchor registration: {}", e))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(new_conf.as_bytes())
            .map_err(|e| format!("failed to write pf config: {}", e))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("pfctl wait failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(
            "pfctl reload with anchor declarations failed: {} — NAT may not take effect",
            stderr.trim()
        );
        // Non-fatal: the anchor rule load might still work on some macOS versions
    }

    Ok(())
}

#[cfg(target_os = "macos")]
fn teardown_nat_macos() -> Result<(), String> {
    info!("flushing pf anchor 'blackhole'");
    let output = Command::new("pfctl")
        .args(["-a", "blackhole", "-F", "all"])
        .output()
        .map_err(|e| format!("failed to run pfctl flush: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "pfctl -a blackhole -F all failed: {}",
            stderr.trim()
        ));
    }

    info!("NAT teardown complete (pf anchor 'blackhole' flushed)");
    Ok(())
}

#[cfg(target_os = "macos")]
fn enable_ip_forwarding_macos() -> Result<(), String> {
    info!("enabling IP forwarding (macOS)");
    let output = Command::new("sysctl")
        .args(["-w", "net.inet.ip.forwarding=1"])
        .output()
        .map_err(|e| format!("failed to run sysctl: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("sysctl ip forwarding failed: {}", stderr.trim()));
    }

    info!("IP forwarding enabled");
    Ok(())
}

// ---------------------------------------------------------------------------
// Linux implementation
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn setup_nat_linux(vpn_subnet: &str) -> Result<(), String> {
    info!("setting up iptables MASQUERADE for {}", vpn_subnet);
    let output = Command::new("iptables")
        .args([
            "-t",
            "nat",
            "-A",
            "POSTROUTING",
            "-s",
            vpn_subnet,
            "-j",
            "MASQUERADE",
        ])
        .output()
        .map_err(|e| format!("failed to run iptables: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("iptables MASQUERADE failed: {}", stderr.trim()));
    }

    info!("NAT enabled via iptables MASQUERADE for {}", vpn_subnet);
    Ok(())
}

#[cfg(target_os = "linux")]
fn teardown_nat_linux(vpn_subnet: &str) -> Result<(), String> {
    info!("removing iptables MASQUERADE for {}", vpn_subnet);
    let output = Command::new("iptables")
        .args([
            "-t",
            "nat",
            "-D",
            "POSTROUTING",
            "-s",
            vpn_subnet,
            "-j",
            "MASQUERADE",
        ])
        .output()
        .map_err(|e| format!("failed to run iptables: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("iptables teardown failed: {}", stderr.trim()));
    }

    info!("NAT teardown complete (iptables rule removed)");
    Ok(())
}

#[cfg(target_os = "linux")]
fn enable_ip_forwarding_linux() -> Result<(), String> {
    info!("enabling IP forwarding (Linux)");
    let output = Command::new("sysctl")
        .args(["-w", "net.ipv4.ip_forward=1"])
        .output()
        .map_err(|e| format!("failed to run sysctl: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("sysctl ip_forward failed: {}", stderr.trim()));
    }

    info!("IP forwarding enabled");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::local_ws_rdr_rule;

    #[test]
    fn local_ws_rdr_rule_uses_utun_not_lo0() {
        let rule = local_ws_rdr_rule("utun4", "10.13.37.0/24", "10.13.37.1", 9527);
        assert!(rule.starts_with("rdr pass on utun4 inet proto tcp"));
        assert!(rule.contains("from 10.13.37.0/24 to 10.13.37.1 port 9527"));
        assert!(rule.contains("-> 127.0.0.1 port 9527"));
        assert!(!rule.contains("on lo0"));
    }
}
