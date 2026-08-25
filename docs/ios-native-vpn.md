# Native VPN (iOS, Android, macOS)

Blackhole's native WireGuard client:

- Compile flag `BH_ENABLE_NATIVE_VPN` defaults to **true**. That flag is
  **not** the user toggle. The user toggle is `vpnEnabled` in app settings.
- `vpnEnabled` default-on for new installs is a separate product gate
  (stay-up). Do not treat the compile flag as "VPN is on."
- iOS uses a Network Extension packet tunnel (`VoyagerTunnel`).
- Android uses `VpnService`.
- macOS Voyager uses a **userspace** `VpnPlugin` + `voyager-vpn-helper`.
  `voyager/macos/VoyagerTunnel/` exists as research and is **not** the live
  path.

## What exists in repo

- `voyager/ios/Runner.xcodeproj` includes the `VoyagerTunnel` app extension.
- `voyager/ios/Runner/VpnPlugin.swift` exposes the Flutter method/event channels.
- `voyager/ios/VoyagerTunnel/PacketTunnelProvider.swift` runs the packet tunnel
  and links against vendored `blackhole-wg`.
- `voyager/macos/Runner/VpnPlugin.swift` + bundled `voyager-vpn-helper`
  (userspace TUN). Fail closed if the helper/TUN is missing.
- `voyager/lib/src/services/vpn_service.dart` — `isFeatureEnabled` reads
  `BH_ENABLE_NATIVE_VPN` (default true). Supported platforms: iOS, macOS,
  Android. Web / Linux / Windows Voyager have no VPN plugin.

## Three-plane handoff

Control WS stays up. After a real WG handshake, the app WebSocket for PTY is
**only** `ws://10.13.37.1:<lanPort>/ws` (default `lanPort` 9527), never the
physical NIC.

UI **Direct** is allowed only after `host_info.vpnPeer==true` on that
in-tunnel socket. If punch fails, stay on the control WebSocket.

Public WG UDP dest comes from candidate exchange / netcheck (UDP **6666**)
and/or UPnP — not Wormhole's WebSocket IP:51820, and never port 443.

`/wg-relay` is a stub. Do not send WG packets over WebSocket.

See `docs/wg-direct-roadmap.md` and `docs/architecture.md`.

## Required Apple capabilities (iOS NE)

The following must exist in the Apple Developer portal and in your signing
profile/certificate setup:

- App ID: `dev.icyou.blackhole.voyager`
- Packet Tunnel extension ID: `dev.icyou.blackhole.voyager.tunnel`
- App Group: `group.dev.icyou.blackhole.voyager`
- Network Extension capability: `packet-tunnel-provider`

The repo already points Xcode at these identifiers via:

- `voyager/ios/Runner/Runner.entitlements`
- `voyager/ios/VoyagerTunnel/VoyagerTunnel.entitlements`

## Local validation

Install pods if needed:

```bash
cd voyager/ios
pod install
```

Simulator build:

```bash
xcodebuild -workspace voyager/ios/Runner.xcworkspace \
  -scheme Runner \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Generic device build:

```bash
xcodebuild -workspace voyager/ios/Runner.xcworkspace \
  -scheme Runner \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Run Voyager (compile flag already defaults true; pass it only to be explicit
or to disable with `false`):

```bash
cd voyager
flutter run -d ios
# optional: --dart-define=BH_ENABLE_NATIVE_VPN=true
```

The in-app **VPN** switch is `vpnEnabled`. Turning the compile flag on does
not start a tunnel by itself.

## Runtime notes

- Voyager asks Wormhole for `endpoint_info`, then punches Horizon's
  **UDP candidates** (LAN, netcheck-observed, UPnP). `vpn_config.serverIp`
  (`10.13.37.1`) is the in-tunnel **app WS** host, not the public WG
  endpoint.
- `vpn_config` carries tunnel addresses, DNS, MTU, routes, and `lanPort`.
- Native `connected` means a WireGuard **handshake**, not "UDP socket
  exists."
- The packet tunnel writes structured status to the shared App Group
  container so Flutter can show `connecting`, `connected`, `disconnecting`,
  and `error`.
- Split tunnel: only `10.13.37.0/24` (+ optional `internalRoutes`).

## Remaining manual step

A signed real-device run with the matching App Group and Network Extension
capability is still required to treat the iOS NE path as runtime-certified.
Until that is done, treat it as build-validated.
