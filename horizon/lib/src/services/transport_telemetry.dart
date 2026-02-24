import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'transport_models.dart';

class TransportTelemetry {
  TransportTelemetry({required this.source, this.maxEvents = 500});

  final String source;
  final int maxEvents;
  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> snapshot() {
    return List<Map<String, dynamic>>.unmodifiable(
      _events.map((event) => Map<String, dynamic>.from(event)),
    );
  }

  void emit({
    required String event,
    TransportKind kind = TransportKind.unknown,
    String? transportId,
    String? pathId,
    String? switchReason,
    String? fallbackReason,
    int? probeRttMs,
    bool? connected,
    String? sessionId,
    Object? error,
    Map<String, dynamic>? extra,
  }) {
    final payload = <String, dynamic>{
      'event': event,
      'source': source,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'transport_kind': kind.wireName,
      'transport_id': transportId ?? 'unknown',
      'path_id': pathId ?? 'unknown',
      if (switchReason != null) 'switch_reason': switchReason,
      if (fallbackReason != null) 'fallback_reason': fallbackReason,
      if (probeRttMs != null) 'probe_rtt_ms': probeRttMs,
      if (connected != null) 'connected': connected,
      if (sessionId != null) 'session_id': sessionId,
      if (error != null) 'error': error.toString(),
      if (extra != null) ...extra,
    };

    _events.add(payload);
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }

    debugPrint('[transport_event] ${jsonEncode(payload)}');
  }
}
