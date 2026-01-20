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

### Horizon for Blackhole (Host Terminal Server)

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

## Quick Start

### 1. Run Horizon (Host)

```bash
cd horizon
flutter run -d macos  # or linux, windows
```

### 2. Run Voyager (Client)

```bash
cd voyager
flutter run -d ios     # or macos, android, chrome, linux, windows
```

### 3. Run Wormhole (Relay) - Optional

```bash
cd wormhole
WORMHOLE_TOKEN=your-secret-token cargo run
```

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

## Building

### Prerequisites

- Flutter SDK 3.7+
- Rust 1.70+ (for Wormhole)
- Xcode (for macOS/iOS)
- Android Studio (for Android)
- Visual Studio (for Windows)
- GTK3 dev libraries (for Linux)

### Build Commands

```bash
# Horizon
cd horizon
flutter build macos
flutter build linux
flutter build windows

# Voyager
cd voyager
flutter build ios
flutter build macos
flutter build apk
flutter build web
flutter build linux
flutter build windows

# Wormhole
cd wormhole
cargo build --release
```

## Project Structure

```
Blackhole/
├── horizon/                 # Host terminal server (Flutter)
│   ├── lib/
│   │   ├── main.dart
│   │   └── src/
│   │       ├── app.dart
│   │       ├── controllers/
│   │       │   └── horizon_controller.dart
│   │       ├── models/
│   │       │   └── terminal_group.dart
│   │       ├── pages/
│   │       │   └── home_page.dart
│   │       ├── services/
│   │       │   ├── terminal_service.dart
│   │       │   ├── ws_server.dart
│   │       │   ├── connection_manager.dart
│   │       │   └── group_manager.dart
│   │       └── widgets/
│   ├── macos/Runner/
│   │   └── PtyManager.swift      # macOS PTY
│   ├── linux/runner/
│   │   └── pty_manager.cc        # Linux PTY
│   └── windows/runner/
│       └── pty_manager.cpp       # Windows ConPTY
│
├── voyager/                 # Remote terminal client (Flutter)
│   ├── lib/
│   │   ├── main.dart
│   │   └── src/
│   │       ├── app.dart
│   │       ├── models/
│   │       │   └── terminal_group.dart
│   │       ├── pages/
│   │       │   └── home_page.dart
│   │       ├── services/
│   │       │   ├── connection_manager.dart
│   │       │   ├── terminal_manager.dart
│   │       │   └── group_manager.dart
│   │       └── widgets/
│   │           └── keyboard/     # HHKB virtual keyboard
│   └── [ios|macos|android|web|linux|windows]/
│
├── wormhole/                # Relay server (Rust)
│   ├── Cargo.toml
│   ├── Dockerfile
│   └── src/
│       └── main.rs
│
└── LICENSE                  # GPL-3.0
```

## Environment Variables

### Wormhole Server

| Variable | Description | Default |
|----------|-------------|---------|
| `WORMHOLE_TOKEN` | Authentication token | (required) |
| `PORT` | Server port | 6666 |

## Protocol

Communication uses a binary WebSocket protocol:

| Byte | Description |
|------|-------------|
| 0 | Version (1) |
| 1 | Message type |
| 2-3 | Session ID length (big-endian) |
| 4-N | Session ID |
| N+1... | Payload |

### Binary Message Types

| Type | Value | Description |
|------|-------|-------------|
| Stdin | 0x01 | Terminal input |
| Stdout | 0x02 | Terminal output |
| Resize | 0x03 | Terminal resize |
| Ping | 0x04 | Heartbeat ping |
| Pong | 0x05 | Heartbeat pong |

### JSON Message Types

Control messages use JSON format with `type` field:
- `session_assigned` - Wormhole assigns session ID to Horizon
- `voyager_connect` / `voyager_disconnect` - Connection events
- `pairing_response` / `pairing_result` - Device pairing workflow
- `list` / `create` / `close` - Terminal session management
- `group_*` - Terminal group operations

## License

Blackhole is dual-licensed:

- **[GPL-3.0](LICENSE)** for open source use, modification, and redistribution.
- **[Commercial License](LICENSE-COMMERCIAL.md)** for proprietary use, including:
  - App Store / Google Play distribution
  - Closed-source deployments
  - Commercial SaaS offerings

If you intend to use Blackhole for commercial purposes without
releasing your source code under GPL-3.0, you must obtain a
commercial license.

Contact: licensing@blackhole.dev

