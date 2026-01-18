import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/terminal_group.dart';
import 'group_storage_migrator.dart';

class GroupSnapshot {
  GroupSnapshot({required List<TerminalGroup> groups, required this.activeGroupId})
      : groups = groups.map((group) => group.copy()).toList();

  final List<TerminalGroup> groups;
  final String activeGroupId;
}

class GroupManager {
  GroupManager({required this.onChanged});

  final VoidCallback onChanged;
  final List<TerminalGroup> _groups = [];
  String _activeGroupId = TerminalGroup.defaultGroupId;
  SharedPreferences? _prefs;
  bool _loaded = false;

  List<TerminalGroup> get groups => List.unmodifiable(_groups);
  String get activeGroupId => _activeGroupId;
  bool get isLoaded => _loaded;

  TerminalGroup get defaultGroup {
    final existing = _groups.where((group) => group.isDefault).toList();
    if (existing.isNotEmpty) {
      return existing.first;
    }
    final created = TerminalGroup(
      id: TerminalGroup.defaultGroupId,
      name: TerminalGroup.defaultGroupName,
      sessionIds: const [],
      createdAt: DateTime.now(),
      sortOrder: 0,
    );
    _groups.insert(0, created);
    return created;
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

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_storageKey);
    var dirty = false;

    if (raw == null || raw.trim().isEmpty) {
      _groups
        ..clear()
        ..add(_buildDefaultGroup());
      _activeGroupId = TerminalGroup.defaultGroupId;
      dirty = true;
    } else {
      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          data = Map<String, dynamic>.from(decoded);
        } else {
          data = <String, dynamic>{};
          dirty = true;
        }
      } catch (_) {
        data = <String, dynamic>{};
        dirty = true;
      }

      data = GroupStorageMigrator.migrate(data);
      final groupList = data['groups'];
      final parsedGroups = <TerminalGroup>[];
      if (groupList is List) {
        for (final entry in groupList) {
          if (entry is Map) {
            parsedGroups.add(TerminalGroup.fromJson(Map<String, dynamic>.from(entry)));
          }
        }
      }
      if (parsedGroups.isEmpty) {
        parsedGroups.add(_buildDefaultGroup());
        dirty = true;
      }

      _groups
        ..clear()
        ..addAll(parsedGroups);

      final storedActive = data['activeGroupId'];
      _activeGroupId = storedActive is String ? storedActive : TerminalGroup.defaultGroupId;

      if (!_ensureDefaultGroup()) {
        dirty = true;
      }
      if (_deduplicateSessionIds()) {
        dirty = true;
      }
      if (_validateActiveGroupId()) {
        dirty = true;
      }
      _normalizeSortOrder();
    }

    _loaded = true;
    if (dirty) {
      unawaited(save());
    }
    onChanged();
  }

  Future<void> save() async {
    _prefs ??= await SharedPreferences.getInstance();
    _normalizeSortOrder();
    final payload = jsonEncode({
      'version': GroupStorageMigrator.currentVersion,
      'groups': _groups.map((group) => group.toJson()).toList(),
      'activeGroupId': _activeGroupId,
    });
    await _prefs?.setString(_storageKey, payload);
  }

  GroupSnapshot snapshot() {
    return GroupSnapshot(groups: _groups, activeGroupId: _activeGroupId);
  }

  void restoreSnapshot(GroupSnapshot snapshot) {
    _groups
      ..clear()
      ..addAll(snapshot.groups.map((group) => group.copy()));
    _activeGroupId = snapshot.activeGroupId;
    _ensureDefaultGroup();
    _validateActiveGroupId();
    onChanged();
  }

  TerminalGroup createGroup({String? name, bool persist = true}) {
    final group = TerminalGroup(
      id: _generateGroupId(),
      name: name?.trim().isNotEmpty == true ? name!.trim() : _nextGroupName(),
      sessionIds: const [],
      createdAt: DateTime.now(),
      sortOrder: _groups.length,
    );
    _groups.add(group);
    _activeGroupId = group.id;
    _notify(persist: persist);
    return group;
  }

  void renameGroup(String groupId, String name, {bool persist = true}) {
    final target = _findGroup(groupId);
    if (target == null) {
      return;
    }
    target.name = name;
    _notify(persist: persist);
  }

  bool deleteGroup(String groupId, {bool persist = true}) {
    if (groupId == TerminalGroup.defaultGroupId) {
      return false;
    }
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) {
      return false;
    }
    final removed = _groups.removeAt(index);
    final fallback = defaultGroup;
    for (final sessionId in removed.sessionIds) {
      if (!fallback.sessionIds.contains(sessionId)) {
        fallback.sessionIds.add(sessionId);
      }
    }
    if (_activeGroupId == groupId) {
      _activeGroupId = TerminalGroup.defaultGroupId;
    }
    _notify(persist: persist);
    return true;
  }

  void setActiveGroup(String groupId, {bool persist = true}) {
    if (_activeGroupId == groupId) {
      return;
    }
    if (_findGroup(groupId) == null) {
      return;
    }
    _activeGroupId = groupId;
    _notify(persist: persist);
  }

  void moveSession(String sessionId, String fromGroupId, String toGroupId, {bool persist = true}) {
    if (fromGroupId == toGroupId) {
      return;
    }
    final fromGroup = _findGroup(fromGroupId);
    final toGroup = _findGroup(toGroupId);
    if (fromGroup == null || toGroup == null) {
      return;
    }
    _removeSessionFromAllGroups(sessionId);
    if (!toGroup.sessionIds.contains(sessionId)) {
      toGroup.sessionIds.add(sessionId);
    }
    _notify(persist: persist);
  }

  void reorderSession(String groupId, int oldIndex, int newIndex, {bool persist = true}) {
    final target = _findGroup(groupId);
    if (target == null) {
      return;
    }
    if (oldIndex < 0 || oldIndex >= target.sessionIds.length) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= target.sessionIds.length) {
      return;
    }
    final sessionId = target.sessionIds.removeAt(oldIndex);
    target.sessionIds.insert(newIndex, sessionId);
    _notify(persist: persist);
  }

  void reorderGroup(int oldIndex, int newIndex, {bool persist = true}) {
    if (oldIndex < 0 || oldIndex >= _groups.length) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= _groups.length) {
      return;
    }
    final group = _groups.removeAt(oldIndex);
    _groups.insert(newIndex, group);
    _notify(persist: persist);
  }

  void onSessionListReceived(List<String> activeSessions) {
    reconcileSessions(activeSessions);
  }

  void onSessionCreated(String sessionId) {
    _removeSessionFromAllGroups(sessionId);
    final target = activeGroup ?? defaultGroup;
    if (!target.sessionIds.contains(sessionId)) {
      target.sessionIds.add(sessionId);
      _notify(persist: true);
    }
  }

  void onSessionClosed(String sessionId) {
    var changed = false;
    for (final group in _groups) {
      if (group.sessionIds.remove(sessionId)) {
        changed = true;
      }
    }
    if (changed) {
      _notify(persist: true);
    }
  }

  void onDisconnected() {
    var changed = false;
    for (final group in _groups) {
      if (group.sessionIds.isNotEmpty) {
        group.sessionIds.clear();
        changed = true;
      }
    }
    if (changed) {
      _notify(persist: false);
    }
  }

  void reconcileSessions(List<String> activeSessions, {bool persist = true}) {
    var changed = false;
    if (!_ensureDefaultGroup()) {
      changed = true;
    }
    final activeSet = activeSessions.toSet();

    for (final group in _groups) {
      final before = group.sessionIds.length;
      group.sessionIds.removeWhere((id) => !activeSet.contains(id));
      if (group.sessionIds.length != before) {
        changed = true;
      }
    }

    final assigned = <String>{};
    for (final group in _groups) {
      final updated = <String>[];
      for (final sessionId in group.sessionIds) {
        if (!assigned.contains(sessionId)) {
          assigned.add(sessionId);
          updated.add(sessionId);
        } else {
          changed = true;
        }
      }
      group.sessionIds
        ..clear()
        ..addAll(updated);
    }

    final missing = <String>[];
    for (final sessionId in activeSessions) {
      if (!assigned.contains(sessionId)) {
        missing.add(sessionId);
      }
    }
    if (missing.isNotEmpty) {
      final fallback = defaultGroup;
      for (final sessionId in missing) {
        if (!fallback.sessionIds.contains(sessionId)) {
          fallback.sessionIds.add(sessionId);
        }
      }
      changed = true;
    }

    if (_validateActiveGroupId()) {
      changed = true;
    }

    if (changed) {
      _notify(persist: persist);
    }
  }

  void _notify({required bool persist}) {
    if (persist) {
      unawaited(save());
    }
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

  bool _ensureDefaultGroup() {
    final existing = _groups.where((group) => group.isDefault).toList();
    if (existing.isNotEmpty) {
      return true;
    }
    _groups.insert(0, _buildDefaultGroup());
    return false;
  }

  bool _validateActiveGroupId() {
    if (_findGroup(_activeGroupId) != null) {
      return false;
    }
    _activeGroupId = TerminalGroup.defaultGroupId;
    return true;
  }

  bool _deduplicateSessionIds() {
    final seen = <String>{};
    var changed = false;
    for (final group in _groups) {
      final updated = <String>[];
      for (final sessionId in group.sessionIds) {
        if (seen.add(sessionId)) {
          updated.add(sessionId);
        } else {
          changed = true;
        }
      }
      if (updated.length != group.sessionIds.length) {
        group.sessionIds
          ..clear()
          ..addAll(updated);
      }
    }
    return changed;
  }

  void _normalizeSortOrder() {
    for (var i = 0; i < _groups.length; i += 1) {
      _groups[i].sortOrder = i;
    }
  }

  void _removeSessionFromAllGroups(String sessionId) {
    for (final group in _groups) {
      group.sessionIds.remove(sessionId);
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

  String _generateGroupId() {
    final random = Random();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final suffix = random.nextInt(1000000).toString().padLeft(6, '0');
    return 'group-$stamp-$suffix';
  }

  String _nextGroupName() {
    const base = '分组';
    var index = 1;
    final existing = _groups.map((group) => group.name).toSet();
    while (existing.contains('$base$index')) {
      index += 1;
    }
    return '$base$index';
  }

  static const String _storageKey = 'terminal_groups';
}
