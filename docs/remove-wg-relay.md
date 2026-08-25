# Remove WG Relay Transport

> Date: 2026-03-23
> Updated: 2026-08-25
> Status: **datapath removed; stub retained**
> Author: refiner (ui-polish group)

Do **not** reimplement WG-over-WebSocket / DERP. Punch failure stays on the
Wormhole/LAN control WebSocket. See `docs/wg-direct-roadmap.md` and decision
2276 / design `0b0fc273`.

## Current status

The WG-over-WebSocket data plane is gone. Live remote path:

```
WebSocket relay (control + fallback PTY) → WG direct UDP + in-tunnel app WS
```

- Hole-punching may run while WebSocket already carries PTY.
- On success: handoff to `ws://10.13.37.1:<lanPort>/ws` (default 9527) and
  show Direct only if `host_info.vpnPeer==true` on that socket.
- On failure: stay on WebSocket relay (already working).

Wormhole still exposes `GET /wg-relay` as a **stub** (`200 OK`, body
`"wg-relay stub"`). Old clients probing it must not 404. Leave the stub
until a dedicated cleanup PR. Do not put packets on it.

The sections below are the original removal plan, kept as history. Treat
the datapath work as done; the remaining item is optional stub deletion.

## Background

Historical remote connection upgrade path:

```
WebSocket relay → WG relay → WG direct
```

**WG relay** encapsulated WireGuard packets inside a WebSocket and forwarded
them through the Wormhole server. That created:

- **Double encryption**: WSS (TLS) + WireGuard — redundant since we control the Wormhole server
- **Double encapsulation**: WG packet → WebSocket frame → TLS — higher overhead than plain WebSocket relay
- **Higher latency**: extra WG protocol stack processing on both ends
- **More code**: ~600 lines across 18 files for a transport layer that performs worse than WebSocket relay

The only justification was as a fallback when WG direct hole-punching times out. But WebSocket relay is already working at that point — there's no reason to switch to a slower WG-over-WebSocket path.

## Target state (achieved)

```
WebSocket relay → WG direct
```

- Hole-punching runs in background while WebSocket relay carries traffic
- On success: seamless handoff to WG direct (UDP)
- On failure: stay on WebSocket relay (already working, good enough)

Handoff host is **`10.13.37.1`**, never the physical NIC. App port is
Horizon `lanPort` (9527). Public WG dest is STUN/UPnP, not the Wormhole WS
address.

## Affected files (18 total)

Original removal checklist. Datapath items are done; `/wg-relay` route
remains as the stub.

### Flutter (Voyager)

| File | What to change |
|------|---------------|
| `voyager/lib/src/services/transport_models.dart` | Remove `wireguardRelay` enum value |
| `voyager/lib/src/services/transport_rollout.dart` | Remove `wireguardRelay` priority (125) |
| `voyager/lib/src/services/vpn_transport_handoff.dart` | Remove `VpnTunnelMode.relay → wireguardRelay` mapping; punch timeout keeps WebSocket relay |
| `voyager/lib/src/pages/home_page.dart` | Remove `wireguardRelay` UI text branch |
| `voyager/lib/src/services/wg_app_flow_validator.dart` | Remove relay packet validation |

### iOS Tunnel Extension

| File | What to change |
|------|---------------|
| `voyager/ios/VoyagerTunnel/PacketTunnelProvider.swift` | Remove `relaySession`, `relayTask`, `activateRelayFallback()`, relay send/receive loops, relay packet counters, `.relay` ingress path |
| `voyager/ios/VoyagerTunnel/TunnelRuntimeCoordinator.swift` | Remove `.activateRelay` action, relay fallback logic, `relayFallbackAttempted` flag |
| `voyager/ios/VoyagerTunnel/TunnelConfig.swift` | Remove `relayUrl` field |

### Wormhole Server (Rust)

| File | What to change |
|------|---------------|
| `wormhole/src/main.rs` | Remove `/wg-relay` route, `wg_relay_handler()`, `handle_wg_relay()`, `cleanup_wg_relay()`, `WgRelayParams`, Session fields `wg_relay_horizon` / `wg_relay_voyagers` |

**Now:** keep `.route("/wg-relay", get(wg_relay_stub))` until a cleanup PR.

### Horizon Daemon (Rust)

| File | What to change |
|------|---------------|
| `horizon/daemon/src/main.rs` | Remove `run_wg_relay_horizon()`, `current_wg_relay_url_for_voyager()`, `build_wg_relay_url()`, relay URL generation in endpoint responses |

### Horizon Flutter

| File | What to change |
|------|---------------|
| `horizon/lib/src/services/transport_models.dart` | Remove `wireguardRelay` enum value |

### Tests & Tools

| File | What to change |
|------|---------------|
| `voyager/test/vpn_transport_handoff_test.dart` | Remove wireguardRelay test cases (~10 refs) |
| `voyager/test/transport_rollout_test.dart` | Remove wireguardRelay priority test |
| `voyager/test/transport_models_test.dart` | Remove wireguardRelay parse test |
| `voyager/ios/RunnerTests/TunnelRuntimeCoordinatorTests.swift` | Remove relay action tests (~18 refs) |
| `voyager/tool/ios_tunnel_runtime_replay.swift` | Remove relay scenarios (~10 refs) |
| `voyager/tool/vpn_handoff_replay.dart` | Remove wireguardRelay ref |
| `horizon/test/transport_models_test.dart` | Remove wireguardRelay parse test |

## Phased execution (historical)

### Phase 1 — Cut the upgrade path (Flutter side)

**Risk: Low** — config change only, existing connections unaffected, instant rollback.

1. `vpn_transport_handoff.dart`: `VpnTunnelMode.relay` stops triggering transport switch to `wireguardRelay`. Punch timeout → stay on WebSocket relay.
2. `transport_rollout.dart`: Remove `wireguardRelay` priority entry.
3. `home_page.dart`: Remove `case TransportKind.wireguardRelay` UI branch.

After this phase, no new WG relay connections will be initiated. Existing code is dead but harmless.

### Phase 2 — Remove iOS tunnel relay logic

**Risk: Medium** — needs VPN flow testing on device.

1. `PacketTunnelProvider.swift`: Remove all relay plumbing (~120 lines).
2. `TunnelRuntimeCoordinator.swift`: Remove `.activateRelay` action and relay fallback decision logic.
3. `TunnelConfig.swift`: Remove `relayUrl` field.
4. Update iOS tests and replay tool.

**Test plan:**
- VPN connect with hole-punch success → WG direct works
- VPN connect with hole-punch failure → stays on WebSocket relay, no crash
- VPN connect → hole-punch timeout → later succeeds → promotes to WG direct

### Phase 3 — Remove server-side relay endpoints

**Risk: Low** — but requires coordinated deployment (Wormhole + Horizon daemon).

1. `wormhole/src/main.rs`: Remove `/wg-relay` route and handler (~180 lines).
2. `horizon/daemon/src/main.rs`: Remove relay client and URL generation (~150 lines).

**Deploy order:** Phase 1+2 deployed first (clients stop using relay) → wait for all clients to update → Phase 3 (remove server endpoint).

**Amendment:** Phase 3 keeps a stub route. Full route deletion is optional cleanup, not a data-plane restore.

### Phase 4 — Clean up enums and tests

**Risk: None** — compiler enforces completeness.

1. Remove `wireguardRelay` from both `transport_models.dart` files.
2. Remove all test cases and replay scenarios referencing wireguardRelay.
3. Remove `wg_app_flow_validator.dart` relay validation.

## Hole-punch timeout strategy

```
┌─────────────────────────────────────────────┐
│  WebSocket relay (already connected)        │
│                                             │
│  Background: WG hole-punch attempting...    │
│  ├─ Candidate 0 (timeout: 12s)              │
│  ├─ Candidate 1 (timeout: 12s)              │
│  └─ ... up to N available candidates        │
│                                             │
│  On punch success (any candidate):          │
│  └─ Handoff PTY to ws://10.13.37.1:lanPort  │
│     UI Direct only if host_info.vpnPeer     │
│                                             │
│  On all candidates exhausted:               │
│  └─ Stay on WebSocket relay (no degradation)│
└─────────────────────────────────────────────┘
```

No intermediate WG relay state. The user either gets WG direct (best) or stays on WebSocket relay (good enough). No confusing third state.

## VPN & WebSocket coexistence

VPN uses **split tunnel** — only `includedRoutes` (VPN subnet + internal routes) go through the tunnel. Wormhole WebSocket connections target public addresses and are **not affected** by VPN establishment:

- Routing: public traffic stays on default interface
- DNS: only `dnsMatchDomains` (if configured) go through tunnel DNS
- No reconnect storm when VPN activates

## Estimated impact

- **States eliminated**: 1 transport state (`wireguardRelay`), 1 tunnel action (`.activateRelay`)
- **Wormhole `/wg-relay`**: stub retained (not a live datapath)
- **Simplified mental model**: 2 remote modes instead of 3
- **Performance**: no regression (removing a slower path)
