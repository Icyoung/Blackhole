import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/terminal_group.dart';

class GroupStore {
  GroupStore({required this.onChanged, required this.sendCommand});

  final VoidCallback onChanged;
  final void Function(Map<String, dynamic> payload) sendCommand;

  final List<TerminalGroup> _groups = [];
  final Map<String, String> _sessionNames = {};
  String _activeGroupId = TerminalGroup.defaultGroupId;
  List<String> _groupOrder = [];
  SharedPreferences? _prefs;
  bool _hasSynced = false;
  bool _deferSync = false;
  final List<Map<String, dynamic>> _pendingCommands = [];

  List<TerminalGroup> get groups => List.unmodifiable(_groups);
  Map<String, String> get sessionNames => Map.unmodifiable(_sessionNames);
  String get activeGroupId => _activeGroupId;

  String getSessionName(String sessionId, int index) {
    return _sessionNames[sessionId] ?? 'Terminal ${index + 1}';
  }

  /// Check if user has set a custom name for the session
  bool hasCustomSessionName(String sessionId) {
    return _sessionNames.containsKey(sessionId);
  }

  TerminalGroup? get activeGroup {
    for (final group in _groups) {
      if (group.id == _activeGroupId) {
        return group;
      }
    }
    return null;
  }

  List<String> get activeGroupSessionIds {
    return List.unmodifiable(activeGroup?.sessionIds ?? const []);
  }

  Future<void> loadLocalOrder() async {
    await _ensurePrefs();
    _groupOrder = _prefs?.getStringList(_groupOrderKey) ?? <String>[];
    if (_groups.isNotEmpty && !_hasSynced) {
      _applyLocalOrder();
      onChanged();
    }
  }

  void applySync(Map<String, dynamic> payload) {
    final groupList = payload['groups'];
    final parsed = <TerminalGroup>[];
    if (groupList is List) {
      for (final entry in groupList) {
        if (entry is Map) {
          parsed.add(TerminalGroup.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }
    if (parsed.isEmpty) {
      parsed.add(_buildDefaultGroup());
    }
    _groups
      ..clear()
      ..addAll(parsed);

    // Parse session names
    final sessionNamesRaw = payload['sessionNames'];
    _sessionNames.clear();
    if (sessionNamesRaw is Map) {
      for (final entry in sessionNamesRaw.entries) {
        if (entry.key is String && entry.value is String) {
          _sessionNames[entry.key as String] = entry.value as String;
        }
      }
    }

    _ensureDefaultGroup();
    _deduplicateSessionIds();
    _validateActiveGroupId();
    _hasSynced = true;
    _groupOrder = _groups.map((group) => group.id).toList();
    unawaited(_saveGroupOrder());
    onChanged();
  }

  void requestGroupList() {
    sendCommand(<String, dynamic>{'type': 'group_list'});
  }

  void setDeferredSync(bool defer) {
    if (_deferSync == defer) {
      return;
    }
    _deferSync = defer;
    if (!defer) {
      flushPendingCommands();
    }
  }

  void flushPendingCommands() {
    if (_pendingCommands.isEmpty) {
      return;
    }
    for (final payload in _pendingCommands) {
      sendCommand(payload);
    }
    _pendingCommands.clear();
  }

  void createGroup({String? name}) {
    sendCommand(<String, dynamic>{
      'type': 'group_create',
      if (name != null) 'name': name,
    });
  }

  void renameGroup(String groupId, String name) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) {
      final group = _findGroup(groupId);
      if (group != null && group.name != trimmed) {
        group.name = trimmed;
        onChanged();
      }
    }
    _sendOrQueue(<String, dynamic>{
      'type': 'group_rename',
      'groupId': groupId,
      'name': name,
    });
  }

  void deleteGroup(String groupId) {
    _sendOrQueue(<String, dynamic>{'type': 'group_delete', 'groupId': groupId});
  }

  void moveSession(
    String sessionId,
    String targetGroupId, {
    int? oldIndex,
    int? newIndex,
  }) {
    _sendOrQueue(<String, dynamic>{
      'type': 'group_move_session',
      'sessionId': sessionId,
      'groupId': targetGroupId,
      if (oldIndex != null) 'oldIndex': oldIndex,
      if (newIndex != null) 'newIndex': newIndex,
    });
  }

  void reorderSession(String groupId, int oldIndex, int newIndex) {
    final group = _findGroup(groupId);
    if (group == null) {
      return;
    }
    if (oldIndex < 0 || oldIndex >= group.sessionIds.length) {
      return;
    }
    final requestedNewIndex = newIndex;
    final sessionId = group.sessionIds[oldIndex];
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0) {
      newIndex = 0;
    }
    if (newIndex >= group.sessionIds.length) {
      newIndex = group.sessionIds.length - 1;
    }
    if (newIndex != oldIndex) {
      final moved = group.sessionIds.removeAt(oldIndex);
      group.sessionIds.insert(newIndex, moved);
      onChanged();
    }
    moveSession(
      sessionId,
      groupId,
      oldIndex: oldIndex,
      newIndex: requestedNewIndex,
    );
  }

  void renameSession(String sessionId, String name) {
    final trimmed = name.trim();
    var changed = false;
    if (trimmed.isEmpty) {
      changed = _sessionNames.remove(sessionId) != null;
    } else if (_sessionNames[sessionId] != trimmed) {
      _sessionNames[sessionId] = trimmed;
      changed = true;
    }
    if (changed) {
      onChanged();
    }
    _sendOrQueue(<String, dynamic>{
      'type': 'session_rename',
      'sessionId': sessionId,
      'name': name,
    });
  }

  void reorderGroup(String groupId, int newIndex) {
    final oldIndex = _groups.indexWhere((group) => group.id == groupId);
    if (oldIndex == -1) {
      return;
    }
    if (newIndex < 0) {
      newIndex = 0;
    }
    if (newIndex >= _groups.length) {
      newIndex = _groups.length - 1;
    }
    final group = _groups.removeAt(oldIndex);
    _groups.insert(newIndex, group);
    _groupOrder = _groups.map((g) => g.id).toList();
    unawaited(_saveGroupOrder());
    onChanged();
    _sendOrQueue(<String, dynamic>{
      'type': 'group_reorder',
      'groupId': groupId,
      'newIndex': newIndex,
    });
  }

  void deleteGroupWithSessions(String groupId) {
    _sendOrQueue(<String, dynamic>{
      'type': 'group_delete_with_sessions',
      'groupId': groupId,
    });
  }

  int getGroupIndex(String groupId) {
    return _groups.indexWhere((g) => g.id == groupId);
  }

  void setActiveGroup(String groupId) {
    if (_activeGroupId == groupId) {
      return;
    }
    if (_findGroup(groupId) == null) {
      return;
    }
    _activeGroupId = groupId;
    onChanged();
  }

  void onDisconnected() {
    _pendingCommands.clear();
    _deferSync = false;
    if (_groups.isEmpty &&
        _sessionNames.isEmpty &&
        _activeGroupId == TerminalGroup.defaultGroupId) {
      return;
    }
    _groups.clear();
    _sessionNames.clear();
    _activeGroupId = TerminalGroup.defaultGroupId;
    onChanged();
  }

  TerminalGroup? _findGroup(String groupId) {
    for (final group in _groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  void _ensureDefaultGroup() {
    final index = _groups.indexWhere((group) => group.isDefault);
    if (index == -1) {
      _groups.insert(0, _buildDefaultGroup());
    }
  }

  void _validateActiveGroupId() {
    if (_findGroup(_activeGroupId) != null) {
      return;
    }
    _activeGroupId = TerminalGroup.defaultGroupId;
  }

  void _deduplicateSessionIds() {
    final seen = <String>{};
    for (final group in _groups) {
      final updated = <String>[];
      for (final sessionId in group.sessionIds) {
        if (seen.add(sessionId)) {
          updated.add(sessionId);
        }
      }
      if (updated.length != group.sessionIds.length) {
        group.sessionIds
          ..clear()
          ..addAll(updated);
      }
    }
  }

  TerminalGroup _buildDefaultGroup() {
    return TerminalGroup(
      id: TerminalGroup.defaultGroupId,
      name: TerminalGroup.defaultGroupName,
      sessionIds: const [],
      createdAt: DateTime.now(),
      sortOrder: 0,
    );
  }

  void _applyLocalOrder() {
    if (_groupOrder.isEmpty || _groups.isEmpty) {
      return;
    }
    final byId = <String, TerminalGroup>{
      for (final group in _groups) group.id: group,
    };
    final ordered = <TerminalGroup>[];
    for (final id in _groupOrder) {
      final group = byId.remove(id);
      if (group != null) {
        ordered.add(group);
      }
    }
    ordered.addAll(byId.values);
    _groups
      ..clear()
      ..addAll(ordered);
  }

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> _saveGroupOrder() async {
    await _ensurePrefs();
    await _prefs?.setStringList(_groupOrderKey, _groupOrder);
  }

  static const String _groupOrderKey = 'group_order';

  void _sendOrQueue(Map<String, dynamic> payload) {
    if (_deferSync) {
      _pendingCommands.add(payload);
      return;
    }
    sendCommand(payload);
  }
}
