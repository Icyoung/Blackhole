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

Contact: licensing@blackhole.dev

