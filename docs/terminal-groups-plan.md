# Voyager 终端分组功能规划

## 功能概述

为 Voyager 添加终端分组（项目）功能，允许用户将多个终端会话组织到不同的分组中，便于管理多项目场景。

## 用户界面设计

### 1. 左侧抽屉 (Drawer)

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
| **[+]** | 添加新分组 | 点击后创建 "分组N" |
| **[编辑]** | 进入编辑模式 | 切换为 [保存] |
| **[保存]** | 保存修改 | 切换回 [编辑] |
| **[取消]** | 取消编辑（仅编辑模式显示） | 恢复原始状态 |

### 3. 编辑模式功能

- 分组名称可点击编辑（显示为 TextField）
- **实时验证**: 空名称时显示红色边框和提示
- 每个分组右侧显示删除按钮（默认分组除外）
- 终端项显示移动按钮（点击弹出目标分组选择菜单）
- 长按终端项显示移动菜单

## 数据模型

### TerminalGroup 类

```dart
class TerminalGroup {
  final String id;           // UUID, 默认分组固定为 'default'
  String name;               // 分组名称
  List<String> sessionIds;   // 终端会话ID列表
  final DateTime createdAt;
  int sortOrder;             // 排序顺序 (预留)

  bool get isDefault => id == defaultGroupId;

  static const String defaultGroupId = 'default';
  static const String defaultGroupName = '默认分组';
}
```

### 存储结构 (SharedPreferences / JSON)

```json
{
  "version": 1,
  "groups": [
    {
      "id": "default",
      "name": "默认分组",
      "sessionIds": ["session-1", "session-2"],
      "createdAt": "2024-01-01T00:00:00Z",
      "sortOrder": 0
    },
    {
      "id": "uuid-xxx",
      "name": "项目A",
      "sessionIds": ["session-3"],
      "createdAt": "2024-01-15T10:30:00Z",
      "sortOrder": 1
    }
  ],
  "activeGroupId": "default"
}
```

### 数据不变量 (Invariants)

1. **单分组约束**: 每个 sessionId 只能存在于一个分组中
2. **默认分组必须存在**: 加载时如果没有默认分组，自动创建
3. **activeGroupId 有效性**: 必须指向存在的分组，否则回退到默认分组
4. **sessionId 有效性**: 只保留当前活跃的 session，断开的 session 及时清理

## Schema 版本迁移策略

### 版本迁移表

| 版本 | 变更内容 | 迁移逻辑 |
|------|----------|----------|
| 1 | 初始版本 | - |
| 2 (预留) | 添加 sortOrder | 为现有分组按创建时间分配 sortOrder |
| 3 (预留) | 添加 color | 为现有分组设置默认颜色 null |

### 迁移代码结构

```dart
class GroupStorageMigrator {
  static const int currentVersion = 1;

  static Map<String, dynamic> migrate(Map<String, dynamic> data) {
    int version = data['version'] ?? 0;

    while (version < currentVersion) {
      switch (version) {
        case 0:
          data = _migrateV0ToV1(data);
          break;
        // case 1:
        //   data = _migrateV1ToV2(data);
        //   break;
      }
      version++;
    }

    data['version'] = currentVersion;
    return data;
  }

  static Map<String, dynamic> _migrateV0ToV1(Map<String, dynamic> data) {
    // 从无版本迁移到 v1: 确保有默认分组
    return data;
  }
}
```

### 加载时校验流程

```dart
Future<void> loadGroups() async {
  final json = await _readFromStorage();

  // 1. 版本迁移
  final migrated = GroupStorageMigrator.migrate(json);

  // 2. 确保默认分组存在
  _ensureDefaultGroup(migrated);

  // 3. 清理无效 sessionId (不在当前活跃 session 列表中的)
  _cleanupStaleSessionIds(migrated);

  // 4. 去重: 确保每个 sessionId 只在一个分组
  _deduplicateSessionIds(migrated);

  // 5. 验证 activeGroupId
  _validateActiveGroupId(migrated);

  // 6. 保存修复后的数据
  if (_isDirty) {
    await _saveToStorage(migrated);
  }
}
```

## Session 生命周期管理

### Session 事件钩子

```dart
class GroupManager {
  // 当收到 session_list 消息时调用
  void onSessionListReceived(List<String> activeSessions) {
    // 清理不在 activeSessions 中的 sessionId
    for (final group in _groups) {
      group.sessionIds.removeWhere((id) => !activeSessions.contains(id));
    }
    _save();
  }

  // 当收到 session_created 消息时调用
  void onSessionCreated(String sessionId) {
    // 添加到当前活跃分组（或默认分组）
    final targetGroup = _activeGroup ?? _defaultGroup;
    if (!targetGroup.sessionIds.contains(sessionId)) {
      targetGroup.sessionIds.add(sessionId);
      _save();
    }
  }

  // 当收到 session_closed 消息时调用
  void onSessionClosed(String sessionId) {
    // 从所有分组中移除
    for (final group in _groups) {
      group.sessionIds.remove(sessionId);
    }
    _save();
  }

  // 当 WebSocket 断开时调用
  void onDisconnected() {
    // 清空所有 sessionIds，等待重连后的 session_list
    for (final group in _groups) {
      group.sessionIds.clear();
    }
    // 不保存，因为重连后会重新获取
  }
}
```

### 集成点 (main.dart)

```dart
// 在 _handleMessage 中添加钩子
void _handleWormholeMessage(dynamic message) {
  // ... existing code ...

  if (type == 'session_list') {
    final sessions = decoded['sessions'] as List;
    _groupManager.onSessionListReceived(sessions.cast<String>());
  }

  if (type == 'session_created') {
    final sessionId = decoded['sessionId'] as String;
    _groupManager.onSessionCreated(sessionId);
  }

  if (type == 'session_closed') {
    final sessionId = decoded['sessionId'] as String;
    _groupManager.onSessionClosed(sessionId);
  }
}

// 在 WebSocket 断开时
void _onDisconnected() {
  _groupManager.onDisconnected();
}
```

## 跨分组移动终端方案

### 方案选择: 移动按钮 + 弹出菜单

由于 `ReorderableListView` 不支持跨列表拖拽，采用更简单可靠的方案：

```
编辑模式下:
┌─────────────────────────────────────┐
│  ▼ 默认分组 (2)                     │
│     ├─ Terminal 1  [↔️]  [🗑️]       │
│     └─ Terminal 2  [↔️]  [🗑️]       │
└─────────────────────────────────────┘
                  ↓ 点击 [↔️]
        ┌─────────────────┐
        │  移动到...       │
        ├─────────────────┤
        │  ○ 默认分组  ✓   │
        │  ○ 项目A        │
        │  ○ 分组1        │
        └─────────────────┘
```

### 实现代码

```dart
void _showMoveSessionDialog(String sessionId, String currentGroupId) {
  showModalBottomSheet(
    context: context,
    builder: (context) => ListView(
      shrinkWrap: true,
      children: [
        const ListTile(title: Text('移动到...')),
        const Divider(),
        for (final group in _groups)
          RadioListTile<String>(
            title: Text(group.name),
            value: group.id,
            groupValue: currentGroupId,
            onChanged: (targetGroupId) {
              if (targetGroupId != null && targetGroupId != currentGroupId) {
                _moveSession(sessionId, currentGroupId, targetGroupId);
              }
              Navigator.pop(context);
            },
          ),
      ],
    ),
  );
}

void _moveSession(String sessionId, String fromGroupId, String toGroupId) {
  final fromGroup = _groups.firstWhere((g) => g.id == fromGroupId);
  final toGroup = _groups.firstWhere((g) => g.id == toGroupId);

  fromGroup.sessionIds.remove(sessionId);
  if (!toGroup.sessionIds.contains(sessionId)) {
    toGroup.sessionIds.add(sessionId);
  }
  _save();
}
```

## 编辑模式 UX 详细流程

### 状态机

```
[普通模式] ──点击[编辑]──→ [编辑模式]
     ↑                        │
     │                        ├──点击[保存]──→ 验证 → 成功 → [普通模式]
     │                        │                  ↓
     │                        │               失败 → 显示错误，保持编辑模式
     │                        │
     └────点击[取消]──────────┘
              ↓
        恢复原始数据
```

### 编辑模式状态

```dart
class EditModeState {
  bool isEditing = false;
  Map<String, String> originalNames = {};  // 用于取消时恢复
  Set<String> invalidGroups = {};          // 验证失败的分组ID

  void enterEditMode(List<TerminalGroup> groups) {
    isEditing = true;
    originalNames = {for (var g in groups) g.id: g.name};
    invalidGroups.clear();
  }

  void cancelEdit(List<TerminalGroup> groups) {
    // 恢复原始名称
    for (final group in groups) {
      group.name = originalNames[group.id] ?? group.name;
    }
    isEditing = false;
    invalidGroups.clear();
  }

  bool validateAndSave(List<TerminalGroup> groups) {
    invalidGroups.clear();

    for (final group in groups) {
      if (group.name.trim().isEmpty) {
        invalidGroups.add(group.id);
      }
    }

    if (invalidGroups.isNotEmpty) {
      return false;  // 验证失败
    }

    isEditing = false;
    return true;  // 验证成功，可以保存
  }
}
```

### 名称输入框 UI

```dart
TextField(
  controller: _nameController,
  decoration: InputDecoration(
    border: OutlineInputBorder(
      borderSide: BorderSide(
        color: _editState.invalidGroups.contains(group.id)
            ? Colors.red
            : Colors.grey,
      ),
    ),
    errorText: _editState.invalidGroups.contains(group.id)
        ? '名称不能为空'
        : null,
  ),
  onChanged: (value) {
    group.name = value;
    // 实时清除错误状态
    if (value.trim().isNotEmpty) {
      _editState.invalidGroups.remove(group.id);
    }
  },
)
```

## 实现步骤

### 阶段 1: 数据层

1. **创建 TerminalGroup 模型类**
   - 文件: `lib/models/terminal_group.dart`
   - 包含 toJson/fromJson 序列化方法
   - 包含数据不变量验证方法

2. **创建 GroupStorageMigrator**
   - 文件: `lib/services/group_storage_migrator.dart`
   - Schema 版本迁移逻辑

3. **创建 GroupManager 状态管理**
   - 文件: `lib/services/group_manager.dart`
   - 管理分组的 CRUD 操作
   - 处理持久化存储
   - Session 生命周期钩子

### 阶段 2: UI 组件

4. **创建 GroupDrawer 组件**
   - 文件: `lib/widgets/group_drawer.dart`
   - 抽屉主体布局
   - 分组列表视图

5. **创建 GroupHeader 组件**
   - 标题 + 取消/编辑/保存按钮 + 添加按钮

6. **创建 GroupItem 组件**
   - 可展开/折叠的分组项
   - 编辑模式下的删除和重命名
   - 名称验证和错误显示

7. **创建 SessionItem 组件**
   - 终端会话项
   - 编辑模式下的移动和关闭按钮

### 阶段 3: 集成

8. **修改 main.dart**
   - 添加 Scaffold drawer 属性
   - 集成 GroupManager
   - 处理分组切换逻辑
   - 添加 Session 生命周期钩子

### 阶段 4: 测试

9. **单元测试**
   - 文件: `test/group_manager_test.dart`
   - 测试用例见下方测试计划

10. **集成测试**
    - 文件: `test/group_integration_test.dart`

## 测试计划

### 单元测试 (group_manager_test.dart)

```dart
group('GroupManager', () {
  group('CRUD Operations', () {
    test('createGroup creates group with unique id and default name');
    test('createGroup increments name suffix for duplicates');
    test('deleteGroup moves sessions to default group');
    test('deleteGroup prevents deleting default group');
    test('renameGroup updates group name');
    test('moveSession transfers session between groups');
    test('moveSession maintains single-group invariant');
  });

  group('Session Lifecycle', () {
    test('onSessionCreated adds to active group');
    test('onSessionClosed removes from all groups');
    test('onSessionListReceived cleans up stale sessions');
    test('onDisconnected clears all session ids');
  });

  group('Persistence', () {
    test('save persists to SharedPreferences');
    test('load restores from SharedPreferences');
    test('load creates default group if missing');
    test('load fixes invalid activeGroupId');
    test('load deduplicates sessionIds across groups');
  });

  group('Schema Migration', () {
    test('migrate handles missing version field');
    test('migrate v0 to v1 ensures default group');
    // test('migrate v1 to v2 adds sortOrder');  // 预留
  });
});

group('EditModeState', () {
  test('enterEditMode stores original names');
  test('cancelEdit restores original names');
  test('validateAndSave rejects empty names');
  test('validateAndSave clears invalidGroups on success');
});
```

### 集成测试 (group_integration_test.dart)

```dart
group('Group Drawer Integration', () {
  testWidgets('drawer opens and shows groups');
  testWidgets('add button creates new group');
  testWidgets('edit mode enables rename fields');
  testWidgets('cancel restores original state');
  testWidgets('save validates and persists');
  testWidgets('move session shows target selector');
  testWidgets('delete group shows confirmation');
});
```

## 文件结构

```
voyager/lib/
├── main.dart                           # 修改: 添加 drawer + session hooks
├── models/
│   └── terminal_group.dart             # 新增: 分组数据模型
├── services/
│   ├── group_manager.dart              # 新增: 分组状态管理
│   └── group_storage_migrator.dart     # 新增: Schema 迁移
└── widgets/
    ├── group_drawer.dart               # 新增: 左侧抽屉
    ├── group_header.dart               # 新增: 抽屉头部
    ├── group_item.dart                 # 新增: 分组列表项
    └── session_item.dart               # 新增: 会话列表项

voyager/test/
├── group_manager_test.dart             # 新增: 单元测试
└── group_integration_test.dart         # 新增: 集成测试
```

## 状态管理方案

当前 Voyager 使用 `StatefulWidget` + `setState` 模式。为保持一致性，GroupManager 采用相同模式：

```dart
class GroupManager {
  final VoidCallback onChanged;  // 通知 UI 更新

  GroupManager({required this.onChanged});

  // 所有修改操作后调用 onChanged()
}

// 在 _VoyagerHomeState 中
late final GroupManager _groupManager;

@override
void initState() {
  super.initState();
  _groupManager = GroupManager(onChanged: () => setState(() {}));
}
```

## 边界情况处理

| 场景 | 处理方式 |
|------|----------|
| 删除默认分组 | 禁止删除，按钮置灰 |
| 分组名称为空 | 保存时显示错误，阻止保存 |
| 分组名称重复 | 允许重复（通过 UUID 区分） |
| 终端断开连接 | 从分组中移除 sessionId |
| 清空分组 | 允许空分组存在 |
| 存储损坏 | 重建默认分组，丢失自定义分组 |
| activeGroupId 无效 | 回退到默认分组 |
| sessionId 重复 | 加载时去重，保留第一个 |

## 后续扩展可能

1. **分组颜色标记** - 为分组添加颜色标识
2. **分组排序** - 拖拽调整分组顺序
3. **分组图标** - 自定义分组图标
4. **快捷切换** - 键盘快捷键切换分组
5. **分组导出/导入** - 配置备份恢复
6. **与 Horizon 同步** - 分组配置云端同步

---

*文档版本: 2.0*
*更新时间: 2026-01-15*
*变更: 添加 session 生命周期管理、schema 迁移策略、编辑取消流程、测试计划*
