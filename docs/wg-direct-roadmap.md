# WG Direct (current architecture)

> Status: **current**. The DERP / WG-over-WebSocket / `/wg-relay` data-plane
> plan that this file previously described is **superseded** (design
> `0b0fc273`, decision 2276). Do not resurrect that path.

Preferred WAN data path after pairing is **WireGuard UDP**. Fallback is the
control WebSocket that is already up (Wormhole or LAN). There is no third
data plane.

Related: `docs/architecture.md`, `docs/remove-wg-relay.md`,
`docs/ios-native-vpn.md`, `docs/macos-vpn-helper.md`, decision 2276.

## Three planes

| Plane | Transport | Lifetime | Carries |
| --- | --- | --- | --- |
| Control | Wormhole WSS (WAN) or LAN `ws://<host>:9527/ws` | Always on after connect/pair | Pairing, groups, session list, VPN signaling (`endpoint_*`, `vpn_config`), ping. Also the **fallback PTY** path. |
| WG UDP | WireGuard to Horizon UDP **51820** | Preferred after pair; optional | Encrypted IP for subnet `10.13.37.0/24` |
| Data (PTY) | `ws://10.13.37.1:<lanPort>/ws` inside the tunnel | Only after handshake **and** `host_info.vpnPeer==true` on **that** socket | Binary stdin/stdout/resize |

`lanPort` is Horizon's app/LAN port (default **9527**). It is not 9529.

```
Voyager Flutter
  ├─ Control WS  ──► Wormhole (WAN) or Horizon LAN :9527
  │                    (signaling + fallback PTY)
  └─ Native WG / TUN
         │  WG UDP 51820 (STUN/UPnP dest, never WS IP:51820)
         ▼
      Horizon WgServer ──► horizon-daemon ──► PTY
         ▲
         └── in-tunnel WS: ws://10.13.37.1:lanPort/ws
```

## Current truth

- **Handoff host is `10.13.37.1`**, never the physical NIC. WG UDP dest is a
  candidate set (LAN / netcheck-observed / UPnP), not the app-WS host.
- UI may show **WireGuard Direct** only after `host_info.vpnPeer==true` on the
  in-tunnel socket (URI host `10.13.37.1`). Open that socket with transport
  kind `unknown`. A control-plane `host_info` with omitted/false `vpnPeer`
  must not set or clear Direct.
- If hole punch fails — including symmetric NAT — PTY stays on the control
  WebSocket. That is success, not an error.
- **`/wg-relay` is a stub** (`200`, `"wg-relay stub"`). Datapath removed.
  Keep the stub so old clients probing it do not 404. Do not reimplement
  WG-over-WebSocket / DERP.
- Production Wormhole **netcheck is UDP 6666**, never 443 and never the WSS
  URI port. Public WG dest is STUN/netcheck and/or UPnP UDP, not
  `observed-WS-IP:51820`.
- Horizon daemon owns PTY, pairing (`device_key` allowlist), and the WG
  server. Wormhole is a thin in-memory router + signaling + netcheck. It
  does not parse PTY and does not persist sessions.
- macOS host delivery is **pf `rdr` on utun** → `127.0.0.1:lanPort`. Do
  **not** add a `lo0` alias for `10.13.37.1` (decisions 2087 / 2115 alias
  clause superseded).
- macOS Voyager stays **userspace helper**; Network Extension sources under
  `voyager/macos/VoyagerTunnel/` are research.
- `BH_ENABLE_NATIVE_VPN` compile default `true` is **not** the user toggle.
  The user toggle is `vpnEnabled`. Default-on for new installs is gated on
  stay-up (not this docs PR).

## Split tunnel

Only `10.13.37.0/24` (plus optional `internalRoutes`) goes through the
tunnel. Wormhole WSS and other public traffic stay on the default interface.

## Historical: DERP / WG-over-WS (superseded)

Earlier drafts of this document treated Wormhole `/wg-relay` as a
Tailscale-DERP equivalent: bootstrap and fallback for WireGuard packets
inside a WebSocket, with relay-to-direct promotion.

That path was removed on purpose (`docs/remove-wg-relay.md`):

- Double encryption (WSS + WG) and extra encapsulation vs the control WS
  that already carries PTY.
- Punch failure must stay on Wormhole/LAN WebSocket, not switch to a slower
  WG-over-WS hop.

Do not revive candidate-driven **WG relay** probing, `VpnTunnelMode.relay` →
`wireguardRelay`, or a live `/wg-relay` handler. Candidate-driven **direct
UDP** punch and netcheck remain valid; they terminate on Horizon's WG
server, not on a relay datapath.
