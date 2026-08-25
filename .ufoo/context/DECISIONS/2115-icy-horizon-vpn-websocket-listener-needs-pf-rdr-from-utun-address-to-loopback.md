---
status: open
nickname: icy
alias_clause: superseded
superseded_by: 2276
design: 0b0fc273
---
# DECISION 2115: Horizon VPN websocket listener needs pf rdr from utun address to loopback

Date: 2026-03-18
Author: icy
Nickname: icy
Updated: 2026-08-25 (design `0b0fc273` / decision 2276)

## Supersession (lo0 alias only)

**Keep:** pf `rdr` that DNATs in-tunnel TCP from the VPN subnet targeting
`10.13.37.1:<lanPort>` to `127.0.0.1:<lanPort>`.

**Change:** `inbound_iface` must be the **utun** name. rdr on `lo0` never
sees utun packets.

**Superseded:** the lo0-alias clause ("also ensure the VPN server IP is
exposed on `lo0` via an alias"). Decision 2087 is superseded in full. A
`lo0` alias for `10.13.37.1` makes replies leave via loopback and breaks
the client.

Live helper honors `app_port`. Handoff URI is `ws://10.13.37.1:<lanPort>/ws`
(default 9527, not 9529). UI Direct only after `host_info.vpnPeer==true` on
that socket. See `docs/macos-vpn-helper.md`.

## Context

Voyager now successfully completes relay negotiation, switches application traffic to
`ws://10.13.37.1:9529/ws`, and starts sending TCP packets over the WireGuard relay tunnel.
Horizon decrypts those packets and injects them into `utun`, and the helper confirms packets
with `src=10.13.37.2 dst=10.13.37.1 proto=6` are forwarded from daemon to `utun`.

However, Horizon never logs `websocket upgrade requested ... vpn_peer=true`, which means the
local websocket listener is not actually receiving the TCP connection addressed to
`10.13.37.1:9529` after injection into the VPN interface.

## Decision

On macOS, when Horizon configures VPN NAT rules, also install a pf `rdr` rule that rewrites
TCP traffic from the VPN subnet targeting the Horizon VPN server IP and websocket port to
`127.0.0.1:<port>`. **~~In helper-backed mode, also ensure the VPN server IP is exposed on `lo0`
via an alias so the address is locally owned.~~** Do not add the alias.

This is wired through the helper protocol by passing the websocket app port into VPN startup,
so both native and helper-backed startup paths configure the same **utun-scoped** redirect.

## Implications

- Packets injected into `utun` for `10.13.37.1:<lanPort>` should now reliably reach the existing
  loopback websocket listener instead of depending on macOS local-delivery behavior for the
  utun-bound address.
- ~~Helper teardown must remove the `lo0` alias to avoid leaving stale local addresses behind.~~
  Helper teardown must remove the utun rdr with the blackhole pf anchor. Do not leave a
  `lo0` alias behind, and do not create one.
- This change targets the final host-local delivery gap after handshake, handoff, and
  packet decapsulation were already verified working.
