# Voyager + Horizon 终端分组功能规划（Horizon 主控）

## 功能概述

终端分组的**数据与规则由 Horizon 统一管理**，Voyager 仅负责 UI 展示与操作入口。这样可以保证多设备/多客户端的一致性，并让分组与实际会话生命周期绑定在主机侧。

## 系统架构

- **Horizon**：分组数据的唯一真实来源（source of truth），负责持久化、校验、会话生命周期更新、广播更新。
- **Voyager**：拉取分组快照，展示 UI，发送分组操作指令。
- **Wormhole**：透明转发新增的 `group_*` 消息类型（不做业务逻辑）。

> 设计原则：任何分组变更必须在 Horizon 发生并持久化；Voyager 只根据最新 `group_sync` 更新 UI。

## 用户界面设计

### 1. 左侧抽屉 (Drawer)

**打开方式：**
- 从屏幕左边缘向右滑动
- 或点击顶部栏左侧的菜单按钮 (☰)

**位置：** Scaffold 的 `drawer` 属性（设置抽屉在 `endDrawer`）

```
┌──────────────────────────────────────────────────────────────┐
│  [☰]  Session: ABC123              [连接状态]         [⚙️]   │  ← 顶部栏
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────┐                     │
│  │  终端分组      [取消] [编辑] [+]    │                     │
│  ├─────────────────────────────────────┤                     │
│  │                                     │
│  │  ▼ 默认分组 (3)                     │     终端内容        │
│  │     ├─ Terminal 1                   │
│  │     ├─ Terminal 2                   │
│  │     └─ Terminal 3                   │
│  │                                     │
│  │  ▶ 项目A (2)                        │
│  │                                     │
│  │  ▶ 分组1 (1)                        │
│  │                                     │
│  └─────────────────────────────────────┘                     │
│       ↑ 左侧抽屉 (滑出)                                       │
└──────────────────────────────────────────────────────────────┘
```

**抽屉内容：**

```
┌─────────────────────────────────────┐
│  终端分组      [取消] [编辑] [+]    │
├─────────────────────────────────────┤
│                                     │
│  ▼ 默认分组 (3)                     │
│     ├─ Terminal 1                   │
│     ├─ Terminal 2                   │
│     └─ Terminal 3                   │
│                                     │
│  ▶ 项目A (2)                        │
│                                     │
│  ▶ 分组1 (1)                        │
│                                     │
└─────────────────────────────────────┘
```

### 2. 抽屉头部按钮

| 按钮 | 功能 | 状态切换 |
|------|------|----------|
| **[+]** | 添加新分组（请求 Horizon 创建） | - |
| **[编辑]** | 进入编辑模式（仅改名） | 切换为 [保存] |
| **[保存]** | 保存名称修改（请求 Horizon 批量改名） | 切换回 [编辑] |
| **[取消]** | 取消改名（仅编辑模式显示） | 恢复原始名称（本地 UI） |

### 3. 操作模式说明

**普通模式：**
- [+] 发送 `group_create` 请求
- 点击分组展开/折叠
- 点击终端切换到该终端
- 长按分组显示操作菜单（重命名、删除）

**编辑模式（仅用于批量改名）：**
- 分组名称显示为 TextField，可直接编辑
- **实时验证**: 空名称时显示红色边框和提示
- [保存] 提交所有名称修改（发送批量 rename）
- [取消] 恢复本地名称（不发请求）

**删除分组：**
- 长按分组 → 菜单选择"删除"
- 显示确认对话框
- 确认后发送 `group_delete`

**移动终端：**
- 长按终端 → 显示"移动到..."菜单
- 选择目标分组后发送 `group_move_session`

## 协议与同步

### 消息类型（建议）

**Voyager → Horizon**
- `group_list`：请求分组快照
- `group_create`：创建分组
- `group_rename`：重命名分组
- `group_delete`：删除分组
- `group_move_session`：移动会话到分组

**Horizon → Voyager**
- `group_sync`：完整快照（权威）
- `group_error`：操作失败原因

> 简化策略：Horizon 每次变更后广播 `group_sync`，客户端只做全量替换。

### 示例 payload

```json
{
  "type": "group_sync",
  "version": 1,
  "groups": [
    {
      "id": "default",
      "name": "默认分组",
      "sessionIds": ["session-1", "session-2"],
      "createdAt": "2024-01-01T00:00:00Z"
    }
  ]
}
```

## 数据模型（Horizon 侧）

### TerminalGroup 类

```dart
class TerminalGroup {
  final String id;           // UUID, 默认分组固定为 'default'
  String name;               // 分组名称
  List<String> sessionIds;   // 终端会话ID列表
  final DateTime createdAt;
  // int sortOrder;          // v2 预留

  bool get isDefault => id == defaultGroupId;

  static const String defaultGroupId = 'default';
  static const String defaultGroupName = '默认分组';
}
```

### 存储结构（Horizon 本地持久化）

```json
{
  "version": 1,
  "groups": [
    {
      "id": "default",
      "name": "默认分组",
      "sessionIds": ["session-1", "session-2"],
      "createdAt": "2024-01-01T00:00:00Z"
    }
  ]
}
```

## 数据不变量 (Invariants)

1. **单分组约束**: 每个 sessionId 只能存在于一个分组中（Horizon 强制）
2. **默认分组必须存在**: 加载时如果没有默认分组，自动创建
3. **sessionId 有效性**: 只保留当前活跃的 session，断开的 session 及时清理
4. **客户端只读**: Voyager 只能通过指令请求，不能直接改动分组数据

## Schema 版本迁移策略（Horizon 侧）

| 版本 | 变更内容 | 迁移逻辑 |
|------|----------|----------|
| 1 | 初始版本 | - |
| 2 (预留) | 添加 sortOrder | 为现有分组按创建时间分配 sortOrder |
| 3 (预留) | 添加 color | 为现有分组设置默认颜色 null |

## Session 生命周期管理（Horizon 侧）

- `session_list` 到来时：
  - 移除所有不在活跃列表的 sessionId
  - 将“未分组但活跃”的 sessionId 放入默认分组
- `session_created`：
  - 强制单分组约束（先从所有分组移除）
  - 加入当前活跃分组或默认分组
- `session_closed`：
  - 从所有分组移除
- 任意分组更新后：
  - 持久化并广播 `group_sync`

## 跨分组移动终端

Voyager 仅发送 `group_move_session`，Horizon 负责更新并广播。

## 实现步骤

### 阶段 1：Horizon 数据层 & 持久化

1. **创建 TerminalGroup 模型类**
   - 文件: `horizon/lib/models/terminal_group.dart`
2. **创建 GroupStorageMigrator**
   - 文件: `horizon/lib/services/group_storage_migrator.dart`
3. **创建 GroupManager**
   - 文件: `horizon/lib/services/group_manager.dart`
   - 管理分组 CRUD、持久化、会话生命周期更新

### 阶段 2：协议与 Wormhole

4. **扩展消息类型**
   - Horizon 处理 `group_*` 消息
   - Wormhole 透传 `group_*` 消息（不做过滤/拦截）

### 阶段 3：Voyager UI

5. **分组抽屉 UI**
   - 文件: `voyager/lib/widgets/group_drawer.dart`
6. **分组状态容器（客户端）**
   - 文件: `voyager/lib/services/group_store.dart`
   - 仅保存 Horizon 下发的 `group_sync`
7. **集成到 main.dart**
   - drawer、菜单按钮、分组切换、发送 `group_*` 指令

### 阶段 4：测试

- **Horizon**：分组 CRUD、session 生命周期、迁移测试
- **Voyager**：UI + 协议交互（mock `group_sync`）
- **Wormhole**：消息透传测试（确保新类型不被拦截）

## 文件结构（更新）

```
horizon/lib/
├── models/
│   └── terminal_group.dart
├── services/
│   ├── group_manager.dart
│   └── group_storage_migrator.dart

voyager/lib/
├── main.dart
├── services/
│   └── group_store.dart
└── widgets/
    └── group_drawer.dart

wormhole/src/
└── main.rs (或相关协议转发模块)
```

## 边界情况处理

| 场景 | 处理方式 |
|------|----------|
| 删除默认分组 | Horizon 禁止删除 |
| 分组名称为空 | Horizon 拒绝并返回 `group_error` |
| 多客户端并发操作 | Horizon 统一裁决，广播最新 `group_sync` |
| 终端断开连接 | Horizon 移除 sessionId 并广播 |
| 存储损坏 | Horizon 重建默认分组 |

## 后续扩展可能

1. **分组颜色标记**
2. **分组排序**
3. **分组图标**
4. **快捷切换**
5. **分组导出/导入**
6. **跨设备共享**

---

*文档版本: 3.0*
*更新时间: 2026-01-15*
*变更: 分组主控迁移到 Horizon，新增协议同步与 Wormhole 透传要求*
