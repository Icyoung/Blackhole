# Blackhole NAT 穿透 + VPN 方案 代码审查报告

> 审查日期: 2026-02-27
> 覆盖范围: 6 阶段全部实现代码（Wormhole / blackhole-wg / Horizon daemon / Voyager / iOS+macOS NE）

---

## 🔴 Critical（6 项）

### C-1: macOS utun 读写缺少 4 字节 AF 头部

**文件**: `horizon/daemon/src/wg_server.rs` — `AsyncTun::read/write`
**文件**: `horizon/daemon/src/tun_device.rs` — `SOCK_DGRAM`

macOS utun 设备使用 `SOCK_DGRAM` 模式创建。每个读操作前面有 4 字节的 protocol family header（`AF_INET = 0x00000002`），写操作也必须在 IP 包前面加这 4 字节。

当前实现直接用 `libc::read/write` 读写裸 IP 包，没有处理 AF 头部：
- **读方向**: `tun_buf` 前 4 字节是 AF 头部非 IP 头部，`handle_tun_packet` 按 IPv4 偏移提取目标地址（`packet[16..20]`）将读错位置
- **写方向**: boringtun 解密的 IP 包直接写入 utun，缺少 AF 头部，内核会拒绝

**影响**: macOS 上整个 VPN 数据通路完全不工作。

---

### C-2: 私钥以空字符串传给 Network Extension

**文件**: `voyager/lib/src/pages/home_page.dart` — `_toggleVpn()`

```dart
_vpnService.start(VpnConfig(
  privateKey: '', // Will be generated/loaded by NE from keychain
  ...
));
```

注释说 NE 会从 Keychain 生成/加载密钥，但 `PacketTunnelProvider.swift` 实际从 App Group JSON 文件读取 `privateKey` 字段并传给 `bh_wg_tunnel_new`。空字符串 → base64 解码 0 字节 → `WgTunnel::new` 报错 "private key must be 32 bytes, got 0"。

**影响**: 没有任何代码路径生成客户端密钥对并将公钥发送给 Horizon。VPN 隧道创建必定失败。

---

### C-3: `peer_endpoint` 收到后未调用 `WgServer::add_peer`

**文件**: `horizon/daemon/src/main.rs` — `"peer_endpoint"` handler

```rust
"peer_endpoint" => {
    // A Voyager has requested VPN connection — log for now.
    info!(...);
}
```

Horizon 收到 Voyager 的端点信息后仅做日志记录。`WgServer` 实例在 `start_vpn_server` 的 spawn 任务中，AppState 无引用，handler 无法调用 `add_peer`。

**影响**: 远端 Voyager 客户端的公钥永远不会被注册为 WG peer，入站 WireGuard 握手包将被丢弃。

---

### C-4: FFI 线程安全 — `&mut WgTunnel` 无同步保护

**文件**: `blackhole-wg/src/ffi.rs` — `bh_wg_encapsulate`, `bh_wg_decapsulate`

FFI 函数通过 `&mut *(tunnel as *mut WgTunnel)` 获取可变引用。Swift 的 `PacketTunnelProvider` 从 3 个不同 dispatch queue 调用：
- `readPacketsFromTUN` 回调 → `encapsulate`
- UDP read handler → `decapsulate`
- `DispatchQueue.global()` timer → `update_timers`

**影响**: 并发 `&mut` 是 Rust 未定义行为。boringtun 的 `Tunn` 内部有计数器和握手状态机，并发访问将导致数据损坏、panic 或加密错误。

**修复建议**: 在 Swift 侧使用串行 dispatch queue 序列化所有 FFI 调用，或在 Rust FFI 层加 Mutex。

---

### C-5: VpnPlugin 未在 AppDelegate 中注册

**文件**: `voyager/ios/Runner/AppDelegate.swift`
**文件**: `voyager/macos/Runner/AppDelegate.swift`

`VpnPlugin` 是手动创建的 native 插件，不在 `GeneratedPluginRegistrant` 自动注册列表中。需要手动添加：

```swift
VpnPlugin.register(with: self.registrar(forPlugin: "VpnPlugin"))
```

**影响**: Flutter 端 `MethodChannel('com.blackhole.voyager/vpn')` 调用将抛 `MissingPluginException`。

---

### C-6: VoyagerTunnel target 未添加到 Xcode 项目

**文件**: `voyager/ios/Runner.xcodeproj/project.pbxproj`
**文件**: `voyager/macos/Runner.xcodeproj/project.pbxproj`

`VoyagerTunnel/` 目录下的 Swift 文件存在，但 `.xcodeproj` 中没有 VoyagerTunnel 的任何引用：
- Swift 文件不会被编译
- 没有 NE target 的 build settings（bundle ID、signing、entitlements）
- `BlackholeWG.xcframework` 没有链接目标
- 主 App 不会嵌入 NE extension 的 `.appex`

**影响**: Network Extension 完全不存在于构建产物中。

---

## 🟡 Important（10 项）

### I-1: boringtun drain 在 Swift 端不工作

**文件**: `voyager/ios/VoyagerTunnel/PacketTunnelProvider.swift` — `drainTunnel()`

`drainTunnel()` 对空 src 调用 `bh_wg_decapsulate(handle, nil, 0, ...)`，但 FFI 的 `src.is_null()` 检查（`ffi.rs` 第 133 行）直接返回 `BH_WG_ERR`(-1)。

**影响**: 握手后 boringtun 缓存的数据包将丢失。需要修改 FFI 允许 src 为 null（表示 drain），或者 Swift 端传一个非 null 的空 buffer。

---

### I-2: Relay 帧格式偏离计划

**计划**: `[0x06 (wg_relay)] [session_id] [encrypted_wg_packet]`
**实现**: 直接转发原始二进制帧，无前缀

当前实现简化了帧格式，但无法区分消息类型或在同一 WebSocket 上复用其他数据。如果未来需要混合终端和 VPN 流量，需重构。

---

### I-3: DNS query ID 碰撞

**文件**: `horizon/daemon/src/dns_forwarder.rs`

`pending: HashMap<u16, PendingQuery>` 用 16-bit DNS query ID 作 key。多个 VPN 客户端使用相同 query ID 时，后者覆盖前者，前者永远收不到 DNS 响应。

**修复**: 用 `(SocketAddr, u16)` 元组作 key，或 remap query ID。

---

### I-4: WgServer peers 以 SocketAddr 为 key，placeholder 碰撞

**文件**: `horizon/daemon/src/wg_server.rs` — `add_peer()`

endpoint 未知时使用 `0.0.0.0:0` 作 placeholder。添加第二个 endpoint 未知的 peer 会覆盖第一个。

**修复**: 使用 peer public key 作为主 key，SocketAddr 仅用于快速查找。

---

### I-5: App Group 状态信息回传链路断裂

**文件**: `voyager/ios/VoyagerTunnel/PacketTunnelProvider.swift` — `updateStatus()`
**文件**: `voyager/ios/Runner/VpnPlugin.swift` — `notifyStatusChange()`

NE 写入 `TunnelStatus` 到 App Group 文件，但 `VpnPlugin` 不读此文件 — 通过 `NETunnelProviderManager` 查 connection status，且只返回 `status` 字段。Flutter 端 `VpnService` 尝试读取的 `connectionMode`、`clientIp`、`serverIp` 永远为 null。

**修复**: VpnPlugin 应读 App Group 的 status JSON 文件，合并 NE connection status 和详细信息。

---

### I-6: observed IP 是 TCP 地址不是 UDP

**文件**: `wormhole/src/main.rs` — `endpoint_registered` 回复

`remote_addr` 是 WebSocket TCP 连接的源 IP:port，不是 WireGuard UDP socket 的 NAT 映射。TCP/UDP NAT 映射通常不同（不同端口，有时不同 IP）。

**影响**: 用 TCP observed 地址做 UDP 打洞大概率失败。计划中的 STUN 服务完全未实现。

---

### I-7: Horizon VPN 私钥每次启动重新生成

**文件**: `horizon/daemon/src/main.rs` — `start_vpn_server()`

```rust
let (pub_key, priv_key) = blackhole_wg::generate_keypair();
```

每次 daemon 重启密钥对变化，所有已配对客户端的 `peerPublicKey` 失效。

**修复**: 持久化密钥对到 `~/.blackhole/horizon/wg_keys.json`，启动时优先加载。

---

### I-8: NAT 命令注入风险

**文件**: `horizon/daemon/src/nat.rs` — `setup_nat_macos()`, `setup_nat_linux()`

`vpn_subnet` 来自 CLI 参数 `--vpn-subnet`，未验证格式。macOS 路径中值通过 stdin pipe 传给 pfctl，理论上可注入额外 pf 规则。

**修复**: 在 `parse_args` 中用正则验证 CIDR 格式（如 `^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$`）。

---

### I-9: Settings page VPN 配置与 daemon 未打通

**文件**: `horizon/lib/src/pages/settings_page.dart` — VPN 配置保存
**文件**: `horizon/daemon/src/main.rs` — `parse_args()`

Flutter 将 VPN 配置写入 `settings.json`（vpnEnabled, vpnSubnet, vpnPort, vpnRoutes），但 daemon 从命令行 `--vpn*` 参数读取。两条路径没有连接。

**修复**: daemon 应优先读取 settings.json 中的 VPN 配置，CLI 参数作为 override。

---

### I-10: 主 App entitlements 缺少 NE 和 App Group

**文件**: `voyager/macos/Runner/DebugProfile.entitlements`
**文件**: `voyager/macos/Runner/Release.entitlements`

macOS 主 App entitlements 缺少：
- `com.apple.developer.networking.networkextension`
- `com.apple.security.application-groups`

iOS Runner 同样需要添加。否则 `containerURL(forSecurityApplicationGroupIdentifier:)` 返回 nil。

---

## 🟢 Minor（6 项）

### M-1: IpPool 声称持久化但只在内存中

**文件**: `blackhole-wg/src/ip_pool.rs`

代码注释说 IP 分配按 device_key 持久化，但 `IpPool` 只有内存 `HashMap`，daemon 重启后所有分配丢失。

---

### M-2: 私钥 sk_array 未在使用后 zeroize

**文件**: `blackhole-wg/src/tunnel.rs`, `blackhole-wg/src/ffi.rs`

密钥材料在栈上残留。建议使用 `zeroize` crate。

---

### M-3: STUN 和打洞状态机未被调用

**文件**: `blackhole-wg/src/holepunch.rs`

`HolePunchMachine` 已实现但在整个项目中没有被任何代码调用。STUN 服务也完全未实现。NAT 穿透功能当前不可用。

---

### M-4: `find_peer_for_packet` 遍历所有 peer 尝试解密

**文件**: `horizon/daemon/src/wg_server.rs`

收到未知地址 UDP 包时遍历所有 peer 尝试 `decapsulate`。每次调用可能消耗 nonce 或修改内部状态。WireGuard handshake initiation 包含 receiver index，可快速查找。

---

### M-5: DNS forwarder 清理依赖网络事件触发

**文件**: `horizon/daemon/src/dns_forwarder.rs`

清理检查仅在 `tokio::select!` 有网络事件时运行。长时间无 DNS 活动时 stale entries 不会被清理。应添加定时器分支。

---

### M-6: WG relay 无速率/带宽限制

**文件**: `wormhole/src/main.rs` — `/wg-relay` handler

对所有认证连接无条件转发所有二进制帧，无带宽限制、连接数限制或包大小验证。公共部署下可被滥用。

---

## 计划 vs 实现差距

| 计划特性 | 状态 |
|---------|------|
| Phase 1: Wormhole 信令扩展 | ✅ 基本完成 |
| Phase 2: blackhole-wg 共享库 | ✅ 完成 |
| Phase 3: Horizon WG Server | ⚠️ 框架完成，peer 注册未接通 (C-3) |
| Phase 3: REST API (POST /vpn/config) | ❌ 未实现，仅有 GET /vpn/status |
| Phase 3: vpn_config 信令下发 | ❌ 未实现 |
| Phase 4: iOS/macOS NE | ⚠️ 代码存在，未集成 Xcode (C-5, C-6) |
| Phase 4: App Group IPC | ⚠️ 写入已实现，回读断裂 (I-5) |
| Phase 5: STUN | ❌ 未实现 |
| Phase 5: 打洞状态机集成 | ❌ 代码已写未使用 (M-3) |
| Phase 5: DERP 中继 | ✅ 基本完成 |
| Phase 5: 连接升级 (relay→direct) | ❌ 未实现 |
| Phase 6: VPN Flutter UI | ✅ 完成 |
| Phase 6: Horizon settings VPN 配置 | ⚠️ UI 完成，与 daemon 未打通 (I-9) |

---

## 端到端可用性

要让 VPN 端到端工作，至少需解决以下 blocking issues（按优先级排序）：

1. **C-1** — 修复 macOS utun 4 字节 AF 头部处理
2. **C-2** — 实现客户端密钥生成和交换流程
3. **C-3** — 将 WgServer 引用暴露给 Wormhole 消息处理，实现 add_peer
4. **C-4** — FFI 层或 Swift 调用层添加同步（serial dispatch queue）
5. **C-5** — AppDelegate 注册 VpnPlugin
6. **C-6** — Xcode 项目创建 VoyagerTunnel target
7. **I-1** — 修复 Swift drain 调用中 null src 被 FFI 拒绝
8. **I-5** — App Group 状态回传链路修复
9. **I-10** — 主 App entitlements 添加 NE 和 App Group 权限
