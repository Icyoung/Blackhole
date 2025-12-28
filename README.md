# Blackhole

A cross-platform remote terminal system for secure shell access across devices.

## Architecture

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Voyager   │◄───────►│  Wormhole   │◄───────►│   Horizon   │
│  (Client)   │   WS    │   (Relay)   │   WS    │   (Host)    │
└─────────────┘         └─────────────┘         └─────────────┘
     iOS                     Rust                   macOS
    macOS                   Server                  Linux
   Android                                         Windows
     Web
   Windows
    Linux
```

## Components

### Horizon (Host Terminal Server)

The host application that runs on the machine you want to access remotely. Provides PTY (pseudo-terminal) functionality with native platform support.

**Platforms:** macOS, Linux, Windows

**Features:**
- Native PTY implementation per platform
- LAN mode (direct WebSocket connection)
- Wormhole mode (NAT traversal via relay)
- 6-character session ID for easy pairing

### Voyager (Remote Terminal Client)

The client application for connecting to Horizon hosts from any device.

**Platforms:** iOS, macOS, Android, Web, Windows, Linux

**Features:**
- Full terminal emulation (xterm)
- Multi-session support
- LAN and Wormhole connection modes
- Keyboard shortcuts (Ctrl, Alt, Meta)

### Wormhole (Relay Server)

A Rust-based relay server that enables connections between Voyager and Horizon when they're not on the same network.

**Tech Stack:** Rust, Axum, Tokio

**Features:**
- WebSocket relay
- Session ID assignment
- Token-based authentication

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
│   │       ├── horizon_controller.dart
│   │       ├── terminal_service.dart
│   │       └── ws_server.dart
│   ├── macos/runner/
│   │   └── PtyManager.swift      # macOS PTY
│   ├── linux/runner/
│   │   ├── pty_manager.cc        # Linux PTY
│   │   └── pty_manager.h
│   └── windows/runner/
│       ├── pty_manager.cpp       # Windows ConPTY
│       └── pty_manager.h
│
├── voyager/                 # Remote terminal client (Flutter)
│   ├── lib/
│   │   └── main.dart
│   ├── ios/
│   ├── macos/
│   ├── android/
│   ├── web/
│   ├── linux/
│   └── windows/
│
├── wormhole/                # Relay server (Rust)
│   ├── Cargo.toml
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
| `PORT` | Server port | 3000 |

## Protocol

Communication uses a binary WebSocket protocol:

| Byte | Description |
|------|-------------|
| 0 | Message type |
| 1-4 | Session ID length (big-endian) |
| 5-N | Session ID |
| N+1... | Payload |

### Message Types

| Type | Value | Description |
|------|-------|-------------|
| Stdin | 0x00 | Terminal input |
| Stdout | 0x01 | Terminal output |
| Resize | 0x02 | Terminal resize |
| Create | 0x10 | Create session |
| Close | 0x11 | Close session |

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
