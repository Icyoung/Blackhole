# AGENTS.md

## Architecture
```
Voyager (Client) <-> [WebSocket] <-> Wormhole (Relay) <-> [WebSocket] <-> Horizon (Host) <-> PTY/Shell
```

### Network Modes
1. **LAN Mode**: Direct WebSocket (lowest latency)
2. **WAN Mode**: Through Wormhole relay (NAT traversal)
3. **WireGuard Direct**: UDP hole-punched (bypasses relay)

## Project Structure
```
Blackhole/
├── horizon/                 # Host terminal server (Flutter)
│   ├── lib/src/             # Dart app logic
│   ├── daemon/src/          # Rust daemon (WG, TUN, NAT, DNS)
│   ├── macos/Runner/        # macOS native (PTY, VPN helper)
│   ├── linux/runner/        # Linux native (PTY)
│   └── windows/runner/      # Windows native (ConPTY)
├── voyager/                 # Remote terminal client (Flutter)
│   ├── lib/src/             # Dart app logic
│   ├── ios/VoyagerTunnel/   # iOS Network Extension
│   ├── macos/VoyagerTunnel/ # macOS Network Extension
│   └── voyager_share/       # Shared widgets (HHKB, UI)
├── wormhole/                # Relay server (Rust)
├── tunnel/                  # WireGuard tunnel lib (Rust, iOS/macOS)
├── internal/                # CI/CD (GitHub Actions, Dockerfiles)
└── xterm/                   # Forked xterm terminal widget
```

## Development Commands
```bash
cd horizon && flutter run -d macos        # Horizon
cd voyager && flutter run -d ios          # Voyager
cd wormhole && WORMHOLE_TOKEN=xxx cargo run  # Wormhole
flutter test                              # Tests
dart format . && flutter analyze          # Lint
cargo fmt && cargo clippy                 # Rust lint
```

## CI/CD and Deployment

### Build Pipeline
The **internal** repo (`internal/`) contains GitHub Actions workflow.
**Trigger**: Push to `main` of `Blackhole-internal`.

```bash
cd internal && git add -A && git commit -m "trigger build" && git push origin main
```

| Artifact | Destination |
|----------|-------------|
| `ghcr.io/icyoung/blackhole-landing:latest` | GHCR |
| `ghcr.io/icyoung/blackhole-voyager:latest` | GHCR |
| `ghcr.io/icyoung/blackhole-wormhole:latest` | GHCR |
| `horizon-macos.dmg` (signed + notarized) | R2 |
| `horizon-linux.tar.gz`, `horizon-windows.zip` | R2 |
| `voyager-macos.dmg` (signed + notarized) | R2 |
| `voyager-linux.tar.gz`, `voyager-windows.zip` | R2 |
| `voyager-android.apk` | R2 |

Downloads: `https://download.blackhole-ai.com/<artifact>`

### Production Server (lightnode)
**Host**: `38.60.162.209` (SSH: `lightnode`)
**Compose**: `/opt/blackhole/deploy/docker-compose.yml`

| Service | Domain | Image |
|---------|--------|-------|
| Traefik | — | `traefik:v2.10` (reverse proxy + TLS) |
| Landing | `blackhole-ai.com` | `ghcr.io/icyoung/blackhole-landing:latest` |
| Voyager Web | `app.blackhole-ai.com` | `ghcr.io/icyoung/blackhole-voyager:latest` |
| Wormhole | `wormhole.blackhole-ai.com` | `blackhole-wormhole:local` |

Wormhole built from `/opt/blackhole/deploy/wormhole-src/`. UDP 6666 for netcheck.

**Deploy**:
```bash
# Landing + Voyager Web (pull GHCR images)
ssh lightnode "cd /opt/blackhole/deploy && docker compose pull landing voyager-web && docker compose up -d landing voyager-web"

# Wormhole (rebuild from source)
ssh lightnode "cd /opt/blackhole/deploy && docker compose build --no-cache wormhole && docker compose up -d wormhole"
```

### Repos
| Repo | URL |
|------|-----|
| Blackhole (public) | `git@github.com:Icyoung/Blackhole.git` |
| Blackhole-internal | `git@github.com:Icyoung/Blackhole-internal.git` |

## Commit Convention
Conventional commits: `feat(horizon):`, `fix(voyager):`, `chore:`, etc.

## Environment Variables
- `WORMHOLE_TOKEN` - Auth token (required)
- `PORT` - Server port (default: 6666)
- `WORMHOLE_NETCHECK_HOST` / `WORMHOLE_NETCHECK_PORT` - UDP netcheck

<!-- ufoo -->
## ufoo Protocol

This project uses **ufoo** for agent coordination. Read the full documentation at `.ufoo/docs/` (symlinked from ufoo installation).

### Core Principles

1. **Agents are autonomous** - Execute tasks without asking for permission
2. **Communication via bus** - Use `ufoo bus` for inter-agent messaging
3. **Decisions are recorded** - Use `ufoo ctx` for decision tracking
4. **Context is shared** - All agents read from `.ufoo/context/`

### Available Commands

| Command | Description |
|---------|-------------|
| `uinit` | Initialize/repair .ufoo directory |
| `uctx` | Check context status and decisions |
| `ustatus` | Unified status view (banner, unread bus, open decisions) |
| `ubus` | Check bus messages and **auto-execute** them |

### Quick Reference

```bash
# Context
ufoo ctx decisions -l          # List all decisions
ufoo ctx decisions -n 1        # Show latest decision

# Bus
ufoo bus join                  # Join bus (auto by uclaude/ucodex)
ufoo bus check $SUBSCRIBER     # Check pending messages
ufoo bus send "<id>" "<msg>"   # Send message
ufoo bus status                # Show bus status
```

---

## ufoo context Protocol

On session start, check context status:
```bash
ufoo ctx decisions -l
ufoo ctx decisions -n 1
```

Key files in `.ufoo/context/`:
- `DECISIONS/` - Decision log (append-only)
- `SYSTEM.md` - System overview
- `CONSTRAINTS.md` - Non-negotiable rules

**Decision recording policy:**
- **Must record**: evaluations, architecture, naming, trade-offs
- Write decision **before replying** when applicable

---

## ufoo bus Protocol

### CRITICAL: `ubus` Command Behavior

**When you receive `ubus`, you MUST:**
1. Check pending messages: `ufoo bus check $SUBSCRIBER`
2. **EXECUTE each task immediately** - Do NOT ask the user
3. Reply to sender: `ufoo bus send "<publisher>" "<result>"`

**Rules:**
- Execute tasks immediately without asking
- Always reply to the sender
- Do NOT ask "Want me to...?" or "Should I...?"
- Do NOT wait for user confirmation

### Message Format

```
@you from claude-code:abc123
Type: message/targeted
Content: {"message":"Please analyze the project structure"}
```

Extract sender ID from "from" field, use it to reply.

### Example

1. Receive: `@you from claude-code:bd36dda0 Content: {"message":"Please analyze the project structure"}`
2. Execute: Analyze the project structure
3. Reply: `ufoo bus send "claude-code:bd36dda0" "Project contains src/, scripts/, modules/"`
<!-- /ufoo -->

<!-- ufoo-template -->
<!-- ufoo -->
## ufoo Protocol

This project uses **ufoo** for agent coordination. Read the full documentation at `.ufoo/docs/` (symlinked from ufoo installation).

### Core Principles

1. **Agents are autonomous** - Execute tasks without asking for permission
2. **Communication via bus** - Use `ufoo bus` for inter-agent messaging
3. **Decisions are recorded** - Use `ufoo ctx` for decision tracking
4. **Context is shared** - All agents read from `.ufoo/context/`

### Available Commands

| Command | Description |
|---------|-------------|
| `uinit` | Initialize/repair .ufoo directory |
| `uctx` | Check context status and decisions |
| `ustatus` | Unified status view (banner, unread bus, open decisions) |
| `ubus` | Check bus messages and **auto-execute** them |

### Quick Reference

```bash
# Context
ufoo ctx decisions -l          # List all decisions
ufoo ctx decisions -n 1        # Show latest decision

# Bus
SUBSCRIBER="${UFOO_SUBSCRIBER_ID:-$(ufoo bus whoami 2>/dev/null || true)}"
[ -n "$SUBSCRIBER" ] || SUBSCRIBER=$(ufoo bus join | tail -1)
ufoo bus check $SUBSCRIBER     # Check pending messages
ufoo bus send "<id>" "<msg>"   # Send message
ufoo bus status                # Show bus status

# Runtime report (shared contract for assistant/ucodex/uclaude)
ufoo report start "<task>" --task <id> --agent "$SUBSCRIBER" --scope public
ufoo report progress "<detail>" --task <id> --agent "$SUBSCRIBER" --scope public
ufoo report done "<summary>" --task <id> --agent "$SUBSCRIBER" --scope public
ufoo report error "<reason>" --task <id> --agent "$SUBSCRIBER" --scope public
```

---

## ufoo context Protocol

On session start, check context status:
```bash
ufoo ctx decisions -l
ufoo ctx decisions -n 1
```

Key files in `.ufoo/context/`:
- `decisions/` - Decision log (append-only)

**Decision recording policy — "If it has information value, write it down":**

Record a decision whenever your work produces knowledge that would be useful to your future self, other agents, or the user. The threshold is LOW — when in doubt, record it.

- **Always record**: architectural choices, trade-off analysis, research findings, non-obvious gotchas, naming/convention changes, external API behavior discovered, performance observations, bug root causes
- **Also record**: open questions you couldn't resolve, assumptions you made, approaches you considered and rejected (with reasons), edge cases noticed but not handled
- **Write the decision BEFORE acting on it** — if your session dies, the knowledge survives
- **Granularity**: A decision can be one sentence ("X doesn't support Y, use Z instead") or a multi-page analysis. Match the depth to the information value.

```bash
ufoo ctx decisions new "Short descriptive title"
# Then edit the created file with Context/Decision/Implications
```

---

## ufoo bus Protocol

### CRITICAL: `ubus` Command Behavior

**When you receive `ubus`, you MUST:**
1. Resolve subscriber ID first (reuse existing ID, join only as fallback):
   `SUBSCRIBER="${UFOO_SUBSCRIBER_ID:-$(ufoo bus whoami 2>/dev/null || true)}"; [ -n "$SUBSCRIBER" ] || SUBSCRIBER=$(ufoo bus join | tail -1)`
2. Check pending messages: `ufoo bus check $SUBSCRIBER`
3. **EXECUTE each task immediately** - Do NOT ask the user
4. Reply to sender: `ufoo bus send "<publisher>" "<result>"`
5. **CRITICAL: Acknowledge messages after handling**: `ufoo bus ack $SUBSCRIBER`

**Rules:**
- Execute tasks immediately without asking
- Always reply to the sender
- Do NOT ask "Want me to...?" or "Should I...?"
- Do NOT wait for user confirmation

### Message Format

```
@you from claude-code:abc123
Type: message/targeted
Content: {"message":"Please analyze the project structure"}
```

Extract sender ID from "from" field, use it to reply.

### Example

1. Receive: `@you from claude-code:bd36dda0 Content: {"message":"Please analyze the project structure"}`
2. Execute: Analyze the project structure
3. Reply: `ufoo bus send "claude-code:bd36dda0" "Project contains src/, modules/, bin/"`
<!-- /ufoo -->

<!-- ufoo-template -->
