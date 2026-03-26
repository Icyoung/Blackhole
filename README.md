# Blackhole

A cross-platform remote terminal system for secure shell access across devices.

## Architecture

```
┌─────────────┐         ┌─────────────┐         ┌─────────────────────┐
│   Voyager   │◄───────►│  Wormhole   │◄───────►│       Horizon       │
│  (Client)   │   WS    │   (Relay)   │   WS    │       (Host)        │
└─────────────┘         └─────────────┘         └─────────────────────┘
     iOS                     Rust                        macOS
    macOS                   Server                       Linux
   Android                                              Windows
     Web
   Windows
    Linux
```

## Components

### Horizon (Host Terminal Server)

The host application that runs on the machine you want to access remotely. Provides PTY (pseudo-terminal) functionality with native platform support. Also integrates Voyager client functionality for connecting to other Horizon hosts.

**Platforms:** macOS, Linux, Windows

**Features:**
- Native PTY implementation per platform
- LAN mode (direct WebSocket connection)
- Wormhole mode (NAT traversal via relay)
- 6-character session ID for easy pairing
- Device pairing with approval workflow
- Built-in Voyager client for remote access to other hosts
- Terminal groups for session organization

### Voyager (Remote Terminal Client)

The client application for connecting to Horizon hosts from any device.

**Platforms:** iOS, macOS, Android, Web, Windows, Linux

**Features:**
- Full terminal emulation (xterm)
- Multi-session support with terminal groups
- LAN and Wormhole connection modes
- HHKB-style virtual keyboard for mobile
- Keyboard shortcuts (Ctrl, Alt, Meta)

### Wormhole (Relay Server)

A Rust-based relay server that enables connections between Voyager and Horizon when they're not on the same network.

**Tech Stack:** Rust, Axum, Tokio

**Features:**
- WebSocket relay with binary protocol support
- 6-character session ID assignment
- Token-based authentication
- Device pairing workflow support
- Admin API for session management
- Docker deployment ready

### blackhole-wg (Vendored VPN Core)

Shared Rust crate used by the in-progress VPN/WireGuard transport work.

**Roles:**
- Host-side WireGuard server logic for `horizon/daemon`
- C FFI surface consumed by Voyager packet tunnel targets on Apple platforms

Source lives in `blackhole-wg/`. Generated artifacts under `blackhole-wg/target/`
are build output and should not be committed.

## Quick Start

### 1. Run Horizon (Host)

```bash
cd horizon
flutter run -d macos  # or linux, windows
```

#### Flutter as shell (external Rust core)

If you run `horizon-daemon` as a separate process, start the Flutter app with `HORIZON_CORE=1` (or `--external-core`) so it won’t try to bind the host port itself.

In shell mode, the host (Wormhole) settings in the Horizon panel are applied to the daemon; when they change, the app will request the daemon to restart to apply the new config.

#### macOS: close-to-tray

On macOS, clicking the window close button hides Horizon and keeps it running in the menu bar (use the menu bar item to show/quit).

#### Windows/Linux: close-to-tray

On Windows and Linux desktop builds, clicking the window close button hides Horizon and keeps it running in the system tray (right-click the tray icon to show/quit).

#### Tray “Quit” stops the daemon

If `horizon-daemon` is running, choosing **Quit** from the tray/menu-bar menu will also attempt to stop the daemon (via `~/.blackhole/horizon/daemon.pid`).

### 2. Run Voyager (Client)

```bash
cd voyager
flutter run -d ios     # or macos, android, chrome, linux, windows
```

#### iOS Native VPN

Voyager's Apple packet-tunnel path is currently iOS-only and opt-in. Enable it
with:

```bash
cd voyager
flutter run -d ios --dart-define=BH_ENABLE_NATIVE_VPN=true
```

You still need the matching Apple App Group and Network Extension signing
capabilities for a real-device run. Full setup notes live in
[`docs/ios-native-vpn.md`](docs/ios-native-vpn.md).

### 3. Run Wormhole (Relay) - Optional

```bash
cd wormhole
WORMHOLE_TOKEN=your-secret-token cargo run
```

### 4. Run Horizon (Headless, no GUI) - Optional

For servers without a desktop environment (e.g. Linux without GUI), you can run a headless host that speaks the same LAN WebSocket protocol:

```bash
cd horizon/daemon
cargo run -- --bind 0.0.0.0 --port 9527
```

Notes:
- The daemon is **single-instance** (uses `~/.blackhole/horizon/daemon.pid`).
- Windows uses **ConPTY** (Windows 10+). If you don’t pass `--shell`, it defaults to `COMSPEC` (usually `cmd.exe`).
- To stop the daemon locally, call `POST /shutdown` (loopback-only), e.g. `curl -X POST http://127.0.0.1:9527/shutdown`.

## Connection Modes

### LAN Mode (Direct)

1. Start Horizon on host machine
2. Note the displayed IP address and port
3. Open Voyager and enter the host address
4. Connect directly over local network

### Wormhole Mode (NAT Traversal)

1. Deploy Wormhole server to a public host
2. Configure Horizon with Wormhole URL and token
3. Connect Horizon to Wormhole (receives 6-char Session ID)
4. Open Voyager, enter Wormhole URL and Session ID
5. Connect through relay

## License

Blackhole is dual-licensed:

- **[GPL-3.0](LICENSE)** for open source use, modification, and redistribution.
- **[Commercial License](COMMERCIAL.md)** for proprietary use, including:
  - App Store / Google Play distribution
  - Closed-source deployments
  - Commercial SaaS offerings

If you intend to use Blackhole for commercial purposes without
releasing your source code under GPL-3.0, you must obtain a
commercial license.

Contact: dev@blackhole-ai.com
