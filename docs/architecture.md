# Blackhole - 技术架构设计文档

> 跨平台远程终端控制系统 | Vibe Coding Anywhere

---

## 目录

1. [系统整体架构](#1-系统整体架构)
2. [Horizon（Terminal Agent）详细设计](#2-horizonterminal-agent详细设计)
3. [Wormhole（中转服务）设计](#3-wormhole中转服务设计)
4. [Voyager（Remote Controller）设计](#4-voyagerremote-controller设计)
5. [通信协议设计](#5-通信协议设计)
6. [安全模型](#6-安全模型)
7. [代码组织结构](#7-代码组织结构)

## 相关文档

- `docs/ios-native-vpn.md`
- `docs/macos-vpn-helper.md`
- `docs/wg-direct-roadmap.md`
- `docs/remove-wg-relay.md`

VPN 三平面（控制 WS / WG UDP / 隧道内 PTY WS）以这些文档与决策 2276 / design `0b0fc273` 为准。本文其余章节有历史/愿景描述，**不要**把 `/wg-relay`、DERP、或物理网卡上的 app WS 当成当前数据面。

---

## 1. 系统整体架构

### 1.1 核心设计理念

```
「字符流透传，Wormhole 无持久化，Horizon 是唯一真相」
```

**设计原则：**
- **PTY-native**：操作真实 shell，保留完整上下文（history、env、AI session）
- **NAT-friendly**：WAN 模式下 Horizon 对公网不被动监听业务口，始终主动出连 Wormhole；LAN 模式可选监听 `:9527`
- **Wormhole 最小化**：内存路由 + 信令 + UDP netcheck（生产 **6666**，绝不是 443）。不解析 PTY，无持久化
- **Horizon daemon 是主机真相**：PTY、配对（`device_key` allowlist）、WG server 都在 `horizon-daemon`
- **渐进增强**：LAN / Wormhole WebSocket 始终作为控制面与 PTY 回退；配对后首选 WireGuard UDP + 隧道内 `ws://10.13.37.1:<lanPort>/ws`

### 1.2 命名体系

| 组件 | 命名 | 含义 | 运行平台 |
|------|------|------|----------|
| Terminal Agent | **Horizon** | 事件视界 - 终端的边界 | macOS / Windows / Linux |
| Remote Controller | **Voyager** | 旅行者号 - 远程探索者 | iOS / Android / Web / macOS |
| 中转服务 | **Wormhole** | 虫洞 - 穿越 NAT 的隧道 | Cloud Server |

### 1.3 架构总览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              NETWORK LAYER                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ┌─────────────────┐              ┌─────────────────┐                  │
│   │    Horizon      │              │    Voyager      │                  │
│   │ (Terminal Agent)│              │(Remote Control) │                  │
│   │                 │              │                 │                  │
│   │  ┌───────────┐  │              │  ┌───────────┐  │                  │
│   │  │  Flutter  │  │              │  │  Flutter  │  │                  │
│   │  │    UI     │  │              │  │    UI     │  │                  │
│   │  └─────┬─────┘  │              │  └─────┬─────┘  │                  │
│   │        │        │              │        │        │                  │
│   │  ┌─────┴─────┐  │              │  ┌─────┴─────┐  │                  │
│   │  │ Platform  │  │              │  │  Terminal │  │                  │
│   │  │  Plugin   │  │              │  │  Emulator │  │                  │
│   │  └─────┬─────┘  │              │  └───────────┘  │                  │
│   │        │        │              │                 │                  │
│   │  ┌─────┴─────┐  │              │                 │                  │
│   │  │ PTY/ConPTY│  │              │                 │                  │
│   │  │  + Shell  │  │              │                 │                  │
│   │  └───────────┘  │              │                 │                  │
│   └────────┬────────┘              └────────┬────────┘                  │
│            │                                │                            │
│            │ WebSocket (wss://)             │ WebSocket (wss://)        │
│            │                                │                            │
│            ▼                                ▼                            │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                          Wormhole                                │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │   │
│   │  │    Auth     │  │   Session   │  │     Stream Router       │  │   │
│   │  │   Gateway   │  │   Manager   │  │  (stdin/stdout/resize)  │  │   │
│   │  └─────────────┘  └─────────────┘  └─────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.4 网络模式

#### Mode 1: LAN 直连（低延迟优先）

```
┌──────────────┐                              ┌──────────────┐
│   Horizon    │◄────── mDNS Discovery ──────►│   Voyager    │
│  192.168.1.10│                              │  192.168.1.20│
│              │                              │              │
│   :9527      │◄═══════ WebSocket ══════════►│              │
│  (listener)  │         (direct)             │              │
└──────────────┘                              └──────────────┘
```

**流程：**
1. Horizon 启动时通过 mDNS 广播
2. Voyager 在同一局域网内发现 Horizon
3. 直接 WebSocket 连接，延迟 < 1ms

**LAN 安全模型：配对码 + 设备指纹**

| 机制 | 参数 | 说明 |
|------|------|------|
| TTL | 60 秒 | 配对码生成后 60 秒过期 |
| 尝试限制 | 3 次/码 | 失败后作废 |
| 冷却期 | 30 秒 | 连续失败后等待 |
| PAKE 绑定 | SPAKE2 | 配对码参与密钥交换 |

#### Mode 2: WAN 中转（NAT 穿透）

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Horizon    │         │   Wormhole   │         │   Voyager    │
│  (behind NAT)│         │   (云端)     │         │  (anywhere)  │
│              │         │              │         │              │
│              ├────────►│◄─────────────┤◄────────┤              │
│              │ connect │   session    │ connect │              │
│              │         │   bridge     │         │              │
└──────────────┘         └──────────────┘         └──────────────┘
```

**流程：**
1. Horizon 主动连接 Wormhole，维持长连接
2. Voyager 请求连接某个 Horizon 的 session
3. Wormhole 验证权限后建立双向管道（控制面 + 回退 PTY）

#### Mode 3: WireGuard Direct（首选 WAN 数据面）

三条平面，不是一条链路。**不要**把 WG-over-WebSocket / DERP / `/wg-relay` 当数据面（stub 保留，datapath 已删除）。

| 平面 | 传输 | 生命周期 | 承载 |
|------|------|----------|------|
| Control | Wormhole WSS（WAN）或 LAN `ws://<host>:9527/ws` | 连接/配对后始终在线 | 配对、分组、会话列表、VPN 信令（`endpoint_*`、`vpn_config`）、ping；也是 PTY 回退 |
| WG UDP | WireGuard → Horizon UDP **51820** | 配对后首选；打洞失败则可缺失 | `10.13.37.0/24` 加密 IP |
| Data (PTY) | 隧道内 `ws://10.13.37.1:<lanPort>/ws` | 仅当握手完成 **且** 该 socket 的 `host_info.vpnPeer==true` | 二进制 stdin/stdout/resize |

```
Voyager
  ├─ Control WS ──► Wormhole ──► Horizon daemon        (信令 + 回退 PTY)
  └─ Native WG/TUN ── WG UDP 51820 ──► Horizon WgServer
         └── PTY WS: ws://10.13.37.1:lanPort/ws（默认 9527）
```

**Handoff 主机永远是 `10.13.37.1`，不是物理网卡。** UI 只有在该 socket 上收到 `host_info.vpnPeer==true` 才显示 Direct。公网 WG 目的地址来自 STUN/netcheck 与/或 UPnP UDP，不是 Wormhole WebSocket 的 `IP:51820`。

macOS 本机投递：pf `rdr` 打在 **utun** 上，把 `10.13.37.1:lanPort` DNAT 到 `127.0.0.1:lanPort`。**不要** `lo0 alias 10.13.37.1`（决策 2087 / 2115 的 alias 条款已被 design `0b0fc273` / 决策 2276 取代）。macOS Voyager 走 userspace helper；Network Extension 仅为研究代码。

`BH_ENABLE_NATIVE_VPN` 编译默认 `true` **不是** 用户开关。用户开关是 `vpnEnabled`；新安装默认打开取决于 stay-up 门禁。

---

## 2. Horizon（Terminal Agent）详细设计

**当前运行时：** 主机侧真相是 `horizon-daemon`（Rust）：PTY/ConPTY、配对、分组、LAN/Wormhole WebSocket、WG server。Flutter 是设置与 UI shell，不再是 PTY 的权威实现。下面 2.1–2.3 保留历史平台通道描述，实施时以 daemon 为准。

### 2.1 整体架构

```
┌────────────────────────────────────────────────────────────────────┐
│                         Flutter Application                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                        Dart Layer                             │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐  │  │
│  │  │  Terminal   │  │  Connection │  │     Session          │  │  │
│  │  │  Service    │  │  Manager    │  │     Manager          │  │  │
│  │  └──────┬──────┘  └──────┬──────┘  └──────────────────────┘  │  │
│  │         │                │                                    │  │
│  │         │ MethodChannel  │ WebSocket                         │  │
│  │         ▼                ▼                                    │  │
│  │  ┌──────────────────────────────────────────────────────────┐│  │
│  │  │              Platform Channel Interface                   ││  │
│  │  │  • startShell(shellPath, env, size)                      ││  │
│  │  │  • writeStdin(bytes)                                     ││  │
│  │  │  • resizeTerminal(rows, cols)                            ││  │
│  │  │  • killShell()                                           ││  │
│  │  │  • Stream<Uint8List> stdout                              ││  │
│  │  └──────────────────────────────────────────────────────────┘│  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                │                                    │
│                                │ Platform Channel                   │
│                                ▼                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                     Native Plugin Layer                       │  │
│  │                                                               │  │
│  │   macOS/Linux                      Windows                    │  │
│  │   ┌─────────────────────┐        ┌─────────────────────┐     │  │
│  │   │    PtyManager       │        │   ConPtyManager     │     │  │
│  │   │    (forkpty)        │        │  (CreatePseudo-     │     │  │
│  │   │                     │        │   Console)          │     │  │
│  │   └─────────┬───────────┘        └─────────┬───────────┘     │  │
│  │             │                              │                 │  │
│  │             ▼                              ▼                 │  │
│  │   ┌─────────────────────┐        ┌─────────────────────┐     │  │
│  │   │   /bin/zsh          │        │   cmd.exe / pwsh    │     │  │
│  │   └─────────────────────┘        └─────────────────────┘     │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 Platform Channel 接口

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `startShell` | rows, cols, shellPath? | sessionId | 启动新 shell |
| `writeStdin` | sessionId, data | void | 写入 stdin |
| `resize` | sessionId, rows, cols | void | 调整终端尺寸 |
| `kill` | sessionId | void | 终止 shell |

**EventChannel**: `com.blackhole/pty/output` - stdout 数据流

### 2.3 平台 PTY 实现

| 特性 | macOS/Linux | Windows |
|------|-------------|---------|
| API | `forkpty()` | `CreatePseudoConsole()` |
| 信号 | SIGWINCH, SIGTERM | ResizePseudoConsole, TerminateProcess |
| 默认 Shell | `$SHELL` / `/bin/zsh` | PowerShell / cmd |
| 最低版本 | macOS 10.13, Ubuntu 18.04 | Windows 10 1809 |
| 读取模式 | 独立线程 + select/GCD | 独立线程 + ReadFile |
| Buffer 大小 | 4KB | 4KB |

### 2.4 Shell 生命周期

```
┌───────┐    startShell()    ┌──────────┐    success    ┌─────────┐
│ idle  │ ─────────────────► │ starting │ ────────────► │ running │
└───────┘                    └──────────┘               └────┬────┘
    ▲                                                        │
    │                        ┌──────────┐                    │ exit
    │  reset (after delay)   │ crashed  │ ◄── error ────────┤
    │ ◄───────────────────── │ (retry)  │                    │
    │                        └──────────┘                    ▼
    │                                                   ┌─────────┐
    └────────────── manual restart ◄─────────────────── │ exited  │
                                                        └─────────┘
```

**异常处理策略：**

| 场景 | 处理方式 |
|------|----------|
| Shell 正常退出 (exit 0) | 标记为 exited，等待手动重启 |
| Shell 异常退出 | 自动重启，最多 3 次，指数退避 |
| PTY 创建失败 | 抛出异常，UI 显示错误 |
| 写入失败（管道断裂） | 标记为 crashed，触发重启 |

### 2.5 终端分组功能

终端分组的**数据与规则由 Horizon 统一管理**，Voyager 仅负责 UI 展示。

**数据模型：**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | String | UUID，默认分组固定为 'default' |
| name | String | 分组名称 |
| sessionIds | List<String> | 终端会话 ID 列表 |
| createdAt | DateTime | 创建时间 |

**协议消息：**

| 方向 | 消息类型 | 说明 |
|------|----------|------|
| Voyager → Horizon | `group_list` | 请求分组快照 |
| Voyager → Horizon | `group_create` | 创建分组 |
| Voyager → Horizon | `group_rename` | 重命名分组 |
| Voyager → Horizon | `group_delete` | 删除分组 |
| Voyager → Horizon | `group_move_session` | 移动会话到分组 |
| Horizon → Voyager | `group_sync` | 完整快照（权威） |
| Horizon → Voyager | `group_error` | 操作失败原因 |

**数据不变量：**
1. 每个 sessionId 只能存在于一个分组中
2. 默认分组必须存在，不可删除
3. 断开的 session 及时清理
4. Voyager 只能通过指令请求，不能直接改动分组数据

---

## 3. Wormhole（中转服务）设计

### 3.1 核心职责

```
Wormhole 的黄金法则：
1. 我不知道你们在传什么（不解析内容 / 不解析 PTY）
2. 我只管谁能跟谁说话（权限控制 + VPN 信令转发）
3. 我尽量快（低延迟转发）
4. 我不持久化（重启即清空）
5. 我提供 UDP netcheck（生产 **UDP 6666**，绝不是 443）
6. 我不拥有 PTY / 配对 allowlist / WG server（那是 Horizon daemon）
7. `/wg-relay` 只保留 stub，不是数据面
```

**状态模型：**

| 状态类型 | 存储位置 | 生命周期 |
|----------|----------|----------|
| 会话状态 | 内存 HashMap | 进程生命周期 |
| 连接状态 | 内存 | 连接期间 |
| 认证缓存 | 内存 LRU | TTL 过期 |
| 持久数据 | **无** | N/A |

### 3.2 会话模型

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Session Model                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Horizon (Agent)                     Voyagers (Controllers)        │
│   ┌──────────────┐                    ┌──────────────┐              │
│   │  horizon_1   │◄───────────────────│  voyager_1   │ (owner)      │
│   │              │                    └──────────────┘              │
│   │  session:    │                    ┌──────────────┐              │
│   │  "ABC123"    │◄───────────────────│  voyager_2   │ (observer)   │
│   │              │                    └──────────────┘              │
│   └──────────────┘                                                  │
│                                                                      │
│   Session Attributes:                                               │
│   • session_id: 6 字符（如 "ABC123"）                                │
│   • horizon_id: Horizon 实例标识                                     │
│   • owner_id: 当前控制者                                            │
│   • observers: 观察者列表                                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.3 控制权仲裁

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| Exclusive | 单一控制者，其他人只能观察 | 默认模式 |
| RaceCondition | 谁先发谁生效 | 多人协作 |
| RoundRobin | 固定时间窗口轮询 | 教学演示 |

### 3.4 服务端架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                            Wormhole                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     WebSocket Gateway                          │ │
│   │                                                                │ │
│   │   /ws?role=horizon   <- Horizon 连接点                         │ │
│   │   /ws?role=voyager   <- Voyager 连接点                         │ │
│   │   /wg-relay          <- stub only（datapath removed）           │ │
│   │                                                                │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                              │                                       │
│                              ▼                                       │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     Message Router                             │ │
│   │                                                                │ │
│   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐ │ │
│   │   │   Auth      │   │   Rate      │   │    Session          │ │ │
│   │   │   Check     │──►│   Limiter   │──►│    Dispatch         │ │ │
│   │   └─────────────┘   └─────────────┘   └─────────────────────┘ │ │
│   │                                                                │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                              │                                       │
│                              ▼                                       │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     Session Store                              │ │
│   │                                                                │ │
│   │   sessions: HashMap<SessionId, Session>                        │ │
│   │   horizons: HashMap<HorizonId, WebSocket>                      │ │
│   │   voyagers: HashMap<VoyagerId, WebSocket>                      │ │
│   │                                                                │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**技术栈：** Rust + Axum + Tokio

---

## 4. Voyager（Remote Controller）设计

### 4.1 技术方案

| 方案 | 优点 | 缺点 | 推荐场景 |
|------|------|------|----------|
| **Flutter App** | 原生体验、推送支持 | 需要安装 | 日常使用 |
| **Web App (PWA)** | 无需安装、跨平台 | 浏览器限制 | 临时使用 |

**推荐：Flutter App 为主，Web 为辅**

### 4.2 终端渲染架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Terminal Renderer                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     Input Layer                                │ │
│   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐ │ │
│   │   │  Keyboard   │   │   Gesture   │   │   Virtual           │ │ │
│   │   │  (physical) │   │  (touch)    │   │   Keyboard          │ │ │
│   │   └──────┬──────┘   └──────┬──────┘   └──────────┬──────────┘ │ │
│   │          └─────────────────┼─────────────────────┘            │ │
│   │                            ▼                                   │ │
│   │              ┌─────────────────────────┐                      │ │
│   │              │    Input Translator     │                      │ │
│   │              │  (key -> escape seq)    │                      │ │
│   │              └─────────────────────────┘                      │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                                │                                     │
│                                ▼                                     │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     ANSI Parser                                │ │
│   │   ESC[31m  -> SetForeground(Red)                              │ │
│   │   ESC[2J   -> ClearScreen                                      │ │
│   │   ESC[10;5H -> MoveCursor(row=10, col=5)                       │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                                │                                     │
│                                ▼                                     │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     Screen Buffer                              │ │
│   │   Cell[row][col] = { char, fg, bg, attrs }                     │ │
│   │   Scrollback buffer: 10000 lines (configurable)                │ │
│   │   Alternate screen support: yes (vim, less, etc.)              │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                                │                                     │
│                                ▼                                     │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │                     Render Layer                               │ │
│   │   Flutter: CustomPainter / Canvas                              │ │
│   │   Web: Canvas 2D                                               │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**终端渲染库：** xterm.dart

### 4.3 手机输入方案

**修饰键栏：**
```
┌──────────────────────────────────────────────────────┐
│  Ctrl │  Alt │  Esc │  Tab │  ↑  │  ↓  │  ←  │  →  │
└──────────────────────────────────────────────────────┘
```

**快捷操作菜单（双击触发）：**

| 操作 | 发送 | 操作 | 发送 |
|------|------|------|------|
| Copy | 复制选区 | Paste | 粘贴剪贴板 |
| Ctrl+C | `\x03` | Ctrl+D | `\x04` |
| Clear | `clear\n` | Ctrl+Z | `\x1a` |
| Ctrl+R | `\x12` | Scroll Top | 滚动到顶部 |

### 4.4 按键映射

| 按键 | 转义序列 | 按键 | 转义序列 |
|------|----------|------|----------|
| F1-F4 | `\x1bOP` - `\x1bOS` | ArrowUp | `\x1b[A` |
| F5-F12 | `\x1b[15~` - `\x1b[24~` | ArrowDown | `\x1b[B` |
| Home | `\x1b[H` | ArrowRight | `\x1b[C` |
| End | `\x1b[F` | ArrowLeft | `\x1b[D` |
| PageUp | `\x1b[5~` | Delete | `\x1b[3~` |

**修饰键处理：**
- Ctrl + 字母 → 控制字符（Ctrl+A = 0x01）
- Alt + 字符 → ESC + 字符

---

## 5. 通信协议设计

### 5.1 协议选择

选择 **二进制协议** 而非 JSON：
- 终端数据本身是二进制（含控制字符）
- JSON 编码增加 33% 体积（base64）
- 低延迟要求

### 5.2 帧格式

```
Binary Frame Format
===================

┌─────────────────────────────────────────────────────────────────────┐
│                           Frame Header (8 bytes)                     │
├──────────┬──────────┬──────────┬────────────────────────────────────┤
│  Magic   │   Type   │  Flags   │           Payload Length           │
│ (2 bytes)│ (1 byte) │ (1 byte) │             (4 bytes)              │
│   0x42   │          │          │          (big-endian)              │
│   0x48   │          │          │                                    │
├──────────┴──────────┴──────────┴────────────────────────────────────┤
│                        Payload (variable)                            │
└─────────────────────────────────────────────────────────────────────┘

Magic: 0x4248 ("BH" = BlackHole)
```

### 5.3 消息类型

| Type | 值 | 方向 | 说明 |
|------|-----|------|------|
| Hello | 0x01 | C→S | 认证握手 |
| HelloAck | 0x02 | S→C | 认证响应 |
| Stdin | 0x03 | V→H | 终端输入 |
| Stdout | 0x04 | H→V | 终端输出 |
| Resize | 0x05 | V→H | 终端尺寸变更 |
| Ping | 0x06 | 双向 | 心跳请求 |
| Pong | 0x07 | 双向 | 心跳响应 |
| Control | 0x08 | V→W | 控制权请求 |
| Error | 0x09 | S→C | 错误通知 |
| SessionEvent | 0x0A | S→C | 会话事件 |

### 5.4 心跳与重连

| 参数 | 值 | 说明 |
|------|-----|------|
| Ping 间隔 | 30 秒 | 定时发送 |
| Pong 超时 | 10 秒 | 超时视为断连 |
| 最大重试 | 10 次 | 超过后停止 |
| 基础延迟 | 1 秒 | 指数退避起点 |
| 最大延迟 | 60 秒 | 退避上限 |
| 抖动 | ±25% | 避免惊群效应 |

### 5.5 流控策略

| 参数 | 值 | 说明 |
|------|-----|------|
| 最大待发送 | 256 KB | 超过暂停读取 PTY |
| 恢复阈值 | 128 KB | 低于此值恢复读取 |

---

## 6. 安全模型

### 6.1 威胁模型

| 威胁 | 严重性 | 缓解措施 |
|------|--------|----------|
| 未授权访问终端 | 高 | 设备绑定 + Token 认证 |
| 中间人攻击 | 高 | TLS 强制 |
| 会话劫持 | 高 | Token 绑定设备密钥 |
| Wormhole 窥视内容 | 中 | 端到端加密（可选） |
| 暴力破解 | 中 | 速率限制 + 锁定 |

### 6.2 Token 体系

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Token Hierarchy                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Master Key (用户密码管理器)                                         │
│       │                                                              │
│       ├──► Horizon Key (每个 Horizon 实例唯一，永久有效)              │
│       │       │                                                      │
│       │       └──► Session Token (24小时，自动刷新)                  │
│       │                                                              │
│       └──► Voyager Token (每个 Voyager 实例唯一，30天有效)            │
│               │                                                      │
│               └──► Access Token (会话期间，绑定 session_id)          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**Token 绑定策略：**
- 主绑定因子：设备密钥（Device Key）
- 辅助风险信号：IP 地址（仅用于异常检测，不做强绑定）

### 6.3 认证流程

```
┌─────────────┐                    ┌─────────────┐                    ┌─────────────┐
│   Horizon   │                    │  Wormhole   │                    │   Voyager   │
└──────┬──────┘                    └──────┬──────┘                    └──────┬──────┘
       │                                  │                                  │
       │ ① Hello(horizon_key)             │                                  │
       │─────────────────────────────────►│                                  │
       │                                  │                                  │
       │ ② HelloAck(session_id, token)    │                                  │
       │◄─────────────────────────────────│                                  │
       │                                  │                                  │
       │                                  │     ③ Hello(voyager_token)      │
       │                                  │◄─────────────────────────────────│
       │                                  │                                  │
       │                                  │  ④ HelloAck(sessions[])         │
       │                                  │─────────────────────────────────►│
       │                                  │                                  │
       │                                  │  ⑤ JoinSession(session_id)      │
       │                                  │◄─────────────────────────────────│
       │                                  │                                  │
       │                                  │  ⑥ JoinAck(access_token)        │
       │                                  │─────────────────────────────────►│
       │                                  │                                  │
       │◄═══════════════════════════════════════════════════════════════════►│
       │                    双向数据流开始                                   │
```

### 6.4 端到端加密（可选）

```
E2E Encryption
==============

方案：X25519 密钥交换 + ChaCha20-Poly1305

┌─────────────┐                    ┌─────────────┐
│   Horizon   │                    │   Voyager   │
└──────┬──────┘                    └──────┬──────┘
       │                                  │
       │ ① 生成临时 X25519 密钥对          │
       │                                  │
       │ ② 发送 h_public ────────────────►│
       │                                  │
       │                  生成密钥对并计算 shared
       │                                  │
       │◄──────────────── 发送 v_public   │
       │                                  │
       │ 计算 shared                       │
       │                                  │
       │◄═══════════════════════════════►│
       │   ChaCha20-Poly1305 加密通信     │
```

**信任决策：**

| 部署场景 | E2E 必要性 |
|----------|-----------|
| 自部署 Wormhole + 自有服务器 | 可选 |
| 自部署 Wormhole + 云 VPS | 推荐 |
| 使用公共 Wormhole 服务 | **强制** |

---

## 7. 代码组织结构

### 7.1 模块化设计

```
lib/
├── main.dart                    # 入口，配置初始化
└── src/
    ├── app.dart                 # MaterialApp 配置
    ├── pages/
    │   └── home_page.dart       # 主页面
    ├── controllers/
    │   └── horizon_controller.dart  # 核心控制器 (Horizon)
    ├── models/
    │   ├── terminal_group.dart      # 分组数据模型
    │   └── dev_mode_config.dart     # 开发模式配置
    ├── services/
    │   ├── terminal_service.dart    # PTY 平台通道接口
    │   ├── connection_manager.dart  # WebSocket 连接管理
    │   ├── terminal_manager.dart    # 终端实例管理
    │   ├── group_manager.dart       # 分组业务逻辑
    │   ├── group_store.dart         # 分组本地状态
    │   └── ws_server.dart           # WebSocket 服务器 (Horizon)
    └── widgets/
        ├── common/                  # 通用组件
        ├── cards/                   # 卡片组件 (Horizon)
        ├── chrome/                  # 标签栏组件
        ├── keyboard/                # 虚拟键盘
        ├── group_drawer.dart        # 分组抽屉
        ├── settings_drawer.dart     # 设置抽屉
        └── terminal_window_card.dart
```

### 7.2 Services 层职责

| Service | 职责 | 生命周期 |
|---------|------|----------|
| `ConnectionManager` | WebSocket 连接、协议处理、重连 | 跟随 HomePage |
| `TerminalManager` | 终端实例管理、滚动控制 | 跟随 HomePage |
| `GroupManager` | 分组 CRUD、持久化、会话生命周期 | 跟随 Controller |

### 7.3 平台特定代码

| 平台 | 文件位置 | 实现 |
|------|----------|------|
| macOS | `horizon/macos/Runner/PtyManager.swift` | forkpty + GCD |
| Linux | `horizon/linux/runner/pty_manager.cc` | forkpty + thread |
| Windows | `horizon/windows/runner/pty_manager.cpp` | ConPTY |

**Platform Channel：**
- MethodChannel: `com.blackhole/pty`
- EventChannel: `com.blackhole/pty/output`

---

## 附录 A: 术语表

| 术语 | 定义 |
|------|------|
| **Horizon** | 🌑 事件视界 - 运行在桌面端的 Terminal Agent |
| **Voyager** | 🚀 旅行者号 - 运行在移动端的远程控制器 |
| **Wormhole** | 🕳️ 虫洞 - 中转服务器 |
| **PTY** | Pseudo Terminal，Unix 伪终端 |
| **ConPTY** | Windows Console Pseudo Terminal |
| **Session** | 一个 Horizon 与多个 Voyager 之间的会话 |
| **Owner** | 当前拥有输入控制权的 Voyager |
| **Observer** | 只读观察模式的 Voyager |
| **WG Direct** | WireGuard UDP + 隧道内 `ws://10.13.37.1:<lanPort>/ws`；UI 需 `vpnPeer==true` |
| **Control WS** | 始终在线的 Wormhole/LAN WebSocket；信令 + PTY 回退 |

---

*文档版本: 2.1.0*
*最后更新: 2026-08-25*
*项目代号: Blackhole*
