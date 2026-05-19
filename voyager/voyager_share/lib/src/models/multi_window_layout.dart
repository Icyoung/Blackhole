enum DropSide { left, right, top, bottom }

enum LayoutSplitAxis { horizontal, vertical }

class MultiWindowLayout {
  const MultiWindowLayout({
    this.schemaVersion = currentSchemaVersion,
    required this.root,
    this.hasUserLayout = false,
    this.hasCustomStructure = false,
  });

  static const int currentSchemaVersion = 2;

  final int schemaVersion;
  final LayoutNode? root;

  /// User has interacted with the layout in any way (resize or restructure).
  final bool hasUserLayout;

  /// User has restructured the layout via drag-to-rearrange. When true, the
  /// layout is preserved across window-width breakpoints; when false, only
  /// weights are user-touched and a breakpoint cross can reflow.
  final bool hasCustomStructure;

  List<String> get sessionIds => root?.sessionIds ?? const <String>[];

  int get maxHorizontalLeafCount => _maxHorizontalLeafCount(root);

  MultiWindowLayout copyWith({
    int? schemaVersion,
    LayoutNode? root,
    bool clearRoot = false,
    bool? hasUserLayout,
    bool? hasCustomStructure,
  }) {
    return MultiWindowLayout(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      root: clearRoot ? null : normalizeNode(root ?? this.root),
      hasUserLayout: hasUserLayout ?? this.hasUserLayout,
      hasCustomStructure: hasCustomStructure ?? this.hasCustomStructure,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'hasUserLayout': hasUserLayout,
      'hasCustomStructure': hasCustomStructure,
      'root': root?.toJson(),
    };
  }

  static MultiWindowLayout? fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version == currentSchemaVersion) {
      final rootJson = json['root'];
      final root =
          rootJson is Map
              ? LayoutNode.fromJson(Map<String, dynamic>.from(rootJson))
              : null;
      return MultiWindowLayout(
        root: normalizeNode(root),
        hasUserLayout: json['hasUserLayout'] == true,
        hasCustomStructure: json['hasCustomStructure'] == true,
      );
    }
    if (version == 1) {
      return _fromLegacyRowsJson(json);
    }
    return null;
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
      root: _rootFromRows(normalizeRows(rows)),
      hasUserLayout: hasUserLayout,
      hasCustomStructure: false,
    );
  }

  MultiWindowLayout syncSessions({
    required List<String> sessionIds,
    required int defaultColumns,
    required int maxCellsPerRow,
  }) {
    if (root == null || !hasUserLayout) {
      return fallback(
        sessionIds: sessionIds,
        columns: defaultColumns,
        hasUserLayout: false,
      );
    }

    final wanted = sessionIds.toSet();
    final present = <String>{};
    var nextRoot = _pruneSessions(root!, wanted, present);
    final safeMax = maxCellsPerRow <= 0 ? 1 : maxCellsPerRow;
    for (final sessionId in sessionIds) {
      if (present.contains(sessionId)) {
        continue;
      }
      nextRoot = _appendSession(nextRoot, sessionId, safeMax);
      present.add(sessionId);
    }

    return copyWith(root: nextRoot, hasUserLayout: true);
  }

  MultiWindowLayout resetKeepingOrder({required int columns}) {
    return fallback(
      sessionIds: sessionIds,
      columns: columns,
      hasUserLayout: true,
    );
  }

  MultiWindowLayout moveCell({
    required String fromSessionId,
    required String toSessionId,
    required DropSide side,
  }) {
    final currentRoot = root;
    if (currentRoot == null || fromSessionId == toSessionId) {
      return this;
    }
    final moving = _findLeaf(currentRoot, fromSessionId);
    if (moving == null || !_containsSession(currentRoot, toSessionId)) {
      return this;
    }

    final removed = _removeSession(currentRoot, fromSessionId);
    if (removed == null || !_containsSession(removed, toSessionId)) {
      return this;
    }
    final inserted = _insertAdjacent(removed, toSessionId, moving, side);
    if (identical(inserted, removed)) {
      return this;
    }

    return copyWith(
      root: inserted,
      hasUserLayout: true,
      hasCustomStructure: true,
    );
  }

  MultiWindowLayout resizeSplit(
    List<int> splitPath,
    int dividerIndex,
    double deltaPx,
    double parentExtent, {
    double minWeight = 0.1,
  }) {
    if (parentExtent <= 0 || root == null) {
      return this;
    }
    final nextRoot = _resizeSplitNode(
      root!,
      splitPath,
      0,
      dividerIndex,
      deltaPx / parentExtent,
      minWeight,
    );
    if (identical(nextRoot, root)) {
      return this;
    }
    return copyWith(root: nextRoot);
  }
}

abstract class LayoutNode {
  const LayoutNode();

  List<String> get sessionIds;

  Map<String, dynamic> toJson();

  static LayoutNode? fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == 'leaf') {
      return LayoutLeaf.fromJson(json);
    }
    if (type == 'split') {
      return LayoutSplit.fromJson(json);
    }
    return null;
  }
}

class LayoutLeaf extends LayoutNode {
  const LayoutLeaf({required this.sessionId});

  final String sessionId;

  @override
  List<String> get sessionIds => <String>[sessionId];

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'leaf', 'sessionId': sessionId};
  }

  static LayoutLeaf? fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      return null;
    }
    return LayoutLeaf(sessionId: sessionId);
  }
}

class LayoutSplit extends LayoutNode {
  const LayoutSplit({
    required this.axis,
    required this.children,
    required this.weights,
  });

  final LayoutSplitAxis axis;
  final List<LayoutNode> children;
  final List<double> weights;

  LayoutSplit copyWith({
    LayoutSplitAxis? axis,
    List<LayoutNode>? children,
    List<double>? weights,
  }) {
    return LayoutSplit(
      axis: axis ?? this.axis,
      children: children ?? this.children,
      weights: weights ?? this.weights,
    );
  }

  @override
  List<String> get sessionIds {
    return [for (final child in children) ...child.sessionIds];
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'split',
      'axis': axis.name,
      'weights': weights,
      'children': children.map((child) => child.toJson()).toList(),
    };
  }

  static LayoutSplit? fromJson(Map<String, dynamic> json) {
    final axis = _axisFromJson(json['axis']);
    final childrenJson = json['children'];
    if (axis == null || childrenJson is! List) {
      return null;
    }
    final children = <LayoutNode>[];
    for (final entry in childrenJson) {
      if (entry is! Map) {
        return null;
      }
      final child = LayoutNode.fromJson(Map<String, dynamic>.from(entry));
      if (child != null) {
        children.add(child);
      }
    }
    final weights =
        json['weights'] is List
            ? (json['weights'] as List)
                .map(_doubleFromJson)
                .whereType<double>()
                .toList()
            : <double>[];
    return LayoutSplit(axis: axis, children: children, weights: weights);
  }
}

class LayoutRow {
  const LayoutRow({required this.weight, required this.cells});

  final double weight;
  final List<LayoutCell> cells;

  LayoutRow copyWith({double? weight, List<LayoutCell>? cells}) {
    return LayoutRow(weight: weight ?? this.weight, cells: cells ?? this.cells);
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

  static LayoutCell? fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      return null;
    }
    final weight = _doubleFromJson(json['weight']);
    return LayoutCell(sessionId: sessionId, weight: weight ?? 1);
  }
}

MultiWindowLayout? _fromLegacyRowsJson(Map<String, dynamic> json) {
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
    root: _rootFromRows(normalizeRows(rows)),
    hasUserLayout: json['hasUserLayout'] == true,
    hasCustomStructure: json['hasCustomStructure'] == true,
  );
}

LayoutNode? _rootFromRows(List<LayoutRow> rows) {
  if (rows.isEmpty) {
    return null;
  }
  final rowNodes = <LayoutNode>[];
  final rowWeights = <double>[];
  for (final row in rows) {
    final cells = normalizeCells(row.cells);
    if (cells.isEmpty) {
      continue;
    }
    final node =
        cells.length == 1
            ? LayoutLeaf(sessionId: cells.first.sessionId)
            : LayoutSplit(
              axis: LayoutSplitAxis.horizontal,
              children: [
                for (final cell in cells) LayoutLeaf(sessionId: cell.sessionId),
              ],
              weights: [for (final cell in cells) cell.weight],
            );
    rowNodes.add(node);
    rowWeights.add(row.weight);
  }
  if (rowNodes.isEmpty) {
    return null;
  }
  if (rowNodes.length == 1) {
    return normalizeNode(rowNodes.first);
  }
  return normalizeNode(
    LayoutSplit(
      axis: LayoutSplitAxis.vertical,
      children: rowNodes,
      weights: rowWeights,
    ),
  );
}

LayoutNode? normalizeNode(LayoutNode? node) {
  if (node == null) {
    return null;
  }
  if (node is LayoutLeaf) {
    return node.sessionId.isEmpty ? null : node;
  }
  if (node is LayoutSplit) {
    final children = <LayoutNode>[];
    final weights = <double>[];
    for (var i = 0; i < node.children.length; i++) {
      final child = normalizeNode(node.children[i]);
      if (child == null) {
        continue;
      }
      children.add(child);
      final weight = i < node.weights.length ? node.weights[i] : 1.0;
      weights.add(weight > 0 ? weight : 1.0);
    }
    if (children.isEmpty) {
      return null;
    }
    if (children.length == 1) {
      return children.first;
    }
    return LayoutSplit(
      axis: node.axis,
      children: children,
      weights: normalizeWeights(weights, children.length),
    );
  }
  return null;
}

List<LayoutRow> normalizeRows(List<LayoutRow> rows) {
  final nonEmpty = rows.where((row) => row.cells.isNotEmpty).toList();
  if (nonEmpty.isEmpty) {
    return const <LayoutRow>[];
  }
  final weights = normalizeWeights([
    for (final row in nonEmpty) row.weight,
  ], nonEmpty.length);
  return [
    for (var i = 0; i < nonEmpty.length; i++)
      nonEmpty[i].copyWith(
        weight: weights[i],
        cells: normalizeCells(nonEmpty[i].cells),
      ),
  ];
}

List<LayoutCell> normalizeCells(List<LayoutCell> cells) {
  if (cells.isEmpty) {
    return const <LayoutCell>[];
  }
  final weights = normalizeWeights([
    for (final cell in cells) cell.weight,
  ], cells.length);
  return [
    for (var i = 0; i < cells.length; i++)
      cells[i].copyWith(weight: weights[i]),
  ];
}

List<double> normalizeWeights(List<double> weights, int length) {
  if (length <= 0) {
    return const <double>[];
  }
  final safe = <double>[
    for (var i = 0; i < length; i++)
      i < weights.length && weights[i] > 0 ? weights[i] : 1,
  ];
  final total = safe.fold<double>(0, (sum, weight) => sum + weight);
  if (total <= 0) {
    return List<double>.filled(length, 1 / length);
  }
  return [for (final weight in safe) weight / total];
}

LayoutNode? _pruneSessions(
  LayoutNode node,
  Set<String> wanted,
  Set<String> present,
) {
  if (node is LayoutLeaf) {
    if (wanted.contains(node.sessionId) && present.add(node.sessionId)) {
      return node;
    }
    return null;
  }
  if (node is LayoutSplit) {
    final children = <LayoutNode>[];
    final weights = <double>[];
    for (var i = 0; i < node.children.length; i++) {
      final child = _pruneSessions(node.children[i], wanted, present);
      if (child != null) {
        children.add(child);
        weights.add(i < node.weights.length ? node.weights[i] : 1);
      }
    }
    return normalizeNode(
      LayoutSplit(axis: node.axis, children: children, weights: weights),
    );
  }
  return null;
}

LayoutNode _appendSession(LayoutNode? root, String sessionId, int maxCells) {
  final leaf = LayoutLeaf(sessionId: sessionId);
  if (root == null) {
    return leaf;
  }
  final appended = _appendToHorizontalCapacity(root, leaf, maxCells);
  if (appended != null) {
    return appended;
  }
  if (root is LayoutSplit && root.axis == LayoutSplitAxis.vertical) {
    return normalizeNode(
      root.copyWith(
        children: [...root.children, leaf],
        weights: [...root.weights, 1],
      ),
    )!;
  }
  return normalizeNode(
    LayoutSplit(
      axis: LayoutSplitAxis.vertical,
      children: [root, leaf],
      weights: const [1, 1],
    ),
  )!;
}

LayoutNode? _appendToHorizontalCapacity(
  LayoutNode node,
  LayoutLeaf leaf,
  int maxCells,
) {
  if (maxCells <= 1) {
    return null;
  }
  if (node is LayoutLeaf) {
    return normalizeNode(
      LayoutSplit(
        axis: LayoutSplitAxis.horizontal,
        children: [node, leaf],
        weights: const [1, 1],
      ),
    );
  }
  if (node is LayoutSplit &&
      node.axis == LayoutSplitAxis.horizontal &&
      node.children.length < maxCells) {
    return normalizeNode(
      node.copyWith(
        children: [...node.children, leaf],
        weights: [...node.weights, 1],
      ),
    );
  }
  if (node is LayoutSplit && node.axis == LayoutSplitAxis.vertical) {
    final children = [...node.children];
    if (children.isEmpty) {
      return leaf;
    }
    final last = _appendToHorizontalCapacity(children.last, leaf, maxCells);
    if (last == null) {
      return null;
    }
    children[children.length - 1] = last;
    return normalizeNode(node.copyWith(children: children));
  }
  return null;
}

LayoutLeaf? _findLeaf(LayoutNode node, String sessionId) {
  if (node is LayoutLeaf) {
    return node.sessionId == sessionId ? node : null;
  }
  if (node is LayoutSplit) {
    for (final child in node.children) {
      final found = _findLeaf(child, sessionId);
      if (found != null) {
        return found;
      }
    }
  }
  return null;
}

bool _containsSession(LayoutNode node, String sessionId) {
  return node.sessionIds.contains(sessionId);
}

LayoutNode? _removeSession(LayoutNode node, String sessionId) {
  if (node is LayoutLeaf) {
    return node.sessionId == sessionId ? null : node;
  }
  if (node is LayoutSplit) {
    final children = <LayoutNode>[];
    final weights = <double>[];
    for (var i = 0; i < node.children.length; i++) {
      final child = _removeSession(node.children[i], sessionId);
      if (child != null) {
        children.add(child);
        weights.add(i < node.weights.length ? node.weights[i] : 1);
      }
    }
    return normalizeNode(
      LayoutSplit(axis: node.axis, children: children, weights: weights),
    );
  }
  return node;
}

LayoutNode _insertAdjacent(
  LayoutNode node,
  String targetId,
  LayoutLeaf moving,
  DropSide side,
) {
  final axis = _axisForSide(side);
  final insertBefore = side == DropSide.left || side == DropSide.top;
  if (node is LayoutLeaf) {
    if (node.sessionId != targetId) {
      return node;
    }
    return normalizeNode(
      LayoutSplit(
        axis: axis,
        children: insertBefore ? [moving, node] : [node, moving],
        weights: const [1, 1],
      ),
    )!;
  }
  if (node is LayoutSplit) {
    final children = [...node.children];
    final weights = [...node.weights];
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is LayoutLeaf && child.sessionId == targetId) {
        if (node.axis == axis) {
          final insertAt = insertBefore ? i : i + 1;
          children.insert(insertAt, moving);
          weights.insert(insertAt, i < weights.length ? weights[i] : 1);
        } else {
          children[i] =
              normalizeNode(
                LayoutSplit(
                  axis: axis,
                  children: insertBefore ? [moving, child] : [child, moving],
                  weights: const [1, 1],
                ),
              )!;
        }
        return normalizeNode(
          node.copyWith(children: children, weights: weights),
        )!;
      }
      if (_containsSession(child, targetId)) {
        final updated = _insertAdjacent(child, targetId, moving, side);
        if (!identical(updated, child)) {
          children[i] = updated;
          return normalizeNode(
            node.copyWith(children: children, weights: weights),
          )!;
        }
      }
    }
  }
  return node;
}

LayoutNode _resizeSplitNode(
  LayoutNode node,
  List<int> splitPath,
  int depth,
  int dividerIndex,
  double deltaWeight,
  double minWeight,
) {
  if (depth == splitPath.length) {
    if (node is! LayoutSplit ||
        dividerIndex < 0 ||
        dividerIndex + 1 >= node.children.length) {
      return node;
    }
    final weights = normalizeWeights(node.weights, node.children.length);
    final first = weights[dividerIndex];
    final second = weights[dividerIndex + 1];
    final pairTotal = first + second;
    final minPairWeight = pairTotal * minWeight;
    final nextFirst = (first + deltaWeight).clamp(
      minPairWeight,
      pairTotal - minPairWeight,
    );
    weights[dividerIndex] = nextFirst;
    weights[dividerIndex + 1] = pairTotal - nextFirst;
    return normalizeNode(node.copyWith(weights: weights))!;
  }
  if (node is! LayoutSplit) {
    return node;
  }
  final childIndex = splitPath[depth];
  if (childIndex < 0 || childIndex >= node.children.length) {
    return node;
  }
  final children = [...node.children];
  final updated = _resizeSplitNode(
    children[childIndex],
    splitPath,
    depth + 1,
    dividerIndex,
    deltaWeight,
    minWeight,
  );
  if (identical(updated, children[childIndex])) {
    return node;
  }
  children[childIndex] = updated;
  return normalizeNode(node.copyWith(children: children))!;
}

LayoutSplitAxis? _axisFromJson(Object? raw) {
  if (raw == 'horizontal') {
    return LayoutSplitAxis.horizontal;
  }
  if (raw == 'vertical') {
    return LayoutSplitAxis.vertical;
  }
  return null;
}

LayoutSplitAxis _axisForSide(DropSide side) {
  return switch (side) {
    DropSide.left || DropSide.right => LayoutSplitAxis.horizontal,
    DropSide.top || DropSide.bottom => LayoutSplitAxis.vertical,
  };
}

int _maxHorizontalLeafCount(LayoutNode? node) {
  if (node == null) {
    return 0;
  }
  if (node is LayoutLeaf) {
    return 1;
  }
  if (node is LayoutSplit) {
    final own =
        node.axis == LayoutSplitAxis.horizontal ? node.children.length : 0;
    return node.children.fold<int>(own, (max, child) {
      final childMax = _maxHorizontalLeafCount(child);
      return childMax > max ? childMax : max;
    });
  }
  return 0;
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
