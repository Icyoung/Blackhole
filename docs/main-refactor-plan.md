# Main.dart 拆分计划

## 概述

| 项目 | 当前行数 | 目标 |
|------|---------|------|
| Horizon | 1,084 | ~100 (入口) + 分散到 widgets/ |
| Voyager | 3,021 | ~200 (入口) + 分散到 widgets/ |

---

## Horizon 拆分方案

### 当前结构
```
main.dart (1084 lines)
├── main() + DevModeConfig (1-34)
├── HorizonApp (36-79)
├── HorizonHome (81-223)
└── Widgets (225-1084)
    ├── _StatusDot
    ├── _StatusCard, _InfoItem, _SessionIdDisplay
    ├── _ConnectionCard, _SectionTitle, _ConfigRow, _StyledTextField
    ├── _AddressCard, _StatusMessage
    ├── _AccessCard
    ├── _DevModeCard
    ├── _PairedDevicesCard, _DeviceListTile
    └── _PairingDialog
```

### 目标结构
```
lib/
├── main.dart                          (~35 lines)
│   └── main(), DevModeConfig, runApp
└── src/
    ├── app.dart                       (~50 lines)
    │   └── HorizonApp
    ├── pages/
    │   └── home_page.dart             (~100 lines)
    │       └── HorizonHome
    └── widgets/
        ├── common/
        │   ├── status_dot.dart
        │   ├── section_title.dart
        │   ├── styled_text_field.dart
        │   └── status_message.dart
        └── cards/
            ├── status_card.dart       (StatusCard, InfoItem, SessionIdDisplay)
            ├── connection_card.dart   (ConnectionCard, ConfigRow)
            ├── address_card.dart
            ├── access_card.dart
            ├── dev_mode_card.dart
            └── paired_devices_card.dart (PairedDevicesCard, DeviceListTile)
        └── dialogs/
            └── pairing_dialog.dart
```

### 拆分步骤

1. **创建目录结构**
   ```bash
   mkdir -p horizon/lib/src/{pages,widgets/{common,cards,dialogs}}
   ```

2. **提取公共组件** → `widgets/common/`
   - `StatusDot` - 状态指示点
   - `SectionTitle` - 卡片标题
   - `StyledTextField` - 样式化输入框
   - `StatusMessage` - 状态消息

3. **提取卡片组件** → `widgets/cards/`
   - `StatusCard` (含 InfoItem, SessionIdDisplay)
   - `ConnectionCard` (含 ConfigRow)
   - `AddressCard`
   - `AccessCard`
   - `DevModeCard`
   - `PairedDevicesCard` (含 DeviceListTile)

4. **提取对话框** → `widgets/dialogs/`
   - `PairingDialog`

5. **创建页面** → `pages/home_page.dart`

6. **创建 App** → `app.dart`

7. **精简 main.dart** - 仅保留入口和配置

---

## Voyager 拆分方案

### 当前结构
```
main.dart (3021 lines)
├── Enums + main() (1-70)
├── VoyagerApp (44-69)
├── VoyagerHome (71-77)
├── _VoyagerHomeState (78-1695)        ← 最大的问题：1617 行
│   ├── State & Lifecycle (~200 lines)
│   ├── WebSocket & Protocol (~400 lines)
│   ├── Terminal Management (~300 lines)
│   ├── UI Building (~400 lines)
│   └── Settings Drawer (~300 lines)
└── Widgets (1697-3021)
    ├── _StatusDot
    ├── _QuickActionsBar
    ├── _HeaderChrome
    ├── _ChromeTabButton, _ChromeTabPill, _ChromeTabShell
    ├── _TabClipper, _TabClipperInverted
    ├── _ActionButton
    ├── _HHKBKeyboard, _HHKBKey
    ├── _AddTerminalCard
    └── _TerminalWindowCard
```

### 目标结构
```
lib/
├── main.dart                          (~30 lines)
│   └── main(), runApp
└── src/
    ├── app.dart                       (~40 lines)
    │   └── VoyagerApp
    ├── pages/
    │   └── home_page.dart             (~300 lines)
    │       └── VoyagerHome, _VoyagerHomeState (UI 构建部分)
    ├── services/
    │   ├── connection_manager.dart    (~400 lines) ← 新增
    │   │   └── WebSocket, Protocol, Reconnect
    │   └── terminal_manager.dart      (~200 lines) ← 新增
    │       └── Terminal 创建/销毁/切换
    └── widgets/
        ├── common/
        │   ├── status_dot.dart
        │   └── action_button.dart
        ├── chrome/
        │   ├── header_chrome.dart
        │   ├── chrome_tab_button.dart
        │   ├── chrome_tab_pill.dart
        │   ├── chrome_tab_shell.dart
        │   └── tab_clipper.dart
        ├── keyboard/
        │   ├── hhkb_keyboard.dart
        │   └── hhkb_key.dart
        ├── quick_actions_bar.dart
        ├── terminal_window_card.dart
        ├── add_terminal_card.dart
        └── settings_drawer.dart       (~300 lines) ← 从 home_page 提取
```

### 拆分步骤

1. **创建目录结构**
   ```bash
   mkdir -p voyager/lib/src/{pages,widgets/{common,chrome,keyboard}}
   ```

2. **提取 Services** (最重要)
   - `ConnectionManager` - WebSocket 连接、协议处理、重连逻辑
   - `TerminalManager` - 终端实例管理、滚动控制器

3. **提取 Chrome 组件** → `widgets/chrome/`
   - `HeaderChrome`
   - `ChromeTabButton`, `ChromeTabPill`, `ChromeTabShell`
   - `TabClipper`, `TabClipperInverted`

4. **提取键盘组件** → `widgets/keyboard/`
   - `HHKBKeyboard`, `HHKBKey`

5. **提取其他组件** → `widgets/`
   - `StatusDot`, `ActionButton`
   - `QuickActionsBar`
   - `TerminalWindowCard`, `AddTerminalCard`

6. **提取 Settings Drawer** → `widgets/settings_drawer.dart`

7. **创建页面** → `pages/home_page.dart`

8. **创建 App** → `app.dart`

9. **精简 main.dart**

---

## 优先级

### Phase 1: 低风险提取 (不改变逻辑)
1. Horizon widgets 提取
2. Voyager 独立 widgets 提取 (StatusDot, Chrome, Keyboard)

### Phase 2: Services 提取 (需要接口设计)
1. Voyager ConnectionManager
2. Voyager TerminalManager

### Phase 3: 页面重构
1. Horizon HomePage
2. Voyager HomePage + SettingsDrawer

---

## 关键设计决策（补充）

1. **ConnectionManager/TerminalManager 生命周期**
   - 由 `VoyagerHome` 持有并在 `initState` 初始化，`dispose` 统一释放。
   - 暴露 `dispose()`/`close()` 方法，内部关闭 WebSocket、Stream、Timer、ScrollController。
   - UI 通过回调或 `ValueNotifier` 订阅状态变化，避免在多个 widget 中重复监听。

2. **SettingsDrawer 的依赖收口**
   - 新建 `SettingsController` 或 `SettingsModel`，集中管理 `TextEditingController`/本地持久化/校验。
   - `settings_drawer.dart` 只接收 `SettingsController` 与必要回调，避免长参数链和隐式依赖。

3. **目录分层与迁移范围**
   - 维持现有结构：`lib/src/` 作为统一根目录，`models/services/widgets/pages/app` 都放在 `lib/src/` 下。
   - 不新增 `lib/services/`、`lib/models/`、`lib/widgets/` 等平行目录，避免两套分层。
   - 若迁移已有文件（如 `group_store.dart`），需同步更新 import 路径，避免循环依赖。

4. **私有前缀策略**
   - 拆到独立文件的 widget 默认改为 public（去掉 `_`），或使用 `part of` 保留私有前缀。
   - 建议优先改为 public 并用目录层级表达作用域，减少 `part` 复杂度。

## 注意事项

1. **保持私有前缀** - 提取后的 widgets 如果只在单个文件中使用，可保持 `_` 前缀为私有
2. **导出管理** - 考虑创建 `widgets.dart` barrel file 统一导出
3. **测试** - 每次提取后运行 `flutter analyze` 确保无错误
4. **逐步提交** - 每个 phase 单独提交，便于回滚
