/// Shared code between Voyager and Horizon
library voyager_share;

// Models
export 'src/models/multi_window_layout.dart';
export 'src/models/terminal_group.dart';

// Services
export 'src/controllers/multi_window_layout_controller.dart';
export 'src/services/crypto_service.dart';
export 'src/services/terminal_manager.dart';
export 'src/services/group_storage_migrator.dart';
export 'src/services/group_store.dart';
export 'src/services/pinyin_engine.dart';

// Widgets - Chrome
export 'src/widgets/chrome/chrome_tab_button.dart';
export 'src/widgets/chrome/chrome_tab_pill.dart';
export 'src/widgets/chrome/chrome_tab_shell.dart';
export 'src/widgets/chrome/header_chrome.dart';
export 'src/widgets/chrome/tab_clipper.dart';

// Widgets - Common
export 'src/widgets/common/action_button.dart';
export 'src/widgets/common/fade_overflow_text.dart';
export 'src/widgets/common/status_dot.dart';
export 'src/widgets/common/vpn_status_ring.dart';

// Widgets - Keyboard
export 'src/widgets/keyboard/candidate_bar.dart';
export 'src/widgets/keyboard/hhkb_key.dart';
export 'src/widgets/keyboard/hhkb_keyboard.dart';

// Widgets - Design System
export 'src/widgets/design_tokens.dart';

// Widgets - Other
export 'src/widgets/command_input_bar.dart';
export 'src/widgets/add_terminal_card.dart';
export 'src/widgets/group_drawer.dart';
export 'src/widgets/quick_actions_bar.dart';
export 'src/widgets/settings_drawer.dart';
export 'src/widgets/terminal_style.dart';
export 'src/widgets/session_window_card.dart';
export 'src/widgets/multi_window_grid.dart';
