enum DropSide { left, right, top, bottom }

class MultiWindowLayout {
  const MultiWindowLayout({
    this.schemaVersion = currentSchemaVersion,
    required this.rows,
    this.hasUserLayout = false,
    this.hasCustomStructure = false,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final List<LayoutRow> rows;
  /// User has interacted with the layout in any way (resize or restructure).
  final bool hasUserLayout;
  /// User has restructured the layout via drag-to-rearrange. When true, the
  /// layout is preserved across window-width breakpoint changes; when false,
  /// only weights are user-touched and a breakpoint cross will reflow.
  final bool hasCustomStructure;

  List<String> get sessionIds {
    return [
      for (final row in rows)
        for (final cell in row.cells) cell.sessionId,
    ];
  }

  MultiWindowLayout copyWith({
    int? schemaVersion,
    List<LayoutRow>? rows,
    bool? hasUserLayout,
    bool? hasCustomStructure,
  }) {
    return MultiWindowLayout(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      rows: rows ?? this.rows,
      hasUserLayout: hasUserLayout ?? this.hasUserLayout,
      hasCustomStructure: hasCustomStructure ?? this.hasCustomStructure,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'hasUserLayout': hasUserLayout,
      'hasCustomStructure': hasCustomStructure,
      'rows': rows.map((row) => row.toJson()).toList(),
    };
  }

  static MultiWindowLayout? fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != currentSchemaVersion) {
      return null;
    }
    final rowsJson = json['rows'];
    if (rowsJson is! List) {
      return null;
    }
    final rows = <LayoutRow>[];
    for (final entry in rowsJson) {
      if (entry is! Map) {
        return null;
      }
      final row = LayoutRow.fromJson(Map<String, dynamic>.from(entry));
      if (row == null) {
        return null;
      }
      rows.add(row);
    }
    return MultiWindowLayout(
      rows: normalizeRows(rows),
      hasUserLayout: json['hasUserLayout'] == true,
      hasCustomStructure: json['hasCustomStructure'] == true,
    );
  }

  static MultiWindowLayout fallback({
    required List<String> sessionIds,
    required int columns,
    bool hasUserLayout = false,
  }) {
    final safeColumns = columns <= 0 ? 1 : columns;
    final rows = <LayoutRow>[];
    for (var i = 0; i < sessionIds.length; i += safeColumns) {
      final cells =
          sessionIds
              .skip(i)
              .take(safeColumns)
              .map((id) => LayoutCell(sessionId: id, weight: 1))
              .toList();
      rows.add(LayoutRow(weight: 1, cells: normalizeCells(cells)));
    }
    return MultiWindowLayout(
      rows: normalizeRows(rows),
      hasUserLayout: hasUserLayout,
    );
  }

  MultiWindowLayout syncSessions({
    required List<String> sessionIds,
    required int defaultColumns,
    required int maxCellsPerRow,
  }) {
    if (rows.isEmpty || !hasUserLayout) {
      return fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
        hasUserLayout: false,
      );
    }

    final wanted = sessionIds.toSet();
    final nextRows = <LayoutRow>[];
    final present = <String>{};
    for (final row in rows) {
      final cells = <LayoutCell>[];
      for (final cell in row.cells) {
        if (wanted.contains(cell.sessionId) && present.add(cell.sessionId)) {
          cells.add(cell);
        }
      }
      if (cells.isNotEmpty) {
        nextRows.add(row.copyWith(cells: normalizeCells(cells)));
      }
    }

    final safeMax = maxCellsPerRow <= 0 ? 1 : maxCellsPerRow;
    for (final sessionId in sessionIds) {
      if (present.contains(sessionId)) {
        continue;
      }
      var targetRow = -1;
      for (var i = 0; i < nextRows.length; i++) {
        if (nextRows[i].cells.length < safeMax) {
          targetRow = i;
          break;
        }
      }
      if (targetRow == -1) {
        nextRows.add(LayoutRow(weight: 1, cells: const <LayoutCell>[]));
        targetRow = nextRows.length - 1;
      }
      final row = nextRows[targetRow];
      nextRows[targetRow] = row.copyWith(
        cells: normalizeCells([
          ...row.cells,
          LayoutCell(sessionId: sessionId, weight: 1),
        ]),
      );
      present.add(sessionId);
    }

    return copyWith(rows: normalizeRows(nextRows), hasUserLayout: true);
  }

  MultiWindowLayout resetKeepingOrder({required int columns}) {
    return fallback(
      sessionIds: sessionIds,
      columns: columns,
      hasUserLayout: true,
    );
  }

  /// Move [fromSessionId] adjacent to [toSessionId] on the given [side].
  /// The source cell is removed first (its row weight-normalized; row dropped
  /// if empty), then inserted at the target's edge. Vertical sides
  /// (left/right) insert into the target's row. Horizontal sides
  /// (top/bottom) split into a new row above/below the target's row.
  MultiWindowLayout moveCell({
    required String fromSessionId,
    required String toSessionId,
    required DropSide side,
  }) {
    if (fromSessionId == toSessionId) {
      return this;
    }
    // Snapshot weights so we can restore the moving cell's relative size.
    final movingCellWeight = _findCell(fromSessionId)?.weight ?? 1;

    // Remove source.
    final removed = <LayoutRow>[];
    for (final row in rows) {
      final cells = [
        for (final cell in row.cells)
          if (cell.sessionId != fromSessionId) cell,
      ];
      if (cells.isNotEmpty) {
        removed.add(row.copyWith(cells: normalizeCells(cells)));
      }
    }

    // Locate target after removal.
    var targetRowIndex = -1;
    var targetCellIndex = -1;
    for (var r = 0; r < removed.length; r++) {
      for (var c = 0; c < removed[r].cells.length; c++) {
        if (removed[r].cells[c].sessionId == toSessionId) {
          targetRowIndex = r;
          targetCellIndex = c;
          break;
        }
      }
      if (targetRowIndex != -1) break;
    }
    if (targetRowIndex == -1) {
      // Target was removed (target == source, already handled above) or
      // missing; bail out without changes.
      return this;
    }

    final newRows = [...removed];
    final movingCell =
        LayoutCell(sessionId: fromSessionId, weight: movingCellWeight);

    switch (side) {
      case DropSide.left:
      case DropSide.right:
        final targetRow = newRows[targetRowIndex];
        final insertAt =
            side == DropSide.left ? targetCellIndex : targetCellIndex + 1;
        final cells = [...targetRow.cells];
        cells.insert(insertAt, movingCell);
        newRows[targetRowIndex] = targetRow.copyWith(
          cells: normalizeCells(cells),
        );
        break;
      case DropSide.top:
      case DropSide.bottom:
        final insertAt =
            side == DropSide.top ? targetRowIndex : targetRowIndex + 1;
        newRows.insert(
          insertAt,
          LayoutRow(weight: 1, cells: [movingCell]),
        );
        break;
    }

    return copyWith(
      rows: normalizeRows(newRows),
      hasUserLayout: true,
      hasCustomStructure: true,
    );
  }

  LayoutCell? _findCell(String sessionId) {
    for (final row in rows) {
      for (final cell in row.cells) {
        if (cell.sessionId == sessionId) return cell;
      }
    }
    return null;
  }

  MultiWindowLayout resizeColumn(
    int rowIndex,
    int cellIndex,
    double deltaPx,
    double parentWidth, {
    double minWeight = 0.1,
  }) {
    if (parentWidth <= 0 ||
        rowIndex < 0 ||
        rowIndex >= rows.length ||
        cellIndex < 0 ||
        cellIndex + 1 >= rows[rowIndex].cells.length) {
      return this;
    }
    final row = rows[rowIndex];
    final cells = [...row.cells];
    final left = cells[cellIndex];
    final right = cells[cellIndex + 1];
    final deltaWeight = deltaPx / parentWidth;
    final pairTotal = left.weight + right.weight;
    final minPairWeight = pairTotal * minWeight;
    final nextLeft = (left.weight + deltaWeight).clamp(
      minPairWeight,
      pairTotal - minPairWeight,
    );
    final nextRight = pairTotal - nextLeft;
    cells[cellIndex] = left.copyWith(weight: nextLeft);
    cells[cellIndex + 1] = right.copyWith(weight: nextRight);
    final nextRows = [...rows];
    nextRows[rowIndex] = row.copyWith(cells: normalizeCells(cells));
    return copyWith(rows: normalizeRows(nextRows));
  }

  MultiWindowLayout resizeRow(
    int rowIndex,
    double deltaPx,
    double parentHeight, {
    double minWeight = 0.1,
  }) {
    if (parentHeight <= 0 || rowIndex < 0 || rowIndex + 1 >= rows.length) {
      return this;
    }
    final nextRows = [...rows];
    final top = nextRows[rowIndex];
    final bottom = nextRows[rowIndex + 1];
    final deltaWeight = deltaPx / parentHeight;
    final pairTotal = top.weight + bottom.weight;
    final minPairWeight = pairTotal * minWeight;
    final nextTop = (top.weight + deltaWeight).clamp(
      minPairWeight,
      pairTotal - minPairWeight,
    );
    final nextBottom = pairTotal - nextTop;
    nextRows[rowIndex] = top.copyWith(weight: nextTop);
    nextRows[rowIndex + 1] = bottom.copyWith(weight: nextBottom);
    return copyWith(rows: normalizeRows(nextRows));
  }
}

class LayoutRow {
  const LayoutRow({required this.weight, required this.cells});

  final double weight;
  final List<LayoutCell> cells;

  LayoutRow copyWith({double? weight, List<LayoutCell>? cells}) {
    return LayoutRow(weight: weight ?? this.weight, cells: cells ?? this.cells);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'weight': weight,
      'cells': cells.map((cell) => cell.toJson()).toList(),
    };
  }

  static LayoutRow? fromJson(Map<String, dynamic> json) {
    final cellsJson = json['cells'];
    if (cellsJson is! List) {
      return null;
    }
    final cells = <LayoutCell>[];
    for (final entry in cellsJson) {
      if (entry is! Map) {
        return null;
      }
      final cell = LayoutCell.fromJson(Map<String, dynamic>.from(entry));
      if (cell == null) {
        return null;
      }
      cells.add(cell);
    }
    final weight = _doubleFromJson(json['weight']);
    return LayoutRow(weight: weight ?? 1, cells: normalizeCells(cells));
  }
}

class LayoutCell {
  const LayoutCell({required this.sessionId, required this.weight});

  final String sessionId;
  final double weight;

  LayoutCell copyWith({String? sessionId, double? weight}) {
    return LayoutCell(
      sessionId: sessionId ?? this.sessionId,
      weight: weight ?? this.weight,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'sessionId': sessionId, 'weight': weight};
  }

  static LayoutCell? fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      return null;
    }
    final weight = _doubleFromJson(json['weight']);
    return LayoutCell(sessionId: sessionId, weight: weight ?? 1);
  }
}

List<LayoutRow> normalizeRows(List<LayoutRow> rows) {
  final nonEmpty = rows.where((row) => row.cells.isNotEmpty).toList();
  final total = nonEmpty.fold<double>(
    0,
    (sum, row) => sum + (row.weight > 0 ? row.weight : 1),
  );
  if (nonEmpty.isEmpty) {
    return const <LayoutRow>[];
  }
  return [
    for (final row in nonEmpty)
      row.copyWith(
        weight: (row.weight > 0 ? row.weight : 1) / total,
        cells: normalizeCells(row.cells),
      ),
  ];
}

List<LayoutCell> normalizeCells(List<LayoutCell> cells) {
  if (cells.isEmpty) {
    return const <LayoutCell>[];
  }
  final total = cells.fold<double>(
    0,
    (sum, cell) => sum + (cell.weight > 0 ? cell.weight : 1),
  );
  return [
    for (final cell in cells)
      cell.copyWith(weight: (cell.weight > 0 ? cell.weight : 1) / total),
  ];
}

double? _doubleFromJson(Object? value) {
  if (value is int) {
    return value.toDouble();
  }
  if (value is double) {
    return value;
  }
  return null;
}
