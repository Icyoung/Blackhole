import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void _vpnLog(String message) {
  final timestamp = DateTime.now().toUtc().toIso8601String();
  debugPrint('[$timestamp] [VPN] $message');
}

/// VPN connection status.
enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error;

  static VpnStatus fromString(String? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return VpnStatus.disconnected;
  }
}

/// VPN connection mode.
enum VpnConnectionMode {
  direct, // UDP hole-punched direct connection
  unknown;

  static VpnConnectionMode fromString(String? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return VpnConnectionMode.unknown;
  }
}

/// Configuration to start a VPN connection.
class VpnConfig {
  const VpnConfig({
    required this.privateKey,
    required this.peerPublicKey,
    this.presharedKey,
    this.keepaliveSecs = 25,
    required this.serverAddr,
    required this.serverPort,
    required this.clientIp,
    required this.serverIp,
    this.localPort,
    this.netcheckHost,
    this.netcheckPort,
    this.lanPort = 9527,
    this.subnet = '10.13.37.0/24',
    this.dns = const ['10.13.37.1'],
    this.dnsMatchDomains = const [],
    this.internalRoutes = const [],
    this.mtu = 1280,
    this.directCandidates = const [],
  });

  final String privateKey;
  final String peerPublicKey;
  final String? presharedKey;
  final int keepaliveSecs;
  final String serverAddr;
  final int serverPort;
  final String clientIp;
  final String serverIp;
  final int? localPort;
  final String? netcheckHost;
  final int? netcheckPort;
  final int lanPort;
  final String subnet;
  final List<String> dns;
  final List<String> dnsMatchDomains;
  final List<String> internalRoutes;
  final int mtu;
  final List<Map<String, dynamic>> directCandidates;

  Map<String, dynamic> toMap() => {
    'privateKey': privateKey,
    'peerPublicKey': peerPublicKey,
    if (presharedKey != null) 'presharedKey': presharedKey,
    'keepaliveSecs': keepaliveSecs,
    'serverAddr': serverAddr,
    'serverPort': serverPort,
    'clientIp': clientIp,
    'serverIp': serverIp,
    if (localPort != null) 'localPort': localPort,
    if (netcheckHost != null) 'netcheckHost': netcheckHost,
    if (netcheckPort != null) 'netcheckPort': netcheckPort,
    'lanPort': lanPort,
    'subnet': subnet,
    'dns': dns,
    'dnsMatchDomains': dnsMatchDomains,
    'internalRoutes': internalRoutes,
    'mtu': mtu,
    if (directCandidates.isNotEmpty) 'directCandidates': directCandidates,
  };
}

List<Map<String, dynamic>> planUserspaceDirectCandidates({
  required List<Map<String, dynamic>> configured,
  required String fallbackAddr,
  required int fallbackPort,
}) {
  final candidates = <Map<String, dynamic>>[];
  for (final raw in configured) {
    final addr = (raw['addr'] ?? raw['host'])?.toString().trim() ?? '';
    final port = (raw['port'] as num?)?.toInt() ?? 0;
    if (addr.isEmpty || port <= 0) {
      continue;
    }
    candidates.add(<String, dynamic>{
      'addr': addr,
      'port': port,
      'scope': raw['scope'] ?? 'configured',
      'priority': (raw['priority'] as num?)?.toInt() ?? 0,
      'source': raw['source'] ?? 'vpn_config',
    });
  }

  final normalizedFallback = fallbackAddr.trim();
  if (normalizedFallback.isNotEmpty && fallbackPort > 0) {
    candidates.add(<String, dynamic>{
      'addr': normalizedFallback,
      'port': fallbackPort,
      'scope': 'legacy',
      'priority': 0,
      'source': 'vpn_config',
    });
  }

  final prioritized =
      candidates.indexed.toList()..sort((lhs, rhs) {
        final lp = lhs.$2['priority'] as int;
        final rp = rhs.$2['priority'] as int;
        if (lp == rp) {
          return lhs.$1.compareTo(rhs.$1);
        }
        return rp.compareTo(lp);
      });

  final deduped = <Map<String, dynamic>>[];
  for (final candidate in prioritized.map((entry) => entry.$2)) {
    final duplicate = deduped.any(
      (existing) =>
          existing['addr'] == candidate['addr'] &&
          existing['port'] == candidate['port'],
    );
    if (!duplicate) {
      deduped.add(candidate);
    }
  }
  return deduped;
}

/// Service for managing VPN connections.
///
/// Uses platform MethodChannel to control the native Network Extension
/// (iOS/macOS) and listens for status changes via EventChannel.
class VpnService extends ChangeNotifier {
  VpnService({
    Duration handshakeCandidateTimeout = const Duration(seconds: 12),
    Duration handshakeTotalBudget = const Duration(seconds: 30),
    Duration candidateTickInterval = const Duration(seconds: 1),
    Duration setActiveCandidateRetryDelay = const Duration(milliseconds: 50),
    int setActiveCandidateRetries = 20,
    DateTime Function()? clock,
  }) : _handshakeCandidateTimeout = handshakeCandidateTimeout,
       _handshakeTotalBudget = handshakeTotalBudget,
       _candidateTickInterval = candidateTickInterval,
       _setActiveCandidateRetryDelay = setActiveCandidateRetryDelay,
       _setActiveCandidateRetries = setActiveCandidateRetries,
       _clock = clock ?? DateTime.now;

  final Duration _handshakeCandidateTimeout;
  final Duration _handshakeTotalBudget;
  final Duration _candidateTickInterval;
  final Duration _setActiveCandidateRetryDelay;
  final int _setActiveCandidateRetries;
  final DateTime Function() _clock;

  // Native VPN is enabled by default for iOS builds.
  static const bool isFeatureEnabled = bool.fromEnvironment(
    'BH_ENABLE_NATIVE_VPN',
    defaultValue: true,
  );

  static bool get isSupportedPlatform {
    if (!isFeatureEnabled || kIsWeb) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => true,
      TargetPlatform.macOS => true,
      TargetPlatform.android => true,
      _ => false,
    };
  }

  static bool resolveUserEnabled(bool? stored) => stored ?? isSupportedPlatform;

  static bool isHelperDenied(Object error) {
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      if (code == 'vpn_denied') {
        return true;
      }
      if (_isDeniedConsentText(error.message) ||
          _isDeniedConsentText(error.details?.toString())) {
        return true;
      }
    }
    return _isDeniedConsentText(error.toString());
  }

  static bool _isDeniedConsentText(String? text) {
    if (text == null || text.isEmpty) {
      return false;
    }
    final lower = text.toLowerCase();
    return lower.contains('user canceled') ||
        lower.contains('user cancelled') ||
        lower.contains('authorization was cancelled') ||
        lower.contains('user denied vpn permission') ||
        lower.contains('error -128') ||
        lower.contains('(-128)');
  }

  /// iOS PacketTunnelProvider rotates dest internally.
  static bool get dartOwnsDirectCandidates {
    if (!isSupportedPlatform) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.macOS => true,
      _ => false,
    };
  }

  static const _methodChannel = MethodChannel('com.blackhole.voyager/vpn');
  static const _eventChannel = EventChannel('com.blackhole.voyager/vpn_status');

  VpnStatus _status = VpnStatus.disconnected;
  VpnConnectionMode _connectionMode = VpnConnectionMode.unknown;
  String? _clientIp;
  String? _serverIp;
  int? _lanPort;
  int? _tunPacketsOut;
  int? _tunPacketsIn;
  int? _udpPacketsOut;
  int? _udpPacketsIn;
  int? _wgTxBytes;
  int? _wgRxBytes;
  int? _timeSinceLastHandshakeSecs;
  List<Map<String, dynamic>> _plannedDirectCandidates =
      const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _observedCandidates =
      const <Map<String, dynamic>>[];
  int? _activeDirectCandidateIndex;
  Map<String, dynamic>? _activeDirectCandidate;
  String? _directSessionState;
  bool? _directSessionViable;
  bool? _directSessionReady;
  int? _pendingDirectQueueDepth;
  int? _directWriteAttempts;
  int? _directWriteErrors;
  int? _directHandshakePacketsPrepared;
  int? _directHandshakePacketsSuppressed;
  int? _directProbeWriteAttempts;
  String? _lastDirectWriteLabel;
  String? _lastDirectWriteError;
  String? _error;
  StreamSubscription? _statusSubscription;
  Timer? _statusPollTimer;
  Timer? _candidateRotationTimer;
  DateTime? _negotiationStartedAt;
  DateTime? _handshakeAttemptStartedAt;
  DateTime? _handshakeCandidateStartedAt;
  int _userspaceCandidateIndex = 0;
  List<Map<String, dynamic>> _userspaceCandidates =
      const <Map<String, dynamic>>[];

  VpnStatus get status => _status;
  VpnConnectionMode get connectionMode => _connectionMode;
  String? get clientIp => _clientIp;
  String? get serverIp => _serverIp;
  int? get lanPort => _lanPort;
  int? get tunPacketsOut => _tunPacketsOut;
  int? get tunPacketsIn => _tunPacketsIn;
  int? get udpPacketsOut => _udpPacketsOut;
  int? get udpPacketsIn => _udpPacketsIn;
  int? get wgTxBytes => _wgTxBytes;
  int? get wgRxBytes => _wgRxBytes;
  int? get timeSinceLastHandshakeSecs => _timeSinceLastHandshakeSecs;
  List<Map<String, dynamic>> get plannedDirectCandidates =>
      _plannedDirectCandidates;
  List<Map<String, dynamic>> get observedCandidates => _observedCandidates;
  int? get activeDirectCandidateIndex => _activeDirectCandidateIndex;
  Map<String, dynamic>? get activeDirectCandidate => _activeDirectCandidate;
  String? get directSessionState => _directSessionState;
  bool? get directSessionViable => _directSessionViable;
  bool? get directSessionReady => _directSessionReady;
  int? get pendingDirectQueueDepth => _pendingDirectQueueDepth;
  int? get directWriteAttempts => _directWriteAttempts;
  int? get directWriteErrors => _directWriteErrors;
  int? get directHandshakePacketsPrepared => _directHandshakePacketsPrepared;
  int? get directHandshakePacketsSuppressed =>
      _directHandshakePacketsSuppressed;
  int? get directProbeWriteAttempts => _directProbeWriteAttempts;
  String? get lastDirectWriteLabel => _lastDirectWriteLabel;
  String? get lastDirectWriteError => _lastDirectWriteError;
  String? get error => _error;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isActive =>
      _status == VpnStatus.connected || _status == VpnStatus.connecting;
  bool get _hasCompletedHandshake =>
      _timeSinceLastHandshakeSecs != null && _timeSinceLastHandshakeSecs! >= 0;

  void beginNegotiation() {
    if (!isSupportedPlatform) {
      return;
    }
    _stopStatusPolling();
    _stopCandidateRotation();
    _negotiationStartedAt = DateTime.now().toUtc();
    _status = VpnStatus.connecting;
    _connectionMode = VpnConnectionMode.unknown;
    _clientIp = null;
    _serverIp = null;
    _lanPort = null;
    _tunPacketsOut = null;
    _tunPacketsIn = null;

    _udpPacketsOut = null;
    _udpPacketsIn = null;
    _wgTxBytes = null;
    _wgRxBytes = null;
    _timeSinceLastHandshakeSecs = null;
    _plannedDirectCandidates = const <Map<String, dynamic>>[];
    _observedCandidates = const <Map<String, dynamic>>[];
    _activeDirectCandidateIndex = null;
    _activeDirectCandidate = null;
    _directSessionState = null;
    _directSessionViable = null;
    _directSessionReady = null;
    _pendingDirectQueueDepth = null;
    _directWriteAttempts = null;
    _directWriteErrors = null;
    _directHandshakePacketsPrepared = null;
    _directHandshakePacketsSuppressed = null;
    _directProbeWriteAttempts = null;
    _lastDirectWriteLabel = null;
    _lastDirectWriteError = null;
    _error = null;
    _startStatusPolling();
    notifyListeners();
  }

  void failNegotiation(String message) {
    if (!isSupportedPlatform) {
      return;
    }
    _stopStatusPolling();
    _stopCandidateRotation();
    _negotiationStartedAt = null;
    _status = VpnStatus.error;
    _error = message;
    notifyListeners();
  }

  void cancelPendingStart() {
    if (!isSupportedPlatform) {
      return;
    }
    _stopStatusPolling();
    _stopCandidateRotation();
    _negotiationStartedAt = null;
    _status = VpnStatus.disconnected;
    _connectionMode = VpnConnectionMode.unknown;
    _clientIp = null;
    _serverIp = null;
    _lanPort = null;
    _tunPacketsOut = null;
    _tunPacketsIn = null;

    _udpPacketsOut = null;
    _udpPacketsIn = null;
    _wgTxBytes = null;
    _wgRxBytes = null;
    _timeSinceLastHandshakeSecs = null;
    _plannedDirectCandidates = const <Map<String, dynamic>>[];
    _observedCandidates = const <Map<String, dynamic>>[];
    _activeDirectCandidateIndex = null;
    _activeDirectCandidate = null;
    _directSessionState = null;
    _directSessionViable = null;
    _directSessionReady = null;
    _pendingDirectQueueDepth = null;
    _directWriteAttempts = null;
    _directWriteErrors = null;
    _directHandshakePacketsPrepared = null;
    _directHandshakePacketsSuppressed = null;
    _directProbeWriteAttempts = null;
    _lastDirectWriteLabel = null;
    _lastDirectWriteError = null;
    _error = null;
    notifyListeners();
  }

  /// Initialize the VPN service and start listening for status updates.
  void initialize() {
    if (!isSupportedPlatform) {
      return;
    }
    _statusSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          _applyStatusPayload(event);
        }
      },
      onError: (error) {
        _vpnLog('Status stream error: $error');
        _status = VpnStatus.error;
        _error = error.toString();
        notifyListeners();
      },
    );
    unawaited(refreshStatus());
  }

  void _applyStatusPayload(
    Map<dynamic, dynamic> payload, {
    bool notify = true,
  }) {
    var payloadStatus = VpnStatus.fromString(payload['status'] as String?);
    final handshakeAge =
        (payload['timeSinceLastHandshakeSecs'] as num?)?.toInt();
    if (payloadStatus == VpnStatus.connected &&
        (handshakeAge == null || handshakeAge < 0)) {
      payloadStatus = VpnStatus.connecting;
    }
    final payloadTimestamp =
        DateTime.tryParse(payload['timestamp'] as String? ?? '')?.toUtc();
    final negotiationStartedAt = _negotiationStartedAt;
    final staleDuringNegotiation =
        negotiationStartedAt != null &&
        payloadTimestamp != null &&
        payloadTimestamp.isBefore(negotiationStartedAt) &&
        (payloadStatus == VpnStatus.connecting ||
            payloadStatus == VpnStatus.connected);
    if (staleDuringNegotiation) {
      return;
    }

    _status = payloadStatus;
    _connectionMode = VpnConnectionMode.fromString(
      payload['connectionMode'] as String?,
    );
    _clientIp = payload['clientIp'] as String?;
    _serverIp = payload['serverIp'] as String?;
    _lanPort = (payload['lanPort'] as num?)?.toInt();
    _tunPacketsOut = (payload['tunPacketsOut'] as num?)?.toInt();
    _tunPacketsIn = (payload['tunPacketsIn'] as num?)?.toInt();

    _udpPacketsOut = (payload['udpPacketsOut'] as num?)?.toInt();
    _udpPacketsIn = (payload['udpPacketsIn'] as num?)?.toInt();
    _wgTxBytes = (payload['wgTxBytes'] as num?)?.toInt();
    _wgRxBytes = (payload['wgRxBytes'] as num?)?.toInt();
    _timeSinceLastHandshakeSecs = handshakeAge;
    _plannedDirectCandidates =
        (payload['plannedDirectCandidates'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];
    _observedCandidates =
        (payload['observedCandidates'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];
    _activeDirectCandidateIndex =
        (payload['activeDirectCandidateIndex'] as num?)?.toInt();
    _activeDirectCandidate = (payload['activeDirectCandidate'] as Map?)?.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    _directSessionState = payload['directSessionState'] as String?;
    _directSessionViable = payload['directSessionViable'] as bool?;
    _directSessionReady = payload['directSessionReady'] as bool?;
    _pendingDirectQueueDepth = (payload['pendingDirectQueueDepth'] as num?)
        ?.toInt();
    _directWriteAttempts = (payload['directWriteAttempts'] as num?)?.toInt();
    _directWriteErrors = (payload['directWriteErrors'] as num?)?.toInt();
    _directHandshakePacketsPrepared =
        (payload['directHandshakePacketsPrepared'] as num?)?.toInt();
    _directHandshakePacketsSuppressed =
        (payload['directHandshakePacketsSuppressed'] as num?)?.toInt();
    _directProbeWriteAttempts =
        (payload['directProbeWriteAttempts'] as num?)?.toInt();
    _lastDirectWriteLabel = payload['lastDirectWriteLabel'] as String?;
    _lastDirectWriteError = payload['lastDirectWriteError'] as String?;
    _error = payload['error'] as String?;
    if (_status == VpnStatus.disconnected || _status == VpnStatus.error) {
      _stopStatusPolling();
      _stopCandidateRotation();
      _negotiationStartedAt = null;
    } else if (_status == VpnStatus.connected || _hasCompletedHandshake) {
      _stopCandidateRotation();
      _negotiationStartedAt = null;
    }
    _vpnLog(
      'status=$_status mode=$_connectionMode '
      'udpIn=$_udpPacketsIn tunIn=$_tunPacketsIn wgRx=$_wgRxBytes '
      'directReady=$_directSessionReady handshakeSecs=$_timeSinceLastHandshakeSecs '
      'directViable=$_directSessionViable '
      'probes=$_directProbeWriteAttempts writeErr=$_directWriteErrors',
    );
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    if (!isSupportedPlatform) {
      return;
    }
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getStatus',
      );
      if (result != null) {
        _applyStatusPayload(result);
      }
    } on PlatformException catch (e) {
      _vpnLog('refreshStatus error: ${e.message}');
    }
  }

  /// Start a VPN connection with the given configuration.
  Future<void> start(VpnConfig config) async {
    if (!isSupportedPlatform) {
      return;
    }
    try {
      _status = VpnStatus.connecting;
      _negotiationStartedAt ??= DateTime.now().toUtc();
      _clientIp = config.clientIp;
      _serverIp = config.serverIp;
      _lanPort = config.lanPort;
      _tunPacketsOut = null;
      _tunPacketsIn = null;
      _udpPacketsOut = null;
      _udpPacketsIn = null;
      _wgTxBytes = null;
      _wgRxBytes = null;
      _timeSinceLastHandshakeSecs = null;
      _plannedDirectCandidates = const <Map<String, dynamic>>[];
      _observedCandidates = const <Map<String, dynamic>>[];
      _activeDirectCandidateIndex = null;
      _activeDirectCandidate = null;
      _directSessionState = null;
      _directSessionViable = null;
      _directSessionReady = null;
      _pendingDirectQueueDepth = null;
      _directWriteAttempts = null;
      _directWriteErrors = null;
      _directHandshakePacketsPrepared = null;
      _directHandshakePacketsSuppressed = null;
      _directProbeWriteAttempts = null;
      _lastDirectWriteLabel = null;
      _lastDirectWriteError = null;
      _error = null;
      notifyListeners();

      await _methodChannel.invokeMethod('start', config.toMap());
      if (dartOwnsDirectCandidates) {
        await _beginCandidateRotation(config);
      }
      await refreshStatus();
      _startStatusPolling();
    } on PlatformException catch (e) {
      _stopStatusPolling();
      _stopCandidateRotation();
      _negotiationStartedAt = null;
      _status = VpnStatus.error;
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  /// Stop the active VPN connection.
  Future<void> stop() async {
    if (!isSupportedPlatform) {
      return;
    }
    try {
      _status = VpnStatus.disconnecting;
      _negotiationStartedAt = null;
      _stopCandidateRotation();
      _startStatusPolling();
      notifyListeners();

      await _methodChannel.invokeMethod('stop');
      await refreshStatus();
    } on PlatformException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  void _startStatusPolling() {
    _statusPollTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refreshStatus());
    });
  }

  void _stopStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
  }

  Future<void> setActiveCandidate({
    required String addr,
    required int port,
  }) async {
    if (!dartOwnsDirectCandidates) {
      return;
    }
    await _methodChannel.invokeMethod('setActiveCandidate', {
      'addr': addr,
      'port': port,
    });
  }

  Future<void> _beginCandidateRotation(VpnConfig config) async {
    _stopCandidateRotation();
    _userspaceCandidates = planUserspaceDirectCandidates(
      configured: config.directCandidates,
      fallbackAddr: config.serverAddr,
      fallbackPort: config.serverPort,
    );
    if (_userspaceCandidates.isEmpty) {
      return;
    }
    _userspaceCandidateIndex = 0;
    _handshakeAttemptStartedAt = _clock().toUtc();
    await _activateCurrentUserspaceCandidate();
    _candidateRotationTimer = Timer.periodic(_candidateTickInterval, (_) {
      unawaited(_tickUserspaceCandidates());
    });
  }

  Future<void> _activateCurrentUserspaceCandidate() async {
    if (_userspaceCandidateIndex < 0 ||
        _userspaceCandidateIndex >= _userspaceCandidates.length) {
      return;
    }
    final candidate = _userspaceCandidates[_userspaceCandidateIndex];
    final addr = candidate['addr'] as String? ?? '';
    final port = (candidate['port'] as num?)?.toInt() ?? 0;
    _handshakeCandidateStartedAt = _clock().toUtc();
    if (addr.isEmpty || port <= 0) {
      return;
    }
    if (_hasCompletedHandshake) {
      return;
    }
    for (var attempt = 0; attempt < _setActiveCandidateRetries; attempt++) {
      if (_hasCompletedHandshake) {
        return;
      }
      try {
        await setActiveCandidate(addr: addr, port: port);
        return;
      } on PlatformException catch (e) {
        final canRetry =
            e.code == 'NO_VPN' && attempt + 1 < _setActiveCandidateRetries;
        if (!canRetry) {
          _vpnLog('setActiveCandidate error: ${e.message}');
          return;
        }
        if (_setActiveCandidateRetryDelay > Duration.zero) {
          await Future<void>.delayed(_setActiveCandidateRetryDelay);
        }
      }
    }
  }

  @visibleForTesting
  Future<void> tickUserspaceCandidatesForTest() => _tickUserspaceCandidates();

  Future<void> _tickUserspaceCandidates() async {
    if (!dartOwnsDirectCandidates) {
      return;
    }
    await refreshStatus();
    if (_hasCompletedHandshake || _status == VpnStatus.connected) {
      _stopCandidateRotation();
      return;
    }
    if (_status == VpnStatus.error || _status == VpnStatus.disconnected) {
      _stopCandidateRotation();
      return;
    }
    final now = _clock().toUtc();
    final attemptStartedAt = _handshakeAttemptStartedAt;
    final candidateStartedAt = _handshakeCandidateStartedAt;
    if (attemptStartedAt != null &&
        now.difference(attemptStartedAt) >= _handshakeTotalBudget) {
      await _failUserspaceHandshake();
      return;
    }
    if (candidateStartedAt != null &&
        now.difference(candidateStartedAt) >= _handshakeCandidateTimeout) {
      if (_userspaceCandidateIndex + 1 < _userspaceCandidates.length) {
        _userspaceCandidateIndex += 1;
        await _activateCurrentUserspaceCandidate();
      } else {
        await _failUserspaceHandshake();
      }
    }
  }

  Future<void> _failUserspaceHandshake() async {
    _stopCandidateRotation();
    try {
      await _methodChannel.invokeMethod('fail', {
        'error': 'WireGuard handshake timed out',
      });
    } on PlatformException catch (e) {
      _vpnLog('fail error: ${e.message}');
    }
    failNegotiation('WireGuard handshake timed out');
  }

  void _stopCandidateRotation() {
    _candidateRotationTimer?.cancel();
    _candidateRotationTimer = null;
    _handshakeAttemptStartedAt = null;
    _handshakeCandidateStartedAt = null;
    _userspaceCandidateIndex = 0;
    _userspaceCandidates = const <Map<String, dynamic>>[];
  }

  /// Generate a new X25519 keypair via the native layer.
  /// Returns a map with 'privateKey' and 'publicKey' (base64-encoded).
  Future<Map<String, String>> generateKeypair() async {
    final result = await _methodChannel.invokeMapMethod<String, dynamic>(
      'generateKeypair',
    );
    return {
      'privateKey': result?['privateKey'] as String? ?? '',
      'publicKey': result?['publicKey'] as String? ?? '',
    };
  }

  /// Get the current VPN status from the native layer.
  Future<VpnStatus> getStatus() async {
    await refreshStatus();
    return _status;
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _stopStatusPolling();
    _stopCandidateRotation();
    super.dispose();
  }
}
