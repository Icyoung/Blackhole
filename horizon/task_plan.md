# Task Plan: Horizon 模式本地 Terminal 直连

## Goal
在 Horizon 模式下，Terminal 直接与本地 PTY 交互，不经过任何网络服务；Voyager 模式保持现有的网络连接方式。

## Phases
- [x] Phase 1: 分析现有架构，理解 session 管理流程
- [x] Phase 2: 修改 HorizonController 暴露本地 session API
- [x] Phase 3: 修改 home_page 根据模式切换 session 来源
- [x] Phase 4: 测试并验证两种模式的切换

## Key Questions (已解答)
1. ✅ HorizonController 如何管理本地 PTY sessions？
   - `_terminal: TerminalPlugin` 管理 PTY
   - `_sessions: Set<String>` 存储 session IDs
2. ✅ 现有的 session 创建/关闭/输入/输出 API 是什么？
   - `_terminal.startShell()`, `_terminal.kill()`, `_terminal.writeStdin()`, `_terminal.resize()`
   - `_terminal.outputStream` 提供输出流
3. ✅ 切换模式时如何处理已有的 sessions？
   - 切换到 Horizon: 断开网络，订阅本地输出流
   - 切换到 Voyager: 取消本地订阅，使用 ConnectionManager

## Implementation Plan

### Phase 2: HorizonController 改动
添加公开 API:
```dart
// 暴露本地 session 列表
List<String> get localSessions => _sessions.toList();

// 暴露输出流
Stream<TerminalOutput> get localOutputStream => _terminal.outputStream;

// 本地创建 session
Future<String?> createLocalSession({String? groupId}) async { ... }

// 本地关闭 session
Future<void> closeLocalSession(String sessionId) async { ... }

// 本地写入 stdin
Future<void> writeLocalStdin(String sessionId, Uint8List data) async { ... }

// 本地 resize
Future<void> resizeLocalSession(String sessionId, int rows, int cols) async { ... }
```

### Phase 3: home_page 改动
1. 添加 `StreamSubscription<TerminalOutput>? _localOutputSub`
2. 修改 `_handleModeSwitch()`:
   - Horizon: 断开网络，订阅本地流，加载本地 sessions
   - Voyager: 取消本地订阅，使用 ConnectionManager
3. 修改所有 session 操作方法，根据 `_isHorizonMode` 分发

## Decisions Made
- 本地模式直接复用 HorizonController 的 TerminalPlugin，不走网络
- 两种模式共用同一套 UI 组件，只是数据来源不同

## Errors Encountered
- (无)

## Status
**Completed** - 功能已实现，待用户验证

## Summary
已实现 Horizon 模式本地 Terminal 直连功能：

### HorizonController 新增 API
- `localSessions` - 获取本地 session 列表
- `localOutputStream` - 本地输出流
- `createLocalSession()` - 创建本地 session
- `closeLocalSession()` - 关闭本地 session
- `writeLocalStdin()` - 写入本地 stdin
- `resizeLocalSession()` - 调整本地 session 大小
- `getLocalGroupSync()` - 获取 group 同步数据

### home_page 改动
- 添加 `_localOutputSub` 订阅本地输出
- `_handleModeSwitch()` 切换模式时切换数据源
- `_handleLocalOutput()` 处理本地输出
- `_loadLocalSessions()` 加载本地 sessions
- `_sendRaw()` / `_handleResize()` / `_sendCreateSession()` / `_sendCloseSession()` 根据模式分发到本地或网络 API
