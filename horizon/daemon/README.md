# horizon-daemon

Rust host “daemon” process for Blackhole Horizon.

This runs as a standalone daemon/headless server:
- **LAN mode:** serves `ws://<bind>:<port>/ws`
- **Wormhole mode:** connects to a Wormhole relay when `WORMHOLE_URL` is set

## Run

```bash
cd horizon/daemon
cargo run -- --bind 0.0.0.0 --port 9527
```

## PID file / lifecycle

The daemon writes a pid file to:

- `~/.blackhole/horizon/daemon.pid`

Desktop builds of Horizon (Flutter shell) will try to stop the daemon when you choose **Quit** from the tray/menu-bar menu.

The daemon is single-instance: if the pidfile points to a running process, a second start will exit.

## Windows notes

On Windows, the daemon uses ConPTY (Windows 10+). If you don’t pass `--shell`, it defaults to `COMSPEC` (usually `cmd.exe`).

### Wormhole mode

```bash
WORMHOLE_URL=ws://your-wormhole-host:6666/ws \
WORMHOLE_TOKEN=your-secret-token \
cd horizon/daemon && cargo run -- --dev-mode
```

## HTTP endpoints

- `GET /health`
- `GET /status`
- `POST /shutdown` (loopback-only)
