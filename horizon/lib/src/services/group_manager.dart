import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/terminal_group.dart';
import 'group_storage_migrator.dart';

class GroupActionResult {
  const GroupActionResult({
    required this.changed,
    this.errorCode,
    this.errorMessage,
    this.groupId,
    this.sessionIds,
  });

  final bool changed;
  final String? errorCode;
  final String? errorMessage;
  final String? groupId;
  final List<String>? sessionIds;

  bool get ok => errorCode == null;

  static GroupActionResult success({bool changed = true, String? groupId, List<String>? sessionIds}) {
    return GroupActionResult(changed: changed, groupId: groupId, sessionIds: sessionIds);
  }

  static GroupActionResult failure(String code, String message) {
    return GroupActionResult(changed: false, errorCode: code, errorMessage: message);
  }
}

class GroupManager {
  final List<TerminalGroup> _groups = [];
  final Map<String, String> _sessionNames = {};
  bool _loaded = false;
  static const _uuid = Uuid();

  List<TerminalGroup> get groups => List.unmodifiable(_groups);
  Map<String, String> get sessionNames => Map.unmodifiable(_sessionNames);
  bool get isLoaded => _loaded;

  TerminalGroup get defaultGroup {
    final index = _groups.indexWhere((group) => group.isDefault);
    if (index != -1) {
      return _groups[index];
    }
    final created = _buildDefaultGroup();
    _groups.add(created);
    return created;
  }

  Future<void> load() async {
    var dirty = false;
    try {
      final file = await _storageFile();
      if (!await file.exists()) {
        _groups
          ..clear()
          ..add(_buildDefaultGroup());
        _loaded = true;
        await save();
        return;
      }

      final raw = await file.readAsString();
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

      // Load session names
      final sessionNamesRaw = data['sessionNames'];
      _sessionNames.clear();
      if (sessionNamesRaw is Map) {
        for (final entry in sessionNamesRaw.entries) {
          if (entry.key is String && entry.value is String) {
            _sessionNames[entry.key as String] = entry.value as String;
          }
        }
      }

      _groups
        ..clear()
        ..addAll(parsedGroups);

      if (!_ensureDefaultGroup()) {
        dirty = true;
      }
      if (_deduplicateSessionIds()) {
        dirty = true;
      }
      _loaded = true;
      if (dirty) {
        await save();
      }
    } catch (_) {
      _groups
        ..clear()
        ..add(_buildDefaultGroup());
      _loaded = true;
    }
  }

  Future<void> save() async {
    if (!_loaded) {
      return;
    }
    final file = await _storageFile();
    final payload = {
      'version': GroupStorageMigrator.currentVersion,
      'groups': _groups.map((group) => group.toJson()).toList(),
      'sessionNames': Map<String, String>.from(_sessionNames),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  Map<String, dynamic> buildSyncPayload() {
    return {
      'type': 'group_sync',
      'version': 1,
      'groups': _groups.map((group) => group.toJson()).toList(),
      'sessionNames': Map<String, String>.from(_sessionNames),
    };
  }

  GroupActionResult createGroup({String? name}) {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isEmpty) {
      return GroupActionResult.failure('invalid_name', 'Group name cannot be empty.');
    }
    final groupId = _uuid.v4();
    final group = TerminalGroup(
      id: groupId,
      name: trimmed?.isNotEmpty == true ? trimmed! : _nextGroupName(),
      sessionIds: const [],
      createdAt: DateTime.now(),
    );
    _groups.add(group);
    return GroupActionResult.success(changed: true, groupId: groupId);
  }

  GroupActionResult renameGroup(String groupId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return GroupActionResult.failure('invalid_name', 'Group name cannot be empty.');
    }
    final target = _findGroup(groupId);
    if (target == null) {
      return GroupActionResult.failure('group_not_found', 'Group not found.');
    }
    if (target.name == trimmed) {
      return GroupActionResult.success(changed: false);
    }
    target.name = trimmed;
    return GroupActionResult.success(changed: true);
  }

  GroupActionResult deleteGroup(String groupId, {bool closeSessions = false}) {
    if (groupId == TerminalGroup.defaultGroupId) {
      return GroupActionResult.failure('delete_default', 'Default group cannot be deleted.');
    }
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) {
      return GroupActionResult.failure('group_not_found', 'Group not found.');
    }
    final removed = _groups.removeAt(index);
    if (!closeSessions) {
      // Move sessions to default group
      final fallback = defaultGroup;
      for (final sessionId in removed.sessionIds) {
        if (!fallback.sessionIds.contains(sessionId)) {
          fallback.sessionIds.add(sessionId);
        }
      }
    }
    // Return the session IDs that need to be closed
    return GroupActionResult.success(
      changed: true,
      groupId: groupId,
      sessionIds: closeSessions ? removed.sessionIds : null,
    );
  }

  GroupActionResult reorderGroup(String groupId, int newIndex) {
    final currentIndex = _groups.indexWhere((group) => group.id == groupId);
    if (currentIndex == -1) {
      return GroupActionResult.failure('group_not_found', 'Group not found.');
    }
    if (newIndex < 0) {
      newIndex = 0;
    }
    if (newIndex >= _groups.length) {
      newIndex = _groups.length - 1;
    }
    if (currentIndex == newIndex) {
      return GroupActionResult.success(changed: false);
    }
    final group = _groups.removeAt(currentIndex);
    _groups.insert(newIndex, group);
    return GroupActionResult.success(changed: true);
  }

  GroupActionResult moveSession(
    String sessionId,
    String targetGroupId, {
    int? oldIndex,
    int? newIndex,
  }) {
    final target = _findGroup(targetGroupId);
    if (target == null) {
      return GroupActionResult.failure('group_not_found', 'Group not found.');
    }
    if (oldIndex != null && newIndex != null) {
      if (oldIndex < 0 || oldIndex >= target.sessionIds.length) {
        return GroupActionResult.failure('invalid_index', 'Invalid session index.');
      }
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      if (newIndex < 0 || newIndex >= target.sessionIds.length) {
        return GroupActionResult.failure('invalid_index', 'Invalid session index.');
      }
      final currentId = target.sessionIds[oldIndex];
      if (currentId != sessionId) {
        return GroupActionResult.failure('session_mismatch', 'Session index mismatch.');
      }
      final moved = target.sessionIds.removeAt(oldIndex);
      target.sessionIds.insert(newIndex, moved);
      return GroupActionResult.success(changed: true);
    }
    _removeSessionFromAllGroups(sessionId);
    if (!target.sessionIds.contains(sessionId)) {
      target.sessionIds.add(sessionId);
    }
    // Auto-delete empty non-default groups
    _cleanupEmptyGroups();
    return GroupActionResult.success(changed: true);
  }

  bool onSessionCreated(String sessionId) {
    _removeSessionFromAllGroups(sessionId);
    final target = defaultGroup;
    if (!target.sessionIds.contains(sessionId)) {
      target.sessionIds.add(sessionId);
      return true;
    }
    return false;
  }

  bool onSessionClosed(String sessionId) {
    var changed = false;
    for (final group in _groups) {
      if (group.sessionIds.remove(sessionId)) {
        changed = true;
      }
    }
    if (_sessionNames.remove(sessionId) != null) {
      changed = true;
    }
    // Auto-delete empty non-default groups
    if (_cleanupEmptyGroups()) {
      changed = true;
    }
    return changed;
  }

  GroupActionResult renameSession(String sessionId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      // Empty name means remove custom name (use default)
      if (_sessionNames.remove(sessionId) != null) {
        return GroupActionResult.success(changed: true);
      }
      return GroupActionResult.success(changed: false);
    }
    if (_sessionNames[sessionId] == trimmed) {
      return GroupActionResult.success(changed: false);
    }
    _sessionNames[sessionId] = trimmed;
    return GroupActionResult.success(changed: true);
  }

  bool reconcileSessions(Iterable<String> activeSessions) {
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
    return changed;
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
    final index = _groups.indexWhere((group) => group.isDefault);
    if (index == -1) {
      _groups.add(_buildDefaultGroup());
      return false;
    }
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

  void _removeSessionFromAllGroups(String sessionId) {
    for (final group in _groups) {
      group.sessionIds.remove(sessionId);
    }
  }

  bool _cleanupEmptyGroups() {
    final toRemove = <String>[];
    for (final group in _groups) {
      if (!group.isDefault && group.sessionIds.isEmpty) {
        toRemove.add(group.id);
      }
    }
    if (toRemove.isEmpty) {
      return false;
    }
    _groups.removeWhere((group) => toRemove.contains(group.id));
    return true;
  }

  TerminalGroup _buildDefaultGroup() {
    return TerminalGroup(
      id: TerminalGroup.defaultGroupId,
      name: TerminalGroup.defaultGroupName,
      sessionIds: const [],
      createdAt: DateTime.now(),
    );
  }

  String _nextGroupName() {
    const base = 'Group ';
    var index = 1;
    final existing = _groups.map((group) => group.name).toSet();
    while (existing.contains('$base$index')) {
      index += 1;
    }
    return '$base$index';
  }

  Future<File> _storageFile() async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final dir = Directory('$home/.blackhole/horizon');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/terminal_groups.json');
  }
}
