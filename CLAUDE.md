# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Blackhole is a cross-platform remote terminal system with three components:
- **Horizon** (Flutter) - Host terminal server that runs on the machine you want to access (macOS/Linux/Windows)
- **Voyager** (Flutter) - Remote terminal client that connects from any device (iOS/macOS/Android/Web/Linux/Windows)
- **Wormhole** (Rust) - WebSocket relay server for NAT traversal

## Development Commands

### Horizon (Host Server)
```bash
cd horizon
flutter run -d macos          # Run on macOS
flutter run -d linux          # Run on Linux
flutter run -d windows        # Run on Windows
flutter build macos           # Build release
dart format .                 # Format code
flutter analyze               # Lint
```

### Voyager (Client)
```bash
cd voyager
flutter run -d ios            # Run on iOS
flutter run -d macos          # Run on macOS
flutter run -d chrome         # Run on Web
flutter run -d android        # Run on Android
flutter build apk             # Build Android release
dart format .                 # Format code
flutter analyze               # Lint
```

### Wormhole (Relay Server)
```bash
cd wormhole
WORMHOLE_TOKEN=your-secret-token cargo run    # Run server
cargo build --release                          # Build release
cargo fmt                                      # Format code
cargo test                                     # Run tests
```

## Architecture

### Communication Flow
```
Voyager ←→ [WebSocket] ←→ Wormhole ←→ [WebSocket] ←→ Horizon ←→ PTY/Shell
```

### Network Modes
1. **LAN Mode**: Direct WebSocket connection between Voyager and Horizon (lowest latency)
2. **WAN Mode**: Connection through Wormhole relay server (NAT traversal)

### Binary Protocol
WebSocket messages use a binary protocol: `[type: u8][session_id_len: u32][session_id][payload]`

Message types: stdin (1), stdout (2), resize (3), ping (4), pong (5)

### Platform PTY Implementation
Horizon uses platform-specific native code for PTY (pseudo-terminal):
- **macOS**: `horizon/macos/Runner/PtyManager.swift` - Uses `forkpty()` + DispatchSource
- **Linux**: `horizon/linux/runner/pty_manager.cc` - Uses `forkpty()` + threads
- **Windows**: `horizon/windows/runner/pty_manager.cpp` - Uses ConPTY API

Dart communicates with native code via MethodChannel (`com.blackhole/pty`) and EventChannel (`com.blackhole/pty/output`).

### Key Dart Files
- `horizon/lib/src/controllers/horizon_controller.dart` - Main controller managing PTY sessions and WebSocket connections
- `horizon/lib/src/services/terminal_service.dart` - Platform channel interface to native PTY
- `horizon/lib/src/services/ws_server.dart` - WebSocket server for LAN mode
- `voyager/lib/src/services/connection_manager.dart` - Manages WebSocket connections to Horizon/Wormhole
- `voyager/lib/src/services/terminal_manager.dart` - Terminal session state management

### Wormhole Architecture
Single-file Rust server (`wormhole/src/main.rs`) using Axum + Tokio:
- Session management with 6-character IDs
- Routes Horizon and Voyager connections
- Token-based authentication via `WORMHOLE_TOKEN` env var
- No persistent storage (memory-only session routing)

## Commit Message Convention
Use component prefix: `Horizon: fix tab reorder`, `Voyager: add reconnect`, `Wormhole: add token auth`

## Environment Variables

### Wormhole Server
- `WORMHOLE_TOKEN` - Required authentication token
- `PORT` - Server port (default: 6666)
