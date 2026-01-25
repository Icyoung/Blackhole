import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

typedef TerminalResizeCallback =
    void Function(
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
    this.onTitleChange,
    this.logPrefix = 'TerminalManager',
  });

  final void Function(String sessionId, String data) onInput;
  final TerminalResizeCallback onResize;
  final void Function(String sessionId, String title)? onTitleChange;
  final String logPrefix;

  final Map<String, Terminal> _terminals = {};
  final Map<String, TerminalController> _controllers = {};
  final Map<String, GlobalKey<TerminalViewState>> _terminalViewKeys = {};
  final Map<String, ScrollController> _scrollControllers = {};
  final Map<String, (double, double)> _scrollBottomGapCache = {};
  final Map<String, List<int>> _utf8Buffers = {};  // Stores trailing incomplete UTF-8 bytes (max 3)
  final Map<String, List<String>> _pendingWrites = {};
  final Set<String> _pendingFlushScheduled = {};
  final Map<String, String> _titles = {};

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
  GlobalKey<TerminalViewState> get idleTerminalViewKey => _idleTerminalViewKey;
  ScrollController get idleScrollController => _idleScrollController;

  Terminal _createTerminal(String sessionId) {
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) => onInput(sessionId, data);
    terminal.onResize =
        (cols, rows, pixelWidth, pixelHeight) =>
            onResize(sessionId, cols, rows, pixelWidth, pixelHeight);
    terminal.onTitleChange = (title) {
      _titles[sessionId] = title;
      onTitleChange?.call(sessionId, title);
    };
    return terminal;
  }

  String? getTitle(String sessionId) => _titles[sessionId];

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
    final terminal = terminalFor(sessionId);

    try {
      terminal.write(text);
    } on AssertionError {
      // Terminal not attached to view yet, buffer the write and retry later
      final pending = _pendingWrites.putIfAbsent(sessionId, () => <String>[]);
      pending.add(text);
      _scheduleFlushPendingWrites(sessionId);
    } catch (error) {
      // Other errors (like TypeError from xterm bugs) - just skip this write
      // to avoid UI freezing. Some output may be lost.
    }
  }

  void _scheduleFlushPendingWrites(String sessionId) {
    if (_pendingFlushScheduled.contains(sessionId)) {
      return;
    }
    _pendingFlushScheduled.add(sessionId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingFlushScheduled.remove(sessionId);
      _flushPendingWrites(sessionId);
    });
  }

  void _flushPendingWrites(String sessionId) {
    if (_disposed) {
      return;
    }
    final pending = _pendingWrites.remove(sessionId);
    if (pending == null || pending.isEmpty) {
      return;
    }
    final terminal = _terminals[sessionId];
    if (terminal == null) {
      // Session was removed, discard pending writes
      return;
    }

    // Try to write all pending data
    final combined = pending.join();
    try {
      terminal.write(combined);
    } on AssertionError {
      // Still not attached, re-buffer and retry next frame
      _pendingWrites[sessionId] = [combined];
      _scheduleFlushPendingWrites(sessionId);
    } on TypeError {
      // Buffer not ready, re-buffer and retry next frame
      _pendingWrites[sessionId] = [combined];
      _scheduleFlushPendingWrites(sessionId);
    } catch (error) {
      debugPrint('[$logPrefix] flush pending writes failed: $error');
    }
  }

  /// Write raw bytes to terminal with proper UTF-8 streaming decode.
  /// Only buffers trailing incomplete UTF-8 bytes (max 3 bytes) for efficiency.
  void writeToTerminalBytes(String sessionId, Uint8List data) {
    if (data.isEmpty) return;

    // Get any leftover bytes from previous call
    final leftover = _utf8Buffers.remove(sessionId);

    Uint8List toProcess;
    if (leftover != null && leftover.isNotEmpty) {
      // Prepend leftover bytes to new data
      toProcess = Uint8List(leftover.length + data.length);
      toProcess.setRange(0, leftover.length, leftover);
      toProcess.setRange(leftover.length, toProcess.length, data);
    } else {
      toProcess = data;
    }

    // Find where to split: look for incomplete UTF-8 at the end
    int completeEnd = toProcess.length;

    // Check last 1-3 bytes for incomplete multi-byte sequence
    for (int i = toProcess.length - 1;
         i >= 0 && i >= toProcess.length - 3;
         i--) {
      final byte = toProcess[i];
      if ((byte & 0x80) == 0) {
        // ASCII byte - everything is complete
        break;
      }
      if ((byte & 0xC0) == 0xC0) {
        // Start of multi-byte sequence
        final seqLen = _utf8SeqLength(byte);
        final remaining = toProcess.length - i;
        if (remaining < seqLen) {
          // Incomplete - split here
          completeEnd = i;
        }
        break;
      }
      // Continuation byte (10xxxxxx) - keep looking for start byte
    }

    // Decode complete portion
    if (completeEnd > 0) {
      final completeBytes = completeEnd == toProcess.length
          ? toProcess
          : Uint8List.sublistView(toProcess, 0, completeEnd);
      final text = utf8.decode(completeBytes, allowMalformed: true);
      writeToTerminal(sessionId, text);
    }

    // Save incomplete trailing bytes for next call
    if (completeEnd < toProcess.length) {
      _utf8Buffers[sessionId] = toProcess.sublist(completeEnd).toList();
    }
  }

  int _utf8SeqLength(int firstByte) {
    if ((firstByte & 0x80) == 0) return 1;
    if ((firstByte & 0xE0) == 0xC0) return 2;
    if ((firstByte & 0xF0) == 0xE0) return 3;
    if ((firstByte & 0xF8) == 0xF0) return 4;
    return 1;
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
    _utf8Buffers.remove(sessionId);
    _pendingWrites.remove(sessionId);
    _pendingFlushScheduled.remove(sessionId);
    _titles.remove(sessionId);
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
