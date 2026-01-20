import 'dart:convert';

class TerminalGroup {
  TerminalGroup({
    required this.id,
    required this.name,
    required List<String> sessionIds,
    required this.createdAt,
    this.sortOrder = 0,
  }) : sessionIds = List<String>.from(sessionIds);

  final String id;
  String name;
  List<String> sessionIds;
  final DateTime createdAt;
  int sortOrder;

  bool get isDefault => id == defaultGroupId;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'sessionIds': List<String>.from(sessionIds),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'sortOrder': sortOrder,
    };
  }

  factory TerminalGroup.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['createdAt'];
    DateTime createdAt;
    if (createdAtRaw is String) {
      createdAt = DateTime.tryParse(createdAtRaw)?.toLocal() ?? DateTime.now();
    } else {
      createdAt = DateTime.now();
    }
    final sortOrder = json['sortOrder'];
    return TerminalGroup(
      id: json['id'] as String? ?? _fallbackId(createdAt),
      name: json['name'] as String? ?? defaultGroupName,
      sessionIds: _parseSessionIds(json['sessionIds']),
      createdAt: createdAt,
      sortOrder: sortOrder is int ? sortOrder : 0,
    );
  }

  static List<String> _parseSessionIds(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.whereType<String>().toList();
        }
      } catch (_) {
        return <String>[];
      }
    }
    return <String>[];
  }

  static String _fallbackId(DateTime createdAt) {
    return 'group-${createdAt.millisecondsSinceEpoch}';
  }

  static const String defaultGroupId = 'default';
  static const String defaultGroupName = 'Default';
}
