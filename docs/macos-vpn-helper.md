# macOS VPN Helper

Privileged helper path for Horizon's macOS VPN **host** mode. Voyager on
macOS is a separate userspace helper (`voyager-vpn-helper`); see
`docs/ios-native-vpn.md`.

## Current shape

- `horizon-daemon` stays unprivileged and owns PTY, HTTP/WS, pairing,
  Wormhole signaling, and the WireGuard peer/event loop.
- `horizon-vpn-helper` is a separate binary intended to run as root.
- If `horizon-daemon` sees a helper socket, it asks the helper to:
  - create `utun`
  - configure the interface address/route
  - enable forwarding
  - set up NAT
  - install pf **rdr on that utun** for in-tunnel app WS
  - create a local Unix packet socket bridge
  - pass only the daemon-side packet socket fd back over a Unix socket

The helper keeps ownership of the real `utun` descriptor and bridges raw IP
packets between `utun` and the daemon's helper-backed packet socket. Do not
pass the live `utun` fd via `SCM_RIGHTS`.

## In-tunnel TCP delivery (no lo0 alias)

Voyager's PTY handoff target is `ws://10.13.37.1:<lanPort>/ws` (default
9527). On macOS, packets to that address on utun do not reliably reach a
listener bound to `0.0.0.0` / loopback without a redirect.

Live path: pf rdr **on the utun interface** (not `lo0`):

```text
rdr pass on utunX inet proto tcp from 10.13.37.0/24 to 10.13.37.1 port 9527 -> 127.0.0.1 port 9527
```

The helper **honors `app_port`** for that redirect. Tear down the rdr with
the existing blackhole pf anchor.

**Do not** add `ifconfig lo0 alias 10.13.37.1`. A loopback alias makes
replies leave via `lo0` instead of utun and breaks the client. Decision
2087 and the lo0-alias clause of decision 2115 are **superseded** by design
`0b0fc273` / decision 2276. The rdr-on-utun part of 2115 still holds.

UI Direct is allowed only after Horizon accepts that socket as
`host_info.vpnPeer==true`.

## Socket path and permissions

By default both binaries use:

```text
~/.blackhole/horizon/vpn-helper.sock
```

Override with `HORIZON_VPN_HELPER_SOCKET`. After bind, the helper
`chown`s the socket to the console / `SUDO_UID` user, then `chmod 0600`.
The helper is root; `0600` owned by root would lock the unprivileged
daemon out.

## Bundling and privilege

- Xcode must copy `horizon-vpn-helper` into `Contents/Resources`. Missing
  helper is a hard error (fail closed), not "continue without TUN".
- The macOS app can launch the helper through an administrator prompt
  (`ensureVpnHelper`) when `vpnEnabled` is true. That prompt is the consent
  path; there is no second Flutter helper sheet.
- **`SMAppService` is a follow-up**, not a blocker. No launchd install in
  this cut. osascript remains the live start path.

`BH_ENABLE_NATIVE_VPN` (Voyager compile default true) is not this host
toggle. Horizon's user toggle is `vpnEnabled`.

## Manual test flow

1. Build Horizon for macOS so the helper is bundled into the app:

```bash
cd horizon
flutter build macos
```

2. Start the helper as root:

```bash
sudo /path/to/Horizon.app/Contents/Resources/horizon-vpn-helper \
  --socket "$HOME/.blackhole/horizon/vpn-helper.sock" \
  --pid-file "$HOME/.blackhole/horizon/vpn-helper.pid"
```

3. Start Horizon normally. When host VPN mode is enabled, `horizon-daemon`
   detects the helper socket and requests privileged VPN setup instead of
   touching `utun` directly.

## Limitations of this stage

- Helper install/start is still the administrator prompt (no `SMAppService`
  yet).
- `stop_vpn` is still best-effort: stop the bridge thread, tear down NAT/rdr,
  bring the interface down.
- The helper protocol is local-only and intentionally small; keep a version
  handshake.
- Linux Horizon uses `/dev/net/tun` + iptables MASQUERADE (no pf, no lo0).
