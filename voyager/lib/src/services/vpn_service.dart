import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_capabilities.dart';

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

/// Service for managing VPN connections.
///
/// Uses platform MethodChannel to control the native Network Extension
/// (iOS/macOS) and listens for status changes via EventChannel.
class VpnService extends ChangeNotifier {
  VpnService();

  // Native VPN is enabled by default for iOS builds.
  static const bool isFeatureEnabled = bool.fromEnvironment(
    'BH_ENABLE_NATIVE_VPN',
    defaultValue: true,
  );

  static bool get isSupportedPlatform {
    if (!isFeatureEnabled || kIsWeb || VoyagerPlatform.isTvOS) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => true,
      TargetPlatform.macOS => true,
      TargetPlatform.android => true,
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
  DateTime? _negotiationStartedAt;

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

  void beginNegotiation() {
    if (!isSupportedPlatform) {
      return;
    }
    _stopStatusPolling();
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
    final payloadStatus = VpnStatus.fromString(payload['status'] as String?);
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
    _pendingDirectQueueDepth =
        (payload['pendingDirectQueueDepth'] as num?)?.toInt();
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
      _negotiationStartedAt = null;
    } else if (_status == VpnStatus.connected) {
      _negotiationStartedAt = null;
    }
    _vpnLog(
      'status=$_status mode=$_connectionMode '
      'udpIn=$_udpPacketsIn tunIn=$_tunPacketsIn wgRx=$_wgRxBytes '
      'directReady=$_directSessionReady directViable=$_directSessionViable '
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
      await refreshStatus();
      _startStatusPolling();
    } on PlatformException catch (e) {
      _stopStatusPolling();
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
    super.dispose();
  }
}
