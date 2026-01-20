# Notes: Horizon 本地 Terminal 直连

## 现有架构分析

### HorizonController 核心组件
- `_terminal: TerminalPlugin` - 管理本地 PTY 进程
- `_sessions: Set<String>` - 活跃的 session ID 集合
- `_wsServer: WsServer` - LAN WebSocket 服务器
- `_wormholeSocket` - Wormhole WebSocket 连接

### Session 生命周期 API
| 方法 | 功能 |
|------|------|
| `_createSession()` | 调用 `_terminal.startShell()` 创建 PTY |
| `_closeSession(sessionId)` | 调用 `_terminal.kill(sessionId)` 关闭 PTY |
| `_killAllSessions()` | 关闭所有 session |

### Terminal I/O
| 操作 | 当前实现 |
|------|----------|
| **Output** | `_terminal.outputStream` → `_handleTerminalOutput()` → 广播到网络客户端 |
| **Input** | 网络消息 → `_terminal.writeStdin(sessionId, bytes)` |
| **Resize** | 网络消息 → `_terminal.resize(sessionId, rows, cols)` |

### 需要暴露的本地 API
1. `Stream<TerminalOutput> get localOutputStream` - 直接暴露 terminal 输出流
2. `Future<String?> createLocalSession()` - 本地创建 session
3. `Future<void> closeLocalSession(sessionId)` - 本地关闭 session
4. `void writeLocalStdin(sessionId, data)` - 本地写入 stdin
5. `void resizeLocalSession(sessionId, rows, cols)` - 本地调整大小
6. `List<String> get localSessions` - 获取本地 session 列表

### home_page 改动点
1. 添加 `StreamSubscription<TerminalOutput>?` 用于本地输出监听
2. `_handleModeSwitch()` 切换时:
   - Horizon → 断开网络连接，订阅本地输出流
   - Voyager → 取消本地订阅，使用 ConnectionManager
3. 所有 session 操作根据模式分发到不同的 handler

### 切换模式时的处理
1. **切换到 Horizon 模式**:
   - 断开 ConnectionManager
   - 订阅 `hostController.localOutputStream`
   - 清空现有 sessions，重新从 hostController 获取本地 sessions

2. **切换到 Voyager 模式**:
   - 取消本地输出订阅
   - 通过 ConnectionManager 连接远程/本地服务器
   - 清空 sessions，等待服务器下发 session list
