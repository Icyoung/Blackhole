use std::collections::HashSet;

/// Per-socket PTY destination. `device_key` ties a LAN/control socket to an
/// in-tunnel data-plane socket so dual-plane does not emit a second copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtySinkMeta {
    pub id: u64,
    pub device_key: Option<String>,
    pub data_plane: bool,
}

impl PtySinkMeta {
    pub fn apply_data_plane(&mut self, active: bool, device_key: Option<String>) {
        self.data_plane = active;
        if let Some(key) = device_key {
            let trimmed = key.trim();
            if !trimmed.is_empty() {
                self.device_key = Some(trimmed.to_string());
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtyFanoutPlan {
    pub lan_sink_ids: Vec<u64>,
    /// Whether binary should go to Wormhole at all. Caller still applies
    /// `wormhole_subscriber_count > 0` as the "is anyone on Wormhole?" skip.
    pub send_wormhole: bool,
}

/// Choose binary PTY destinations.
///
/// Dual-plane is per `device_key`: if that device has a data-plane sink, other
/// sockets for the same key are skipped. Unkeyed LAN sockets still receive
/// (true LAN Voyager). Wormhole binary is sent when any Wormhole subscriber
/// lacks a data-plane sink — never gated on subscriber count here.
pub fn plan_pty_binary_fanout(
    sinks: impl IntoIterator<Item = PtySinkMeta>,
    wormhole_device_keys: impl IntoIterator<Item = String>,
) -> PtyFanoutPlan {
    let sinks: Vec<PtySinkMeta> = sinks.into_iter().collect();
    let wormhole_keys: Vec<String> = wormhole_device_keys.into_iter().collect();

    let data_plane_keys: HashSet<String> = sinks
        .iter()
        .filter(|sink| sink.data_plane)
        .filter_map(|sink| sink.device_key.clone())
        .collect();

    let lan_sink_ids: Vec<u64> = sinks
        .iter()
        .filter(|sink| should_send_lan_binary(sink, &data_plane_keys))
        .map(|sink| sink.id)
        .collect();

    // Empty key list: anonymous Wormhole subscribers still need binary.
    // Caller skips the upload when subscriber_count is 0.
    let send_wormhole = if wormhole_keys.is_empty() {
        true
    } else {
        wormhole_keys
            .iter()
            .any(|key| !data_plane_keys.contains(key))
    };

    PtyFanoutPlan {
        lan_sink_ids,
        send_wormhole,
    }
}

fn should_send_lan_binary(sink: &PtySinkMeta, data_plane_keys: &HashSet<String>) -> bool {
    if sink.data_plane {
        return true;
    }
    !matches!(&sink.device_key, Some(key) if data_plane_keys.contains(key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sink(id: u64, key: Option<&str>, data_plane: bool) -> PtySinkMeta {
        PtySinkMeta {
            id,
            device_key: key.map(|k| k.to_string()),
            data_plane,
        }
    }

    #[test]
    fn one_device_two_sockets_one_stdout_stream() {
        let plan = plan_pty_binary_fanout(
            [sink(1, Some("dev-a"), false), sink(2, Some("dev-a"), true)],
            ["dev-a".to_string()],
        );
        assert_eq!(plan.lan_sink_ids, vec![2]);
        assert!(!plan.send_wormhole);
    }

    #[test]
    fn two_devices_two_streams() {
        let plan = plan_pty_binary_fanout(
            [sink(1, Some("dev-a"), true), sink(2, Some("dev-b"), false)],
            ["dev-b".to_string()],
        );
        assert_eq!(plan.lan_sink_ids, vec![1, 2]);
        assert!(plan.send_wormhole);
    }

    #[test]
    fn true_lan_plus_vpn_does_not_filter_by_vpn_peer() {
        let plan = plan_pty_binary_fanout(
            [sink(1, None, false), sink(2, Some("vpn"), true)],
            ["vpn".to_string()],
        );
        assert_eq!(plan.lan_sink_ids, vec![1, 2]);
        assert!(!plan.send_wormhole);
    }

    #[test]
    fn wormhole_only_second_device_still_gets_pty() {
        let plan = plan_pty_binary_fanout(
            [sink(1, Some("vpn"), true)],
            ["vpn".to_string(), "relay".to_string()],
        );
        assert_eq!(plan.lan_sink_ids, vec![1]);
        assert!(plan.send_wormhole);
    }

    #[test]
    fn wormhole_subscriber_count_is_not_the_dual_plane_gate() {
        // Dual-plane skip is "does this device_key have a data-plane sink?",
        // not "is anyone subscribed via Wormhole?".
        let all_on_data_plane =
            plan_pty_binary_fanout([sink(1, Some("vpn"), true)], ["vpn".to_string()]);
        assert!(!all_on_data_plane.send_wormhole);

        let mixed = plan_pty_binary_fanout(
            [sink(1, Some("vpn"), true)],
            ["vpn".to_string(), "other".to_string()],
        );
        assert!(mixed.send_wormhole);
    }

    #[test]
    fn data_plane_json_binds_device_key() {
        let mut meta = sink(7, None, false);
        meta.apply_data_plane(true, Some("  dev-a  ".to_string()));
        assert!(meta.data_plane);
        assert_eq!(meta.device_key.as_deref(), Some("dev-a"));

        meta.apply_data_plane(false, None);
        assert!(!meta.data_plane);
        assert_eq!(meta.device_key.as_deref(), Some("dev-a"));
    }

    #[test]
    fn anonymous_wormhole_keys_keep_binary_path() {
        let plan = plan_pty_binary_fanout([sink(1, Some("vpn"), true)], Vec::<String>::new());
        assert_eq!(plan.lan_sink_ids, vec![1]);
        assert!(plan.send_wormhole);
    }
}
