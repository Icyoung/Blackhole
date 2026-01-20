# Repository Guidelines

## Architecture
```
Voyager (Client) ←→ [WebSocket] ←→ Wormhole (Relay) ←→ [WebSocket] ←→ Horizon (Host) ←→ PTY/Shell
```

## Project Structure
Blackhole is a multi-component system with three main modules:
- `horizon/` is the host terminal server (Flutter). Core Dart code lives in `horizon/lib/`, with platform PTY integrations under `horizon/macos/`, `horizon/linux/`, and `horizon/windows/`.
- `voyager/` is the remote terminal client (Flutter). UI and app logic are in `voyager/lib/`, with platform shells under `voyager/ios/`, `voyager/macos/`, `voyager/android/`, `voyager/web/`, `voyager/linux/`, `voyager/windows/`.
- `wormhole/` is the Rust relay server. The entrypoint is `wormhole/src/main.rs` with config in `wormhole/Cargo.toml`.
Supporting docs live in `docs/`; assets and screenshots are in `screenshot/` when present.

## Build, Test, and Development Commands
- `cd horizon && flutter run -d macos` (or `linux`, `windows`) to run the host locally.
- `cd voyager && flutter run -d ios` (or `macos`, `android`, `chrome`, `linux`, `windows`) to run the client.
- `cd wormhole && WORMHOLE_TOKEN=your-secret-token cargo run` to start the relay server.
- `cd horizon && flutter build macos` or `cd voyager && flutter build apk` for release builds.
- `cd wormhole && cargo build --release` for a production relay binary.

## Coding Style & Naming Conventions
- Dart/Flutter: 2-space indentation; format with `dart format .` and lint with `flutter analyze` (see `analysis_options.yaml`).
- Rust: use `cargo fmt` and keep naming idiomatic (`snake_case` for functions, `CamelCase` for types).
- Keep platform-specific logic isolated in the platform runner directories and avoid duplicating shared Dart logic.

## Testing Guidelines
There are no committed test suites yet. If you add tests:
- Flutter: place tests under `horizon/test/` or `voyager/test/` with `*_test.dart`, run with `flutter test`.
- Rust: add unit tests in `wormhole/src/` or integration tests in `wormhole/tests/`, run with `cargo test`.
Add tests for protocol handling and reconnection flows where possible.

## Commit & Pull Request Guidelines
- Commit messages follow a component prefix pattern, e.g. `Voyager: fix tab reorder` or `Wormhole: add token auth`.
- PRs should include a short problem/solution description, relevant issue links, and platform(s) tested.
- Include screenshots or short recordings for UI or terminal behavior changes.

## Configuration & Security
- `WORMHOLE_TOKEN` is required for the relay server; `PORT` defaults to `6666`.
- Do not commit secrets or host addresses; use env vars and local config where needed.

## WebSocket Protocol

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
| Stdin | 0x01 | Terminal input from client |
| Stdout | 0x02 | Terminal output to client |
| Resize | 0x03 | Terminal resize (cols, rows) |
| Ping | 0x04 | Heartbeat ping |
| Pong | 0x05 | Heartbeat pong |

### JSON Control Messages

Control messages use JSON format with `type` field:

| Type | Direction | Description |
|------|-----------|-------------|
| `session_assigned` | Wormhole → Horizon | Assigns 6-char session ID |
| `voyager_connect` | Wormhole → Horizon | Client connected |
| `voyager_disconnect` | Wormhole → Horizon | Client disconnected |
| `pairing_request` | Voyager → Horizon | Device pairing request |
| `pairing_response` | Horizon → Voyager | Accept/reject pairing |
| `pairing_result` | Horizon → Voyager | Pairing outcome |
| `list` | Voyager → Horizon | List terminal sessions |
| `create` | Voyager → Horizon | Create new terminal |
| `close` | Voyager → Horizon | Close terminal session |
| `group_*` | Both | Terminal group operations |

## Platform Channels (Flutter ↔ Native)

**MethodChannel:** `com.blackhole/pty`
- `create` - Create new PTY session
- `write` - Write to PTY stdin
- `resize` - Resize PTY
- `close` - Close PTY session

**EventChannel:** `com.blackhole/pty/output`
- Streams PTY stdout data to Dart

## Key Implementation Files

### Horizon
- `horizon_controller.dart` - Main state management
- `terminal_service.dart` - PTY interface
- `ws_server.dart` - LAN WebSocket server
- `PtyManager.swift/cc/cpp` - Native PTY per platform

### Voyager
- `connection_manager.dart` - WebSocket client
- `terminal_manager.dart` - Session state
- `hhkb_keyboard.dart` - Mobile keyboard

### Wormhole
- `main.rs` - Single-file Axum server
