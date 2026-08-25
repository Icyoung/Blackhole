---
status: superseded
nickname: codex-3
superseded_by: 2276
design: 0b0fc273
---
# DECISION 2087: horizon-macos-helper-must-add-a-lo0-alias-for-the-vpn-server-ip-so-local-services-are-reachable-at-10-13-37-1

Date: 2026-03-17
Author: codex-3
Nickname: codex-3
Superseded: 2026-08-25 (design `0b0fc273` / decision 2276)

## Supersession (lo0 alias)

The **lo0 alias clause is superseded**. Do not run
`ifconfig lo0 alias 10.13.37.1`. A loopback alias makes replies leave via
`lo0` instead of utun and breaks VPN client connectivity.

Current macOS delivery: pf **rdr on utun** → `127.0.0.1:lanPort` (default
9527). Helper honors `app_port`. See `docs/macos-vpn-helper.md` and
decision 2115 (rdr kept; its alias clause also superseded).

The original context/evidence below is historical.

# Context

Voyager's native VPN relay path could establish a WireGuard session, but the
application-layer handoff to `ws://10.13.37.1:9529/ws` kept timing out. Host
logs showed Horizon daemon listening on `0.0.0.0:9529`, and the VPN relay
showed encrypted traffic flowing, but the inner websocket never reached
`ready`.

# Decision

~~On macOS, the privileged VPN helper must expose the VPN server IP
(`10.13.37.1`) as a local loopback alias on `lo0` in addition to configuring
the `utun` interface. The helper now runs:~~

~~- `ifconfig lo0 alias 10.13.37.1 10.13.37.1 netmask 0xffffffff` on start~~
~~- `ifconfig lo0 -alias 10.13.37.1` on stop~~

**Replacement:** do not alias `lo0`. Install
`rdr pass on utunX inet proto tcp from 10.13.37.0/24 to 10.13.37.1 port <lanPort> -> 127.0.0.1 port <lanPort>`.

This is tracked in `horizon/daemon/src/bin/horizon-vpn-helper.rs` and
`horizon/daemon/src/nat.rs`.

# Evidence

- `nc -vz 127.0.0.1 9529` succeeded on the host.
- `nc -vz 10.13.37.1 9529` hung before the loopback alias existed.
- `tcpdump -ni utun7 tcp port 9529` showed SYN packets to `10.13.37.1:9529`
  with no SYN-ACK.
- After adding `lo0` alias `10.13.37.1/32`, `nc -vz 10.13.37.1 9529`
  succeeded immediately.

(Note: live app port is **9527**, not 9529. Alias-based local `nc` success
did not prove in-tunnel reply routing.)

# Implications

- The previous helper setup made the VPN subnet reachable for packet routing,
  but it did not make Horizon's local application websocket reachable at the
  VPN server IP.
- VPN "connected" state and working WG control/data counters were not
  sufficient to guarantee that app-layer services were reachable until the host
  delivered TCP to the listener without stealing the reply path onto `lo0`.
