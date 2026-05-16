import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/multi_window_layout.dart';

class MultiWindowLayoutController extends ChangeNotifier {
  MultiWindowLayout? _layout;
  String? _groupId;
  String? _loadedGroupId;
  SharedPreferences? _prefs;

  MultiWindowLayout? get layout => _layout;
  String? get groupId => _groupId;

  /// Read-only fallback for the build phase: returns the current layout if it
  /// covers [sessionIds] and matches the requested column policy, otherwise a
  /// non-persisted fallback. Never mutates controller state. Use this in
  /// [build] paths; mutations go through [syncSessions] from event callbacks.
  MultiWindowLayout effectiveLayout(
    List<String> sessionIds, {
    required int defaultColumns,
  }) {
    final current = _layout;
    if (current == null) {
      return MultiWindowLayout.fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
      );
    }
    final existing = current.sessionIds.toSet();
    final wanted = sessionIds.toSet();
    final sessionsMatch =
        existing.length == wanted.length && existing.containsAll(wanted);
    // User has restructured the layout: keep their structure exactly,
    // even across window-width breakpoints. Their drag-to-rearrange wins.
    if (current.hasCustomStructure) {
      if (sessionsMatch) {
        return current;
      }
      // Sessions drifted (rare race); render a fallback this frame and let
      // syncSessions catch up.
      return MultiWindowLayout.fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
      );
    }
    // Non-user (auto) layouts always re-flow with the current column policy
    // so window resize across breakpoints reflows panes instantly.
    if (!current.hasUserLayout) {
      return MultiWindowLayout.fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
      );
    }
    final maxCellsInRow = current.rows.fold<int>(
      0,
      (m, row) => row.cells.length > m ? row.cells.length : m,
    );
    // User-resized weights only apply when the window's current column policy
    // still allows this structure. If we've crossed a breakpoint
    // (e.g. 1-col → 2-col), reflow into a fresh fallback. Weights are
    // discarded since they're meaningless at the new column count.
    if (!sessionsMatch || maxCellsInRow != defaultColumns) {
      return MultiWindowLayout.fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
      );
    }
    return current;
  }

  Future<void> loadFor(String groupId) async {
    if (_groupId == groupId && _loadedGroupId == groupId) {
      return;
    }
    if (_groupId != groupId) {
      _layout = null;
    }
    _groupId = groupId;
    _prefs ??= await SharedPreferences.getInstance();
    if (_groupId != groupId) {
      return;
    }
    final raw = _prefs?.getString(_keyFor(groupId));
    MultiWindowLayout? loaded;
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          loaded = MultiWindowLayout.fromJson(Map<String, dynamic>.from(json));
        }
      } catch (_) {
        loaded = null;
      }
    }
    _layout = loaded;
    _loadedGroupId = groupId;
    notifyListeners();
  }

  MultiWindowLayout syncSessions(
    List<String> sessionIds, {
    required int defaultColumns,
    required int maxCellsPerRow,
  }) {
    final current = _layout;
    if (current != null && current.hasUserLayout) {
      // For user-customized layouts, only re-flow when sessionIds actually
      // differ — keep their pane proportions across resizes.
      final existingIds = current.sessionIds;
      var sameIds = existingIds.length == sessionIds.length;
      if (sameIds) {
        for (var i = 0; i < sessionIds.length; i++) {
          if (existingIds[i] != sessionIds[i]) {
            sameIds = false;
            break;
          }
        }
      }
      if (sameIds) {
        return current;
      }
    }
    // Non-user (fallback) layouts always regenerate so window resize across
    // column-count breakpoints reflows panes (e.g. wider window: 2 stacked
    // panes collapse into a single 2-column row).
    final next =
        current == null || !current.hasUserLayout
            ? MultiWindowLayout.fallback(
              sessionIds: sessionIds,
              columns: defaultColumns,
            )
            : current.syncSessions(
              sessionIds: sessionIds,
              defaultColumns: defaultColumns,
              maxCellsPerRow: maxCellsPerRow,
            );
    if (current != null && _layoutsEqual(current, next)) {
      return current;
    }
    _layout = next;
    notifyListeners();
    return next;
  }

  bool _layoutsEqual(MultiWindowLayout a, MultiWindowLayout b) {
    if (a.hasUserLayout != b.hasUserLayout) return false;
    if (a.rows.length != b.rows.length) return false;
    for (var r = 0; r < a.rows.length; r++) {
      final ra = a.rows[r];
      final rb = b.rows[r];
      if (ra.cells.length != rb.cells.length) return false;
      for (var c = 0; c < ra.cells.length; c++) {
        if (ra.cells[c].sessionId != rb.cells[c].sessionId) return false;
      }
    }
    return true;
  }

  void resizeColumn(
    int rowIndex,
    int cellIndex,
    double deltaPx,
    double parentWidth,
  ) {
    final current = _layout;
    if (current == null) {
      return;
    }
    _layout = current.resizeColumn(rowIndex, cellIndex, deltaPx, parentWidth);
    notifyListeners();
  }

  void resizeRow(int rowIndex, double deltaPx, double parentHeight) {
    final current = _layout;
    if (current == null) {
      return;
    }
    _layout = current.resizeRow(rowIndex, deltaPx, parentHeight);
    notifyListeners();
  }

  Future<void> moveCell({
    required String fromSessionId,
    required String toSessionId,
    required DropSide side,
  }) async {
    final current = _layout;
    if (current == null) {
      return;
    }
    final next = current.moveCell(
      fromSessionId: fromSessionId,
      toSessionId: toSessionId,
      side: side,
    );
    if (identical(next, current)) {
      return;
    }
    _layout = next.copyWith(hasUserLayout: true);
    final groupId = _groupId;
    if (groupId != null) {
      await _save(groupId, _layout!);
    }
    notifyListeners();
  }

  Future<void> commit() async {
    final current = _layout;
    final groupId = _groupId;
    if (current == null || groupId == null) {
      return;
    }
    _layout = current.copyWith(hasUserLayout: true);
    await _save(groupId, _layout!);
    notifyListeners();
  }

  Future<void> resetToFallback({
    required List<String> sessionIds,
    required int columns,
    required bool keepPaneOrder,
  }) async {
    final groupId = _groupId;
    if (groupId == null) {
      return;
    }
    if (keepPaneOrder && _layout != null) {
      _layout = _layout!.resetKeepingOrder(columns: columns);
    } else {
      _layout = MultiWindowLayout.fallback(
        sessionIds: sessionIds,
        columns: columns,
      );
    }
    await _save(groupId, _layout!);
    notifyListeners();
  }

  Future<void> _save(String groupId, MultiWindowLayout layout) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString(_keyFor(groupId), jsonEncode(layout.toJson()));
  }

  String _keyFor(String groupId) => 'multiWindowLayout:$groupId';
}
