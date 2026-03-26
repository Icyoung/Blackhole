# Blackhole VPN Takeover Final Conclusion

> Date: 2026-03-17
> Scope: Voyager -> Wormhole -> Horizon VPN control plane and data plane
> Status: Final integrated conclusion agreed between codex-3 and codex-4

## End-to-End Breakpoints

- Voyager native VPN `connected` means only that the WireGuard handshake succeeded. It does not prove Blackhole app traffic has been taken over. After native WG connects, Voyager separately attempts an application-layer handoff to `ws://10.13.37.1:<lanPort>/ws`.
- The highest-probability current breakpoint is that Horizon does not guarantee a VPN-reachable app endpoint independent of LAN exposure. This includes both daemon `bindHost` still being derived from `lanEnabled` rather than `vpnEnabled`, and the macOS inconsistency where the helper-backed path explicitly exposes `10.13.37.1` while the direct-TUN path does not guarantee identical local ownership/reachability semantics for that VPN server IP.
- Stale peer routing by `deviceKey` / `client_ip` was a real data-plane breakpoint because Horizon `WgServer` routes TUN egress by VPN client IP. If stale peers for the same device remained, reply traffic could be encrypted to an old peer key. Current source now removes stale peers in `add_peer`, so this appears fixed in source but still depends on the running daemon actually including that code.
- Wormhole relay is confirmed to carry WireGuard data plane, not just control plane. Voyager can send encrypted WG packets over relay websocket, Wormhole `/wg-relay` forwards binary WG packets, and Horizon feeds relay packets into `WgServer` and can emit packets back to relay.
- Voyager iOS is currently split-tunnel by design. The native tunnel installs only `internalRoutes + VPN subnet`, not a default route. So arbitrary app/system traffic is not captured unless routes explicitly include it. This explains why full traffic takeover is not the current behavior by default, but it is not the first blocker for Blackhole's own websocket handoff because `10.13.37.1` is already inside the VPN subnet.

## Root-Cause Ranking

- `1)` Horizon does not guarantee a VPN-reachable app endpoint independent of LAN exposure. This is the primary root-cause bucket and includes both bind policy and VPN-server-IP reachability consistency.
- `2)` Stale peer routing ambiguity by `deviceKey` / `client_ip` on Horizon. Current source appears to address it, but runtime freshness still needs verification.
- `3)` Semantic gap between WG connected and application websocket takeover complete. The system can report VPN success while the app-layer handoff is still failing.
- `4)` Split-tunnel route scope, but mainly if the goal expands from Blackhole-app takeover to arbitrary app/system traffic takeover.
- No material disagreement remains beyond runtime verification of which of the above is active in the failing environment.

## Minimal Viable Fix Path

- Decouple VPN application reachability from LAN exposure. If `vpnEnabled=true`, Horizon must expose or proxy the application websocket on a VPN-reachable endpoint even when `lanEnabled=false`.
- Make host-side ownership/reachability of `10.13.37.1` consistent across helper and direct-TUN macOS paths.
- Keep stale-peer cleanup and ensure the running daemon/helper are restarted so the source-level fix is actually active in the failing environment.
- Treat WG connected and app websocket handoff ready as separate states in logs/UI. Only consider takeover complete after `ws://10.13.37.1:<lanPort>/ws` reaches ready.
- If the product goal later becomes true full-tunnel for arbitrary apps, add an explicit route-all/full-tunnel mode instead of conflating that with the current Blackhole-app takeover failure.

## Remaining Uncertainties

- We have not live-verified whether the failing environment is helper-backed or direct-TUN-backed in the current repro.
- We have not fully proven whether any startup path besides the reviewed desktop daemon path already avoids the bind/reachability problem when VPN is enabled.
- We have not verified whether the currently failing deployed binaries all include the stale-peer cleanup and any partial VPN-server-IP reachability changes already landed in source, for example helper-path `lo0` alias handling.
- After the bind/reachability issue is fixed, a remaining failure could still exist in the websocket handoff/session layer; that second-stage behavior was not live-proven in this pass.
