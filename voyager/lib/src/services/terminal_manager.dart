import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

typedef TerminalResizeCallback = void Function(
  String sessionId,
  int cols,
  int rows,
  int pixelWidth,
  int pixelHeight,
);

class TerminalManager {
  TerminalManager({
    required this.onInput,
    required this.onResize,
  });

  final void Function(String sessionId, String data) onInput;
  final TerminalResizeCallback onResize;

  final Map<String, Terminal> _terminals = {};
  final Map<String, TerminalController> _controllers = {};
  final Map<String, GlobalKey<TerminalViewState>> _terminalViewKeys = {};
  final Map<String, ScrollController> _scrollControllers = {};
  final Map<String, (double, double)> _scrollBottomGapCache = {};

  final Terminal _idleTerminal = Terminal(maxLines: 2000);
  final TerminalController _idleController = TerminalController();
  final GlobalKey<TerminalViewState> _idleTerminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _idleScrollController = ScrollController();

  String? activeSessionId;
  String? _lastResizeSessionId;
  int _lastResizeCols = 0;
  int _lastResizeRows = 0;
  bool _disposed = false;

  Terminal get idleTerminal => _idleTerminal;
  TerminalController get idleController => _idleController;
  GlobalKey<TerminalViewState> get idleTerminalViewKey =>
      _idleTerminalViewKey;
  ScrollController get idleScrollController => _idleScrollController;

  Terminal _createTerminal(String sessionId) {
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) => onInput(sessionId, data);
    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) =>
        onResize(sessionId, cols, rows, pixelWidth, pixelHeight);
    return terminal;
  }

  Terminal terminalFor(String sessionId) {
    return _terminals.putIfAbsent(sessionId, () {
      _controllers.putIfAbsent(sessionId, () => TerminalController());
      return _createTerminal(sessionId);
    });
  }

  TerminalController controllerFor(String sessionId) {
    return _controllers.putIfAbsent(sessionId, () => TerminalController());
  }

  ScrollController scrollControllerFor(String sessionId) {
    final existing = _scrollControllers[sessionId];
    if (existing != null) {
      return existing;
    }
    final controller = ScrollController();
    controller.addListener(() => cacheScrollOffset(sessionId, controller));
    _scrollControllers[sessionId] = controller;
    restoreScrollOffset(sessionId);
    return controller;
  }

  GlobalKey<TerminalViewState> viewKeyFor(String sessionId) {
    return _terminalViewKeys.putIfAbsent(
      sessionId,
      () => GlobalKey<TerminalViewState>(),
    );
  }

  GlobalKey<TerminalViewState>? get activeViewKey {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return viewKeyFor(sessionId);
  }

  Terminal? get activeTerminal {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return terminalFor(sessionId);
  }

  TerminalController? get activeController {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return controllerFor(sessionId);
  }

  ScrollController? get activeScrollController {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return scrollControllerFor(sessionId);
  }

  void resetTerminal(String sessionId) {
    _controllers[sessionId]?.clearSelection();
    _terminals[sessionId] = _createTerminal(sessionId);
    _controllers.putIfAbsent(sessionId, () => TerminalController());
    restoreScrollOffset(sessionId);
  }

  void writeToTerminal(String sessionId, String text) {
    try {
      terminalFor(sessionId).write(text);
    } on AssertionError catch (error, stack) {
      debugPrint('[Voyager] terminal write failed: $error');
      debugPrint('$stack');
      resetTerminal(sessionId);
      try {
        terminalFor(sessionId).write(text);
      } on AssertionError catch (error, stack) {
        debugPrint('[Voyager] terminal write retry failed: $error');
        debugPrint('$stack');
      }
    } catch (error, stack) {
      debugPrint('[Voyager] terminal write error: $error');
      debugPrint('$stack');
    }
  }

  void cacheScrollOffset(String sessionId, ScrollController controller) {
    if (!controller.hasClients) {
      return;
    }
    final maxScroll = controller.position.maxScrollExtent;
    final offset = controller.offset;
    final gap = (maxScroll - offset).clamp(0.0, maxScroll);
    _scrollBottomGapCache[sessionId] = (offset, gap);
  }

  void restoreScrollOffset(String sessionId) {
    final controller = _scrollControllers[sessionId];
    final cached = _scrollBottomGapCache[sessionId];
    if (controller == null || cached == null) {
      return;
    }
    final (cachedOffset, gap) = cached;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !controller.hasClients) {
        return;
      }
      final maxScroll = controller.position.maxScrollExtent;
      final currentOffset = controller.offset;
      var target = (maxScroll - gap).clamp(0.0, maxScroll);
      if (target < 10.0 && cachedOffset > 10.0) {
        target = cachedOffset.clamp(0.0, maxScroll);
      }
      if ((currentOffset - target).abs() < 0.5) {
        return;
      }
      controller.jumpTo(target);
    });
  }

  void removeSession(String sessionId) {
    _terminals.remove(sessionId);
    _controllers.remove(sessionId)?.dispose();
    _terminalViewKeys.remove(sessionId);
    _scrollControllers.remove(sessionId)?.dispose();
    _scrollBottomGapCache.remove(sessionId);
  }

  void forceResizeActiveTerminal({
    required bool multiWindow,
    required double bottomBarHeight,
  }) {
    if (multiWindow) {
      return;
    }
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return;
    }
    final terminal = activeTerminal;
    if (terminal == null) {
      return;
    }
    if (terminal.buffer.height == 0) {
      return;
    }
    if (terminal.viewWidth <= 0 || terminal.viewHeight <= 0) {
      return;
    }
    if (terminal.buffer.height < terminal.viewHeight) {
      return;
    }
    final viewState = activeViewKey?.currentState;
    if (viewState == null) {
      return;
    }
    final renderTerminal = viewState.renderTerminal;
    final size = renderTerminal.size;
    if (!size.isFinite || size.width <= 0 || size.height <= 0) {
      return;
    }
    final padding = EdgeInsets.fromLTRB(8, 4, 8, bottomBarHeight + 8);
    final viewportWidth = size.width - padding.horizontal;
    final viewportHeight = size.height - padding.vertical;
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      return;
    }
    final cellSize = renderTerminal.cellSize;
    if (cellSize.width <= 0 || cellSize.height <= 0) {
      return;
    }
    final cols = viewportWidth ~/ cellSize.width;
    final rows = viewportHeight ~/ cellSize.height;
    if (cols <= 0 || rows <= 0) {
      return;
    }
    if (_lastResizeSessionId == sessionId &&
        _lastResizeCols == cols &&
        _lastResizeRows == rows) {
      return;
    }
    final scrollController = _scrollControllers[sessionId];
    if (scrollController != null) {
      cacheScrollOffset(sessionId, scrollController);
    }
    try {
      terminal.resize(
        cols,
        rows,
        viewportWidth.round(),
        viewportHeight.round(),
      );
    } catch (_) {
      return;
    }
    _lastResizeSessionId = sessionId;
    _lastResizeCols = cols;
    _lastResizeRows = rows;
    restoreScrollOffset(sessionId);
  }

  void clear() {
    for (final sessionId in _terminals.keys.toList()) {
      removeSession(sessionId);
    }
    _terminals.clear();
    activeSessionId = null;
    _lastResizeSessionId = null;
    _lastResizeCols = 0;
    _lastResizeRows = 0;
  }

  void dispose() {
    _disposed = true;
    clear();
    _idleScrollController.dispose();
  }
}
