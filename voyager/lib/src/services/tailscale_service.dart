import 'dart:async';
import 'package:flutter/services.dart';

/// Service for interacting with Tailscale via platform channels.
///
/// Phase 1: Uses platform channels to call system Tailscale capabilities.
/// Phase 2: May migrate to FFI for direct network stack integration.
class TailscaleService {
  static const _channel = MethodChannel('com.blackhole.voyager/tailscale');

  static TailscaleService? _instance;

  TailscaleService._();

  static TailscaleService get instance {
    _instance ??= TailscaleService._();
    return _instance!;
  }

  /// Check if Tailscale is installed and running on the system.
  Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Get the current Tailscale status.
  Future<TailscaleStatus> getStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('getStatus');
      if (result == null) {
        return TailscaleStatus(
          connected: false,
          selfNode: null,
          peers: [],
        );
      }

      return TailscaleStatus.fromMap(Map<String, dynamic>.from(result));
    } on PlatformException catch (e) {
      throw TailscaleException('Failed to get Tailscale status: ${e.message}');
    }
  }

  /// Get information about Tailscale peers.
  Future<List<TailscalePeer>> getPeers() async {
    try {
      final result = await _channel.invokeMethod<List>('getPeers');
      if (result == null) {
        return [];
      }

      return result
          .whereType<Map>()
          .map((m) => TailscalePeer.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } on PlatformException catch (e) {
      throw TailscaleException('Failed to get Tailscale peers: ${e.message}');
    }
  }

  /// Check if a specific peer is reachable.
  Future<bool> isPeerReachable(String peerId) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isPeerReachable',
        {'peerId': peerId},
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Get the Tailscale IP address for a peer.
  Future<String?> getPeerAddress(String peerId) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'getPeerAddress',
        {'peerId': peerId},
      );
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Measure RTT to a Tailscale peer.
  Future<Duration?> measurePeerRtt(String peerId) async {
    try {
      final result = await _channel.invokeMethod<int>(
        'measurePeerRtt',
        {'peerId': peerId},
      );
      if (result == null) {
        return null;
      }
      return Duration(milliseconds: result);
    } on PlatformException {
      return null;
    }
  }
}

/// Tailscale connection status.
class TailscaleStatus {
  const TailscaleStatus({
    required this.connected,
    required this.selfNode,
    required this.peers,
  });

  final bool connected;
  final TailscaleNode? selfNode;
  final List<TailscalePeer> peers;

  factory TailscaleStatus.fromMap(Map<String, dynamic> map) {
    return TailscaleStatus(
      connected: map['connected'] as bool? ?? false,
      selfNode: map['selfNode'] != null
          ? TailscaleNode.fromMap(Map<String, dynamic>.from(map['selfNode']))
          : null,
      peers: (map['peers'] as List?)
              ?.whereType<Map>()
              .map((m) => TailscalePeer.fromMap(Map<String, dynamic>.from(m)))
              .toList() ??
          [],
    );
  }
}

/// Information about a Tailscale node.
class TailscaleNode {
  const TailscaleNode({
    required this.id,
    required this.name,
    required this.addresses,
  });

  final String id;
  final String name;
  final List<String> addresses;

  factory TailscaleNode.fromMap(Map<String, dynamic> map) {
    return TailscaleNode(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      addresses: (map['addresses'] as List?)?.whereType<String>().toList() ?? [],
    );
  }
}

/// Information about a Tailscale peer.
class TailscalePeer {
  const TailscalePeer({
    required this.id,
    required this.name,
    required this.online,
    required this.addresses,
    this.lastSeen,
  });

  final String id;
  final String name;
  final bool online;
  final List<String> addresses;
  final DateTime? lastSeen;

  factory TailscalePeer.fromMap(Map<String, dynamic> map) {
    return TailscalePeer(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      online: map['online'] as bool? ?? false,
      addresses: (map['addresses'] as List?)?.whereType<String>().toList() ?? [],
      lastSeen: map['lastSeen'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['lastSeen'] as int)
          : null,
    );
  }
}

/// Exception thrown when Tailscale operations fail.
class TailscaleException implements Exception {
  const TailscaleException(this.message);

  final String message;

  @override
  String toString() => 'TailscaleException: $message';
}