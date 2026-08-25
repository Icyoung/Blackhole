use std::collections::HashSet;

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
    pub send_wormhole: bool,
}

/// `wormhole_tracked_subscribers` is the sum of known-key refcounts.
/// Skip Wormhole binary only when every live subscriber is in that set and
/// each of those keys already has a data-plane sink.
pub fn plan_pty_binary_fanout(
    sinks: impl IntoIterator<Item = PtySinkMeta>,
    wormhole_device_keys: impl IntoIterator<Item = String>,
    wormhole_tracked_subscribers: usize,
    wormhole_subscriber_count: usize,
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

    PtyFanoutPlan {
        lan_sink_ids,
        send_wormhole: should_send_wormhole_binary(
            &wormhole_keys,
            &data_plane_keys,
            wormhole_tracked_subscribers,
            wormhole_subscriber_count,
        ),
    }
}

fn should_send_lan_binary(sink: &PtySinkMeta, data_plane_keys: &HashSet<String>) -> bool {
    if sink.data_plane {
        return true;
    }
    !matches!(&sink.device_key, Some(key) if data_plane_keys.contains(key))
}

fn should_send_wormhole_binary(
    wormhole_keys: &[String],
    data_plane_keys: &HashSet<String>,
    wormhole_tracked_subscribers: usize,
    wormhole_subscriber_count: usize,
) -> bool {
    if wormhole_subscriber_count == 0 {
        return false;
    }
    if wormhole_subscriber_count > wormhole_tracked_subscribers {
        return true;
    }
    if wormhole_keys.is_empty() {
        return true;
    }
    wormhole_keys
        .iter()
        .any(|key| !data_plane_keys.contains(key))
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

    fn plan(
        sinks: impl IntoIterator<Item = PtySinkMeta>,
        keys: impl IntoIterator<Item = String>,
        tracked: usize,
        subscribers: usize,
    ) -> PtyFanoutPlan {
        plan_pty_binary_fanout(sinks, keys, tracked, subscribers)
    }

    #[test]
    fn one_device_two_sockets_one_stdout_stream() {
        let result = plan(
            [sink(1, Some("dev-a"), false), sink(2, Some("dev-a"), true)],
            ["dev-a".to_string()],
            1,
            1,
        );
        assert_eq!(result.lan_sink_ids, vec![2]);
        assert!(!result.send_wormhole);
    }

    #[test]
    fn two_devices_two_streams() {
        let result = plan(
            [sink(1, Some("dev-a"), true), sink(2, Some("dev-b"), false)],
            ["dev-b".to_string()],
            1,
            1,
        );
        assert_eq!(result.lan_sink_ids, vec![1, 2]);
        assert!(result.send_wormhole);
    }

    #[test]
    fn true_lan_plus_vpn_does_not_filter_by_vpn_peer() {
        let result = plan(
            [sink(1, None, false), sink(2, Some("vpn"), true)],
            ["vpn".to_string()],
            1,
            1,
        );
        assert_eq!(result.lan_sink_ids, vec![1, 2]);
        assert!(!result.send_wormhole);
    }

    #[test]
    fn wormhole_only_second_device_still_gets_pty() {
        let result = plan(
            [sink(1, Some("vpn"), true)],
            ["vpn".to_string(), "relay".to_string()],
            2,
            2,
        );
        assert_eq!(result.lan_sink_ids, vec![1]);
        assert!(result.send_wormhole);
    }

    #[test]
    fn untracked_wormhole_subscriber_keeps_binary() {
        let result = plan([sink(1, Some("vpn"), true)], ["vpn".to_string()], 1, 2);
        assert_eq!(result.lan_sink_ids, vec![1]);
        assert!(result.send_wormhole);
    }

    #[test]
    fn control_bind_without_active_is_exclusive_for_same_key() {
        let mut control = sink(1, None, false);
        control.apply_data_plane(false, Some("dev-a".to_string()));
        let result = plan(
            [control, sink(2, Some("dev-a"), true)],
            ["dev-a".to_string()],
            1,
            1,
        );
        assert_eq!(result.lan_sink_ids, vec![2]);
        assert!(!result.send_wormhole);
    }

    #[test]
    fn unkeyed_lan_client_is_not_dropped_when_another_device_is_dual_plane() {
        let mut control = sink(1, None, false);
        control.apply_data_plane(false, Some("vpn".to_string()));
        let result = plan(
            [control, sink(2, Some("vpn"), true), sink(3, None, false)],
            ["vpn".to_string()],
            1,
            1,
        );
        assert_eq!(result.lan_sink_ids, vec![2, 3]);
    }

    #[test]
    fn no_wormhole_subscribers_skips_relay() {
        let result = plan([sink(1, Some("vpn"), true)], Vec::<String>::new(), 0, 0);
        assert!(!result.send_wormhole);
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
}
