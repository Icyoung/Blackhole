import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

enum _BinaryType {
  stdin(1),
  stdout(2),
  resize(3),
  ping(4),
  pong(5),
  unknown(255);

  const _BinaryType(this.code);

  final int code;

  static _BinaryType fromCode(int code) {
    for (final value in _BinaryType.values) {
      if (value.code == code) {
        return value;
      }
    }
    return _BinaryType.unknown;
  }
}

void main() {
  runApp(const VoyagerApp());
}

class VoyagerApp extends StatelessWidget {
  const VoyagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blackhole Voyager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F141B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A2A3A),
          brightness: Brightness.dark,
          surface: const Color(0xFF111620),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70),
          titleMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        useMaterial3: true,
      ),
      home: const VoyagerHome(),
    );
  }
}

class VoyagerHome extends StatefulWidget {
  const VoyagerHome({super.key});

  @override
  State<VoyagerHome> createState() => _VoyagerHomeState();
}

class _VoyagerHomeState extends State<VoyagerHome>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _quickBarKey = GlobalKey();
  final ScrollController _terminalScrollController = ScrollController();
  final TextEditingController _urlController = TextEditingController(
    text: 'ws://127.0.0.1:9527',
  );
  final TextEditingController _wormholeController = TextEditingController(
    text: 'ws://127.0.0.1:8080/ws',
  );
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final Map<String, Terminal> _terminals = {};
  final Map<String, TerminalController> _controllers = {};
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final Terminal _idleTerminal = Terminal(maxLines: 2000);
  final TerminalController _idleController = TerminalController();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _metricsDebounce;
  DateTime? _lastMessageAt;

  bool _connected = false;
  bool _autoReconnect = true;
  bool _chromeHidden = false;
  bool _useWormhole = false;
  bool _showHHKB = false;
  bool _hhkbFn = false;
  bool _hhkbShift = false;
  bool _shouldReconnect = false;
  int _reconnectDelaySeconds = 2;

  String? _lastResizeSessionId;
  int _lastResizeCols = 0;
  int _lastResizeRows = 0;
  double _quickBarHeight = 0;
  static const double _hhkbKeyboardHeight = 242; // 5*42 + 4*4 + 16 padding

  double get _bottomBarHeight => _showHHKB ? _quickBarHeight + _hhkbKeyboardHeight : _quickBarHeight;
  double _lastMetricsInsetsBottom = 0;
  Size _lastMetricsSize = Size.zero;

  final List<String> _sessions = [];
  String? _activeSessionId;

  bool _ctrl = false;
  bool _alt = false;
  bool _meta = false;

  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlController.addListener(_handleAddressChange);
    _wormholeController.addListener(_handleAddressChange);
  }

  @override
  void dispose() {
    _disconnect();
    WidgetsBinding.instance.removeObserver(this);
    _urlController.removeListener(_handleAddressChange);
    _wormholeController.removeListener(_handleAddressChange);
    _urlController.dispose();
    _wormholeController.dispose();
    _sessionController.dispose();
    _tokenController.dispose();
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _metricsDebounce?.cancel();
    _terminalScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _metricsDebounce?.cancel();
    _metricsDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      final media = MediaQuery.of(context);
      final bottom = media.viewInsets.bottom;
      final size = media.size;
      final sameInsets = (bottom - _lastMetricsInsetsBottom).abs() < 0.5;
      final sameSize = (size.width - _lastMetricsSize.width).abs() < 0.5 &&
          (size.height - _lastMetricsSize.height).abs() < 0.5;
      if (sameInsets && sameSize) {
        return;
      }
      _lastMetricsInsetsBottom = bottom;
      _lastMetricsSize = size;
      _scheduleActiveResize();
    });
  }

  void _handleAddressChange() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _connect() async {
    _shouldReconnect = true;
    _disconnect();
    setState(() {
      _error = null;
    });

    try {
      final uri = _useWormhole
          ? _buildWormholeUri()
          : Uri.parse(_urlController.text.trim());
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onDone: _handleConnectionClosed,
        onError: (error) {
          _error = 'WebSocket error: $error';
          _handleConnectionClosed();
        },
      );
      setState(() {
        _connected = true;
        _sessions.clear();
        _activeSessionId = null;
        _lastMessageAt = DateTime.now();
      });
      _reconnectDelaySeconds = 2;
      _sendListSessions();
      _startHeartbeat();
      _terminalViewKey.currentState?.requestKeyboard();
    } catch (error) {
      setState(() {
        _error = 'Failed to connect: $error';
        _connected = false;
      });
      _scheduleReconnect();
    }
  }

  void _handleConnectionClosed() {
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
    });
    _stopHeartbeat();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_autoReconnect || !_shouldReconnect || _connected) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelaySeconds), () {
      if (!mounted || _connected || !_autoReconnect || !_shouldReconnect) {
        return;
      }
      _connect();
    });
    _reconnectDelaySeconds = (_reconnectDelaySeconds * 2).clamp(2, 10);
  }

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    _sessions.clear();
    _activeSessionId = null;
    _terminals.clear();
    _controllers.clear();
    _stopHeartbeat();
  }

  void _handleMessage(dynamic message) {
    final decoded = _decodeIncoming(message);
    if (decoded is! Map) {
      return;
    }
    if (decoded?['type'] == 'unsupported') {
      final version = decoded?['version'];
      setState(() {
        _error = 'Unsupported protocol version: $version';
      });
      _disconnect();
      return;
    }
    _lastMessageAt = DateTime.now();
    final type = decoded?['type'];
    if (type == 'pong') {
      return;
    }
    if (type == 'error') {
      final message = decoded?['message'];
      if (message is String) {
        setState(() {
          _error = 'Server error: $message';
        });
      }
      return;
    }
    if (type == 'session_list') {
      final sessions = decoded?['sessions'];
      if (sessions is List) {
        _sessions
          ..clear()
          ..addAll(sessions.whereType<String>());
        if (_sessions.isEmpty) {
          _sendCreateSession();
        } else {
          _activeSessionId ??= _sessions.first;
          _terminalFor(_activeSessionId!);
        }
        setState(() {});
        _scheduleActiveResize();
      }
      return;
    }
    if (type == 'session_created') {
      final sessionId = decoded?['sessionId'];
      if (sessionId is String) {
        if (!_sessions.contains(sessionId)) {
          _sessions.add(sessionId);
        }
        _activeSessionId ??= sessionId;
        _terminalFor(sessionId);
        setState(() {});
        _scheduleActiveResize();
      }
      return;
    }
    if (type == 'session_closed') {
      final sessionId = decoded?['sessionId'];
      if (sessionId is String) {
        _sessions.remove(sessionId);
        _terminals.remove(sessionId);
        _controllers.remove(sessionId);
        if (_activeSessionId == sessionId) {
          _activeSessionId = _sessions.isNotEmpty ? _sessions.first : null;
        }
        setState(() {});
      }
      return;
    }
    if (type == 'stdout') {
      final data = decoded?['data'];
      final raw = decoded?['raw'];
      final sessionId = decoded?['sessionId'];
      if (sessionId is String) {
        if (data is String) {
          _terminalFor(sessionId).write(data);
        } else if (raw is Uint8List) {
          final text = utf8.decode(raw, allowMalformed: true);
          _terminalFor(sessionId).write(text);
        }
        if (sessionId == _activeSessionId) {
          setState(() {});
        }
      }
    }
  }

  Uri _buildWormholeUri() {
    final base = Uri.parse(_wormholeController.text.trim());
    final query = Map<String, String>.from(base.queryParameters);
    query['role'] = 'voyager';
    final session = _sessionController.text.trim();
    if (session.isNotEmpty) {
      query['session'] = session;
    }
    final token = _tokenController.text.trim();
    if (token.isNotEmpty) {
      query['token'] = token;
    }
    return base.replace(queryParameters: query);
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_connected) {
        return;
      }
      _sendPing();
      final last = _lastMessageAt;
      if (last == null) {
        return;
      }
      final silence = DateTime.now().difference(last);
      if (silence > const Duration(seconds: 20)) {
        _error = 'Heartbeat timeout: no data for ${silence.inSeconds}s';
        _disconnect();
        _scheduleReconnect();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _sendPing() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage({'type': 'ping'}));
  }

  Terminal _terminalFor(String sessionId) {
    return _terminals.putIfAbsent(sessionId, () {
      final terminal = Terminal(maxLines: 10000);
      terminal.onOutput = (data) => _handleTerminalInput(sessionId, data);
      terminal.onResize = (cols, rows, pixelWidth, pixelHeight) =>
          _handleResize(sessionId, cols, rows, pixelWidth, pixelHeight);
      _controllers.putIfAbsent(sessionId, () => TerminalController());
      return terminal;
    });
  }

  void _scheduleActiveResize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _forceResizeActiveTerminal();
    });
  }

  void _updateQuickBarHeight() {
    final context = _quickBarKey.currentContext;
    if (context == null) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    final height = box.size.height;
    if ((height - _quickBarHeight).abs() < 0.5) {
      return;
    }
    setState(() {
      _quickBarHeight = height;
    });
    _scheduleActiveResize();
  }

  void _forceResizeActiveTerminal() {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return;
    }
    final terminal = _activeTerminal;
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
    final viewState = _terminalViewKey.currentState;
    if (viewState == null) {
      return;
    }
    final renderTerminal = viewState.renderTerminal;
    final size = renderTerminal.size;
    if (!size.isFinite || size.width <= 0 || size.height <= 0) {
      return;
    }
    final padding = EdgeInsets.fromLTRB(4, 0, 4, _bottomBarHeight);
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
  }

  TerminalController _controllerFor(String sessionId) {
    return _controllers.putIfAbsent(sessionId, () => TerminalController());
  }

  Terminal? get _activeTerminal {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return _terminalFor(sessionId);
  }

  TerminalController? get _activeController {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return null;
    }
    return _controllerFor(sessionId);
  }

  void _handleTerminalInput(String sessionId, String data) {
    if (_activeSessionId == null || _activeSessionId != sessionId) {
      return;
    }
    var output = data.replaceAll('\n', '\r');
    if (_ctrl) {
      output = _applyCtrl(output);
      _ctrl = false;
    }
    if (_alt || _meta) {
      output = _applyAlt(output);
      _alt = false;
      _meta = false;
    }
    _sendRaw(output);
  }

  String _applyCtrl(String data) {
    final codes = data.runes.map((rune) {
      final ch = String.fromCharCode(rune);
      final upper = ch.toUpperCase();
      if (upper.codeUnitAt(0) >= 65 && upper.codeUnitAt(0) <= 90) {
        return String.fromCharCode(upper.codeUnitAt(0) - 64);
      }
      return ch;
    }).join();
    return codes;
  }

  String _applyAlt(String data) {
    final buffer = StringBuffer();
    for (final rune in data.runes) {
      buffer.writeCharCode(0x1b);
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  void _sendCtrl(String key) {
    _sendRaw(_applyCtrl(key));
  }

  void _handleResize(
    String sessionId,
    int cols,
    int rows,
    int pixelWidth,
    int pixelHeight,
  ) {
    final channel = _channel;
    if (channel == null || _activeSessionId != sessionId) {
      return;
    }
    final payload = _encodeBinaryMessage(
      _BinaryType.resize,
      sessionId,
      data: Uint8List.fromList([
        (rows >> 8) & 0xFF,
        rows & 0xFF,
        (cols >> 8) & 0xFF,
        cols & 0xFF,
      ]),
    );
    channel.sink.add(payload);
  }

  void _sendRaw(String data) {
    final channel = _channel;
    if (channel == null || _activeSessionId == null) {
      return;
    }
    final payload = _encodeBinaryMessage(
      _BinaryType.stdin,
      _activeSessionId!,
      data: Uint8List.fromList(utf8.encode(data)),
    );
    channel.sink.add(payload);
  }

  void _sendListSessions() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage({'type': 'list'}));
  }

  void _sendCreateSession() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage({'type': 'create'}));
  }

  void _sendCloseSession(String sessionId) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage({'type': 'close', 'sessionId': sessionId}));
  }

  String _encodeMessage(Map<String, dynamic> payload) {
    if (!payload.containsKey('v')) {
      payload['v'] = 1;
    }
    return jsonEncode(payload);
  }

  Map<String, dynamic>? _decodeIncoming(dynamic message) {
    if (message is String) {
      return _decodeMessage(message);
    }
    if (message is Uint8List) {
      return _decodeBinaryMessage(message);
    }
    if (message is List<int>) {
      return _decodeBinaryMessage(Uint8List.fromList(message));
    }
    return null;
  }

  Map<String, dynamic>? _decodeMessage(String message) {
    final decoded = jsonDecode(message);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(decoded);
    final version = map['v'];
    if (version != null && version != 1) {
      return {'type': 'unsupported', 'version': version};
    }
    return map;
  }

  Uint8List _encodeBinaryMessage(
    _BinaryType type,
    String sessionId, {
    required Uint8List data,
  }) {
    final sessionBytes = utf8.encode(sessionId);
    final buffer = BytesBuilder(copy: false)
      ..add([1, type.code])
      ..add([
        (sessionBytes.length >> 8) & 0xFF,
        sessionBytes.length & 0xFF,
      ])
      ..add(sessionBytes)
      ..add(data);
    return buffer.toBytes();
  }

  Map<String, dynamic>? _decodeBinaryMessage(Uint8List data) {
    if (data.length < 4) {
      return null;
    }
    final version = data[0];
    if (version != 1) {
      return {'type': 'unsupported', 'version': version};
    }
    final type = _BinaryType.fromCode(data[1]);
    final sessionLen = (data[2] << 8) | data[3];
    if (data.length < 4 + sessionLen) {
      return null;
    }
    final sessionBytes = data.sublist(4, 4 + sessionLen);
    final sessionId = utf8.decode(sessionBytes, allowMalformed: true);
    final payload = data.sublist(4 + sessionLen);

    switch (type) {
      case _BinaryType.stdin:
        return {
          'type': 'stdin',
          'sessionId': sessionId,
          'raw': Uint8List.fromList(payload),
        };
      case _BinaryType.stdout:
        return {
          'type': 'stdout',
          'sessionId': sessionId,
          'raw': Uint8List.fromList(payload),
        };
      case _BinaryType.resize:
        if (payload.length < 4) {
          return null;
        }
        final rows = (payload[0] << 8) | payload[1];
        final cols = (payload[2] << 8) | payload[3];
        return {
          'type': 'resize',
          'sessionId': sessionId,
          'rows': rows,
          'cols': cols,
        };
      case _BinaryType.ping:
        return {'type': 'ping'};
      case _BinaryType.pong:
        return {'type': 'pong'};
      case _BinaryType.unknown:
        return {'type': 'unsupported', 'version': version};
    }
  }

  void _sendKey(TerminalKey key) {
    _activeTerminal?.keyInput(key);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _sendRaw(text);
    }
  }

  Future<void> _copySelection() async {
    final controller = _activeController;
    final terminal = _activeTerminal;
    if (controller == null || terminal == null) {
      return;
    }
    final selection = controller.selection;
    if (selection == null) {
      return;
    }
    final text = terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
  }

  void _scrollToBottom() {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    _terminalScrollController.jumpTo(
      _terminalScrollController.position.maxScrollExtent,
    );
  }

  @override
  Widget build(BuildContext context) {
    const barColor = Color(0xFF111620);
    const activeColor = Color(0xFF1A2A3A);
    const overlayColor = Color(0x66000000);
    final terminal = _activeTerminal ?? _idleTerminal;
    final controller = _activeController ?? _idleController;
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateQuickBarHeight();
      }
    });

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      endDrawer: _buildSettingsDrawer(context),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(color: Colors.black),
          ),
          Positioned.fill(
            top: _chromeHidden ? (_sessions.length <= 1 ? 0 : 36) : MediaQuery.of(context).padding.top + 82,
            child: TerminalView(
              terminal,
              key: _terminalViewKey,
              controller: controller,
              scrollController: _terminalScrollController,
              autoResize: false,
              autofocus: true,
              deleteDetection: true,
              readOnly: _showHHKB,
              keyboardType: _showHHKB ? TextInputType.none : TextInputType.text,
              backgroundOpacity: 1.0,
              padding: EdgeInsets.fromLTRB(8, 4, 8, _bottomBarHeight + 8),
              textStyle: const TerminalStyle(
                fontFamily: 'Menlo',
                fontSize: 14,
              ),
            ),
          ),
          if (!_chromeHidden)
            Positioned(
              top: MediaQuery.of(context).padding.top + 82,
              left: 0,
              right: 0,
              height: 24,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.4), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _HeaderChrome(
              hidden: _chromeHidden,
              color: barColor,
              activeColor: activeColor,
              overlayColor: overlayColor,
              error: _error,
              onToggle: () {
                setState(() {
                  _chromeHidden = !_chromeHidden;
                });
                _scheduleActiveResize();
              },
              onAddSession: _sendCreateSession,
              sessions: _sessions,
              activeSessionId: _activeSessionId,
              onSelectSession: (id) {
                setState(() {
                  _activeSessionId = id;
                  _terminalFor(id);
                });
                _scheduleActiveResize();
              },
              onCloseSession: _sendCloseSession,
              connectionContent: _buildConnectionContent(context),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KeyedSubtree(
                    key: _quickBarKey,
                    child: _QuickActionsBar(
                      connected: _connected,
                      ctrl: _ctrl,
                      alt: _alt,
                      meta: _meta,
                      onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
                      onToggleAlt: () => setState(() => _alt = !_alt),
                      onToggleMeta: () => setState(() => _meta = !_meta),
                      onKey: _sendKey,
                      onPaste: _pasteClipboard,
                      onCopy: _copySelection,
                      onSend: _sendRaw,
                      onScrollToBottom: _scrollToBottom,
                    ),
                  ),
                  if (_showHHKB)
                    _HHKBKeyboard(
                      connected: _connected,
                      fn: _hhkbFn,
                      ctrl: _ctrl,
                      alt: _alt,
                      shift: _hhkbShift,
                      onKey: (key, {bool isSpecial = false}) {
                        if (_ctrl && !isSpecial) {
                          _sendCtrl(key);
                        } else if (_alt && !isSpecial) {
                          _sendRaw('\x1b$key');
                        } else {
                          _sendRaw(key);
                        }
                        // Reset modifiers after key press (except Fn)
                        if (_ctrl || _alt || _hhkbShift) {
                          setState(() {
                            _ctrl = false;
                            _alt = false;
                            _hhkbShift = false;
                          });
                        }
                      },
                      onToggleFn: () => setState(() => _hhkbFn = !_hhkbFn),
                      onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
                      onToggleAlt: () => setState(() => _alt = !_alt),
                      onToggleShift: () => setState(() => _hhkbShift = !_hhkbShift),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionContent(BuildContext context) {
    final urlText = _useWormhole
        ? _wormholeController.text.trim()
        : _urlController.text.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          _StatusDot(connected: _connected, size: 8),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _useWormhole ? 'WORMHOLE REMOTE' : 'LAN CONNECTION',
                  style: const TextStyle(
                    color: Color(0xFF4B7AA6),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  urlText.isEmpty ? 'Not Configured' : urlText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            value: _connected,
            activeColor: const Color(0xFF41C87A),
            onChanged: (value) {
              if (value) {
                _connect();
              } else {
                _shouldReconnect = false;
                _reconnectTimer?.cancel();
                _reconnectTimer = null;
                _disconnect();
              }
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70, size: 20),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsDrawer(BuildContext context) {
    final fieldFill = Colors.white.withOpacity(0.05);
    final fieldBorder = Colors.white.withOpacity(0.1);
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(color: Colors.white, fontSize: 18);

    return Drawer(
      backgroundColor: const Color(0xFF0F141B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          bottomLeft: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Row(
              children: [
                const Icon(Icons.settings_outlined, color: Color(0xFF4B7AA6)),
                const SizedBox(width: 12),
                Text('VOYAGER SETTINGS', style: titleStyle?.copyWith(fontSize: 14, letterSpacing: 1)),
              ],
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Connection Address'),
            const SizedBox(height: 12),
            TextField(
              controller: _useWormhole ? _wormholeController : _urlController,
              decoration: _buildInputDecoration('Address', fieldFill, fieldBorder),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Modes & Behavior'),
            const SizedBox(height: 8),
            _buildDrawerSwitch(
              'LAN Mode',
              !_useWormhole,
              (v) => setState(() => _useWormhole = !v),
            ),
            _buildDrawerSwitch(
              'Auto Reconnect',
              _autoReconnect,
              (v) => setState(() {
                _autoReconnect = v;
                if (!_autoReconnect) {
                  _reconnectTimer?.cancel();
                  _reconnectTimer = null;
                }
              }),
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Input'),
            const SizedBox(height: 8),
            _buildDrawerSwitch(
              'HHKB Keyboard',
              _showHHKB,
              (v) {
                setState(() => _showHHKB = v);
                // Trigger resize after state update
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scheduleActiveResize();
                });
              },
            ),
            if (_useWormhole) ...[
              const SizedBox(height: 24),
              _buildDrawerSection('Wormhole Remote Options'),
              const SizedBox(height: 12),
              TextField(
                controller: _sessionController,
                textCapitalization: TextCapitalization.characters,
                decoration: _buildInputDecoration('Session ID', fieldFill, fieldBorder, hint: '6-digit code'),
                style: const TextStyle(color: Colors.white, letterSpacing: 4, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tokenController,
                decoration: _buildInputDecoration('Token (Optional)', fieldFill, fieldBorder),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
            const SizedBox(height: 40),
            Text(
              'Blackhole Voyager v1.0.0',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerSection(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF4B7AA6),
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildDrawerSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Switch(
            value: value,
            activeColor: const Color(0xFF41C87A),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  InputDecoration _buildInputDecoration(String label, Color fill, Color border, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
      filled: true,
      fillColor: fill,
      isDense: true,
      labelStyle: const TextStyle(color: Color(0xFF9AA6B2), fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF4B7AA6), width: 1.5),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected, this.size = 10});

  final bool connected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF41C87A) : const Color(0xFFFF5C5C);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class _QuickActionsBar extends StatefulWidget {
  const _QuickActionsBar({
    required this.connected,
    required this.ctrl,
    required this.alt,
    required this.meta,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleMeta,
    required this.onKey,
    required this.onPaste,
    required this.onCopy,
    required this.onSend,
    required this.onScrollToBottom,
  });

  final bool connected;
  final bool ctrl;
  final bool alt;
  final bool meta;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleMeta;
  final void Function(TerminalKey key) onKey;
  final Future<void> Function() onPaste;
  final Future<void> Function() onCopy;
  final void Function(String data) onSend;
  final VoidCallback onScrollToBottom;

  @override
  State<_QuickActionsBar> createState() => _QuickActionsBarState();
}

class _QuickActionsBarState extends State<_QuickActionsBar> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _snapKeys = List.generate(5, (_) => GlobalKey());
  bool _isSnapping = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScrollEnd() {
    if (_isSnapping || !_scrollController.hasClients) return;

    final currentOffset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;

    if (currentOffset <= 0 || currentOffset >= maxScroll) return;

    // 收集所有吸附点的位置
    final snapOffsets = <double>[0];

    for (final key in _snapKeys) {
      final ctx = key.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          // 获取相对于 viewport 的位置
          final offset = _getSnapOffset(box);
          if (offset != null && offset > 0) {
            snapOffsets.add(offset);
          }
        }
      }
    }

    if (snapOffsets.length <= 1) return;

    snapOffsets.sort();

    // 找最近的吸附点
    double nearest = 0;
    double minDist = double.infinity;

    for (final snap in snapOffsets) {
      final dist = (currentOffset - snap).abs();
      if (dist < minDist) {
        minDist = dist;
        nearest = snap;
      }
    }

    nearest = nearest.clamp(0.0, maxScroll);

    if ((nearest - currentOffset).abs() > 2) {
      _isSnapping = true;
      _scrollController.animateTo(
        nearest,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      ).then((_) => _isSnapping = false);
    }
  }

  double? _getSnapOffset(RenderBox box) {
    try {
      // 获取 Row 相对于 viewport 的位置
      final ancestor = context.findRenderObject() as RenderBox?;
      if (ancestor == null) return null;

      final boxGlobal = box.localToGlobal(Offset.zero);
      final ancestorGlobal = ancestor.localToGlobal(Offset.zero);

      // 计算相对于滚动区域的偏移
      return _scrollController.offset + (boxGlobal.dx - ancestorGlobal.dx) - 12; // 12 是 padding
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111620),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification && !_isSnapping) {
            // 等惯性停止
            Future.delayed(const Duration(milliseconds: 80), _onScrollEnd);
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _ActionButton(label: 'CTRL', modifier: true, active: widget.ctrl, onTap: widget.onToggleCtrl),
              const SizedBox(width: 6),
              _ActionButton(label: 'ALT', modifier: true, active: widget.alt, onTap: widget.onToggleAlt),
              const SizedBox(width: 12),
              _ActionButton(key: _snapKeys[0], label: 'TAB', onTap: widget.connected ? () => widget.onKey(TerminalKey.tab) : null),
              const SizedBox(width: 6),
              _ActionButton(label: 'ESC', onTap: widget.connected ? () => widget.onKey(TerminalKey.escape) : null),
              const SizedBox(width: 12),
              _ActionButton(key: _snapKeys[1], icon: Icons.keyboard_arrow_up, onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowUp) : null),
              const SizedBox(width: 6),
              _ActionButton(icon: Icons.keyboard_arrow_down, onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowDown) : null),
              const SizedBox(width: 6),
              _ActionButton(icon: Icons.keyboard_arrow_left, onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowLeft) : null),
              const SizedBox(width: 6),
              _ActionButton(icon: Icons.keyboard_arrow_right, onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowRight) : null),
              const SizedBox(width: 12),
              _ActionButton(key: _snapKeys[2], icon: Icons.keyboard_return, onTap: widget.connected ? () => widget.onSend("\r") : null),
              const SizedBox(width: 6),
              _ActionButton(label: 'LF', onTap: widget.connected ? () => widget.onSend("\n") : null),
              const SizedBox(width: 12),
              _ActionButton(key: _snapKeys[3], label: 'PASTE', onTap: widget.connected ? widget.onPaste : null),
              const SizedBox(width: 6),
              _ActionButton(label: 'COPY', onTap: widget.connected ? widget.onCopy : null),
              const SizedBox(width: 6),
              _ActionButton(key: _snapKeys[4], icon: Icons.vertical_align_bottom, onTap: widget.onScrollToBottom),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderChrome extends StatelessWidget {
  const _HeaderChrome({
    required this.hidden,
    required this.color,
    required this.activeColor,
    required this.overlayColor,
    required this.onToggle,
    required this.onAddSession,
    required this.sessions,
    required this.activeSessionId,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.connectionContent,
    required this.error,
  });

  final bool hidden;
  final Color color;
  final Color activeColor;
  final Color overlayColor;
  final VoidCallback onToggle;
  final VoidCallback onAddSession;
  final List<String> sessions;
  final String? activeSessionId;
  final void Function(String id) onSelectSession;
  final void Function(String id) onCloseSession;
  final Widget connectionContent;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final hasMultipleSessions = sessions.length > 1;
    final showTabs = !hidden || hasMultipleSessions;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!hidden)
          _FrostedBar(
            color: color,
            overlayColor: overlayColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: topInset),
                connectionContent,
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5C5C).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFF5C5C).withOpacity(0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, size: 14, color: Color(0xFFFF5C5C)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error!,
                              style: const TextStyle(color: Color(0xFFFF5C5C), fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          color: showTabs ? color.withOpacity(0.8) : Colors.transparent,
          padding: EdgeInsets.only(top: hidden ? topInset : 0),
          child: Row(
            children: [
              if (showTabs)
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        for (final entry in sessions.asMap().entries)
                          _ChromeTabPill(
                            label: 'TERM ${entry.key + 1}',
                            active: entry.value == activeSessionId,
                            onTap: () => onSelectSession(entry.value),
                            onClose: () => onCloseSession(entry.value),
                            color: activeColor,
                            overlayColor: overlayColor,
                            width: _tabWidthForCount(
                              MediaQuery.of(context).size.width,
                              sessions.length,
                            ),
                          ),
                        _ChromeTabButton(
                          icon: Icons.add,
                          onTap: onAddSession,
                          color: activeColor,
                          overlayColor: overlayColor,
                          inverted: true,
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Spacer(),
              _ChromeTabButton(
                icon: hidden
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_up,
                onTap: onToggle,
                color: activeColor,
                overlayColor: overlayColor,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

double _tabWidthForCount(double screenWidth, int count) {
  if (count <= 0) {
    return 120;
  }
  final maxTabsWidth = screenWidth - 140;
  final width = maxTabsWidth / count;
  return width.clamp(80, 150).toDouble();
}

class _ChromeTabButton extends StatelessWidget {
  const _ChromeTabButton({
    required this.onTap,
    required this.color,
    required this.icon,
    required this.overlayColor,
    this.inverted = false,
  });

  final VoidCallback onTap;
  final Color color;
  final IconData icon;
  final Color overlayColor;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return _ChromeTabShell(
      onTap: onTap,
      color: color,
      overlayColor: overlayColor,
      inverted: inverted,
      child: SizedBox(
        width: 48,
        height: 36,
        child: Center(
          child: Icon(
            icon,
            color: Colors.white,
            size: 16,
          ),
        ),
      ),
    );
  }
}

class _ChromeTabPill extends StatelessWidget {
  const _ChromeTabPill({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.color,
    required this.overlayColor,
    required this.width,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final Color color;
  final Color overlayColor;
  final double width;

  @override
  Widget build(BuildContext context) {
    final textColor = active ? Colors.white : Colors.white60;
    
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: _ChromeTabShell(
        onTap: onTap,
        color: active ? color : Colors.transparent,
        overlayColor: active ? overlayColor : Colors.transparent,
        inverted: true,
        child: Container(
          width: width,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 10,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (active)
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 10, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChromeTabShell extends StatelessWidget {
  const _ChromeTabShell({
    required this.onTap,
    required this.color,
    required this.overlayColor,
    required this.child,
    this.inverted = false,
  });

  final VoidCallback onTap;
  final Color color;
  final Color overlayColor;
  final Widget child;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.translucent,
      child: ClipPath(
        clipper: inverted ? _TabClipperInverted() : _TabClipper(),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color),
              child: DecoratedBox(
                decoration: BoxDecoration(color: overlayColor),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabClipper extends CustomClipper<Path> {

  static Path buildPath(Size size) {
    final w = size.width;
    final h = size.height;

    // Fixed shoulder width (left+right). Clamp so it never exceeds the widget width.
    final moldWidth = w < 40.0 ? w : 40.0;

    const c1 = 0.40;
    const c2 = 0.65;

    final topY = 0.0;
    final bottomY = h * 0.9;

    final shoulder = moldWidth / 2.0;
    final leftJoinX = shoulder;
    final rightJoinX = w - shoulder;

    // Right curve control points (defined in absolute coordinates)
    final cp1R = Offset(rightJoinX + shoulder * c1, topY);
    final cp2R = Offset(rightJoinX + shoulder * c2, bottomY);

    // Mirror those control points across the vertical centerline x = w/2
    final cp1LForward = Offset(w - cp1R.dx, topY);
    final cp2LForward = Offset(w - cp2R.dx, bottomY);

    return Path()
      // Top cap
      ..moveTo(0, topY)
      ..lineTo(w, topY)

      // Right shoulder (top -> bottom)
      ..cubicTo(cp1R.dx, cp1R.dy, cp2R.dx, cp2R.dy, rightJoinX, bottomY)

      // Bottom flat stretch (the only part that grows with width)
      ..lineTo(leftJoinX, bottomY)

      // Left shoulder (bottom -> top), using the *reversed* mirrored control points
      ..cubicTo(
        cp2LForward.dx, cp2LForward.dy,
        cp1LForward.dx, cp1LForward.dy,
        0, topY,
      )
      ..close();
  }

  @override
  Path getClip(Size size) {
    return buildPath(size);
  }

  @override
  bool shouldReclip(covariant _TabClipper oldClipper) => false;
}

class _TabClipperInverted extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = _TabClipper.buildPath(size);
    final matrix = Matrix4.identity()
      ..translate(0.0, size.height)
      ..scale(1.0, -1.0);
    return path.transform(matrix.storage);
  }

  @override
  bool shouldReclip(covariant _TabClipperInverted oldClipper) => false;
}

class _FrostedBar extends StatelessWidget {
  const _FrostedBar({
    required this.color,
    required this.overlayColor,
    required this.child,
  });

  final Color color;
  final Color overlayColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.7),
            border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: overlayColor),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    this.label,
    this.icon,
    this.onTap,
    this.modifier = false,
    this.active = false,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool modifier;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    Color bgColor;
    Color borderColor;

    if (modifier) {
      bgColor = active ? const Color(0xFF284058) : const Color(0xFF141B24);
      borderColor = active ? const Color(0xFF4B7AA6) : const Color(0xFF223042);
    } else {
      bgColor = enabled ? const Color(0xFF1B2430) : const Color(0xFF0E131A);
      borderColor = enabled ? const Color(0xFF2E3A4A) : const Color(0xFF1A222D);
    }

    final textColor = modifier
        ? (active ? Colors.white : const Color(0xFF9AA6B2))
        : (enabled ? Colors.white : const Color(0xFF6D7785));

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
          boxShadow: (enabled || modifier)
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: icon != null
            ? Icon(icon, size: 16, color: textColor)
            : Text(
                label ?? '',
                style: TextStyle(
                  color: textColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
      ),
    );
  }
}

// HHKB Keyboard Widget
class _HHKBKeyboard extends StatelessWidget {
  const _HHKBKeyboard({
    required this.connected,
    required this.fn,
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.onKey,
    required this.onToggleFn,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleShift,
  });

  final bool connected;
  final bool fn;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final void Function(String key, {bool isSpecial}) onKey;
  final VoidCallback onToggleFn;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleShift;

  static const _bgColor = Color(0xFF1A1A1A);
  static const _keyColor = Color(0xFF2D2D2D);
  static const _keyBorder = Color(0xFF3D3D3D);
  static const _modActiveColor = Color(0xFF4B7AA6);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bgColor,
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildRow1(),
          const SizedBox(height: 4),
          _buildRow2(),
          const SizedBox(height: 4),
          _buildRow3(),
          const SizedBox(height: 4),
          _buildRow4(),
          const SizedBox(height: 4),
          _buildRow5(),
        ],
      ),
    );
  }

  Widget _buildRow1() {
    // Esc 1 2 3 4 5 6 7 8 9 0 - = \ `
    final keys = fn
        ? ['Esc', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12', 'Ins', 'Del']
        : ['Esc', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\\', '`'];
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  Widget _buildRow2() {
    // Tab Q W E R T Y U I O P [ ] BS
    final keys = fn
        ? ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 'BS']
        : ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', 'BS'];
    return Row(
      children: [
        _key(keys[0], flex: 15, special: true),
        ...keys.sublist(1, 13).map((k) => _key(k, flex: 10)),
        _key(keys[13], flex: 15, special: true),
      ],
    );
  }

  Widget _buildRow3() {
    // Ctrl A S D F G H J K L ; ' Enter
    final baseKeys = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'"];
    final fnKeys = ['A', 'S', 'D', 'F', 'G', '←', '↓', '↑', '→', ';', "'"];
    final keys = fn ? fnKeys : baseKeys;
    return Row(
      children: [
        _modKey('Ctrl', ctrl, onToggleCtrl, flex: 18),
        ...keys.map((k) => _key(k, flex: 10)),
        _key('Enter', flex: 22, special: true),
      ],
    );
  }

  Widget _buildRow4() {
    // Shift Z X C V B N M , . / Shift
    final keys = ['Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/'];
    return Row(
      children: [
        _modKey('Shift', shift, onToggleShift, flex: 22),
        ...keys.map((k) => _key(k, flex: 10)),
        _modKey('Shift', shift, onToggleShift, flex: 18),
      ],
    );
  }

  Widget _buildRow5() {
    // Fn Meta Alt [Space] Alt Meta Fn
    return Row(
      children: [
        _modKey('Fn', fn, onToggleFn, flex: 12),
        _key('◇', flex: 12, special: true), // Meta/Super
        _modKey('Alt', alt, onToggleAlt, flex: 12),
        _key('', flex: 60, special: true, isSpace: true), // Space
        _modKey('Alt', alt, onToggleAlt, flex: 12),
        _key('◇', flex: 12, special: true),
        _modKey('Fn', fn, onToggleFn, flex: 12),
      ],
    );
  }

  Widget _key(String label, {int flex = 1, bool special = false, bool isSpace = false}) {
    String output = label;
    bool isSpecialKey = special;

    // 处理特殊键的输出
    if (label == 'Esc') {
      output = '\x1b';
      isSpecialKey = true;
    } else if (label == 'Tab') {
      output = '\t';
      isSpecialKey = true;
    } else if (label == 'Enter') {
      output = '\r';
      isSpecialKey = true;
    } else if (label == 'BS') {
      output = '\x7f';
      isSpecialKey = true;
    } else if (label == 'Del') {
      output = '\x1b[3~';
      isSpecialKey = true;
    } else if (label == 'Ins') {
      output = '\x1b[2~';
      isSpecialKey = true;
    } else if (isSpace) {
      output = ' ';
    } else if (label == '←') {
      output = '\x1b[D';
      isSpecialKey = true;
    } else if (label == '→') {
      output = '\x1b[C';
      isSpecialKey = true;
    } else if (label == '↑') {
      output = '\x1b[A';
      isSpecialKey = true;
    } else if (label == '↓') {
      output = '\x1b[B';
      isSpecialKey = true;
    } else if (label.startsWith('F') && label.length > 1) {
      final fNum = int.tryParse(label.substring(1));
      if (fNum != null && fNum >= 1 && fNum <= 12) {
        output = _getFnKeyCode(fNum);
        isSpecialKey = true;
      }
    } else if (label == '◇') {
      // Meta key - don't send
      output = '';
    } else if (label.length == 1) {
      // 字母键：默认小写，shift 时大写
      final code = label.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        // A-Z
        output = shift ? label : label.toLowerCase();
      } else if (shift) {
        // 其他字符应用 shift
        output = _applyShift(label);
      }
    }

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: _HHKBKey(
          label: isSpace ? '' : label,
          enabled: connected && output.isNotEmpty,
          onTap: () => onKey(output, isSpecial: isSpecialKey),
          fontSize: label.length > 2 ? 10.0 : 13.0,
        ),
      ),
    );
  }

  Widget _modKey(String label, bool active, VoidCallback onTap, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: _HHKBKey(
          label: label,
          enabled: true,
          active: active,
          isModifier: true,
          onTap: onTap,
          fontSize: 10,
        ),
      ),
    );
  }

  String _getFnKeyCode(int n) {
    const codes = {
      1: '\x1bOP',
      2: '\x1bOQ',
      3: '\x1bOR',
      4: '\x1bOS',
      5: '\x1b[15~',
      6: '\x1b[17~',
      7: '\x1b[18~',
      8: '\x1b[19~',
      9: '\x1b[20~',
      10: '\x1b[21~',
      11: '\x1b[23~',
      12: '\x1b[24~',
    };
    return codes[n] ?? '';
  }

  String _applyShift(String char) {
    const shiftMap = {
      '1': '!', '2': '@', '3': '#', '4': '\$', '5': '%',
      '6': '^', '7': '&', '8': '*', '9': '(', '0': ')',
      '-': '_', '=': '+', '[': '{', ']': '}', '\\': '|',
      ';': ':', "'": '"', ',': '<', '.': '>', '/': '?',
      '`': '~',
    };
    if (shiftMap.containsKey(char)) {
      return shiftMap[char]!;
    }
    if (char.length == 1 && char.codeUnitAt(0) >= 97 && char.codeUnitAt(0) <= 122) {
      return char.toUpperCase();
    }
    return char;
  }
}

class _HHKBKey extends StatefulWidget {
  const _HHKBKey({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.active = false,
    this.isModifier = false,
    this.fontSize = 13,
  });

  final String label;
  final bool enabled;
  final bool active;
  final bool isModifier;
  final VoidCallback onTap;
  final double fontSize;

  @override
  State<_HHKBKey> createState() => _HHKBKeyState();
}

class _HHKBKeyState extends State<_HHKBKey> {
  bool _pressed = false;
  OverlayEntry? _bubbleEntry;
  final GlobalKey _keyKey = GlobalKey();

  static const _keyColor = Color(0xFF2D2D2D);
  static const _keyPressedColor = Color(0xFF1A1A1A);
  static const _keyBorder = Color(0xFF3D3D3D);
  static const _modActiveColor = Color(0xFF4B7AA6);
  static const _modPressedColor = Color(0xFF3A6080);

  @override
  void dispose() {
    _hideBubble();
    super.dispose();
  }

  void _showBubble() {
    if (widget.label.isEmpty || widget.isModifier) return;

    final renderBox = _keyKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _bubbleEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx + size.width / 2 - 28,
        top: position.dy - 52,
        child: IgnorePointer(
          child: Container(
            width: 56,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF3A3A3A),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_bubbleEntry!);
  }

  void _hideBubble() {
    _bubbleEntry?.remove();
    _bubbleEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color borderColor;

    if (widget.isModifier) {
      if (_pressed) {
        bgColor = widget.active ? _modPressedColor : _keyPressedColor;
      } else {
        bgColor = widget.active ? _modActiveColor : _keyColor;
      }
      borderColor = widget.active ? _modActiveColor.withOpacity(0.8) : _keyBorder;
    } else {
      bgColor = _pressed ? _keyPressedColor : _keyColor;
      borderColor = _keyBorder;
    }

    return GestureDetector(
      onTapDown: widget.enabled ? (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
        _showBubble();
      } : null,
      onTapUp: widget.enabled ? (_) {
        setState(() => _pressed = false);
        _hideBubble();
      } : null,
      onTapCancel: widget.enabled ? () {
        setState(() => _pressed = false);
        _hideBubble();
      } : null,
      onTap: widget.enabled ? widget.onTap : null,
      child: Container(
        key: _keyKey,
        height: 42,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: borderColor, width: 0.5),
          boxShadow: _pressed
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.enabled ? Colors.white : Colors.white38,
              fontSize: widget.fontSize,
              fontWeight: widget.isModifier ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
