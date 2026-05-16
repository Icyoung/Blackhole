import 'package:flutter_test/flutter_test.dart';
import 'package:voyager_share/voyager_share.dart';

void main() {
  test('fallback creates normalized rows and cells', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b', 'c', 'd', 'e'],
      columns: 2,
    );

    expect(layout.schemaVersion, MultiWindowLayout.currentSchemaVersion);
    expect(layout.hasUserLayout, isFalse);
    expect(layout.rows, hasLength(3));
    expect(layout.rows[0].cells.map((cell) => cell.sessionId), ['a', 'b']);
    expect(layout.rows[1].cells.map((cell) => cell.sessionId), ['c', 'd']);
    expect(layout.rows[2].cells.map((cell) => cell.sessionId), ['e']);
    expect(
      layout.rows.fold<double>(0, (sum, row) => sum + row.weight),
      closeTo(1, 0.0001),
    );
    expect(
      layout.rows.first.cells.fold<double>(0, (sum, cell) => sum + cell.weight),
      closeTo(1, 0.0001),
    );
  });

  test('non-user layout follows sidebar order', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b', 'c'],
      columns: 2,
    ).syncSessions(
      sessionIds: const ['c', 'a', 'b'],
      defaultColumns: 2,
      maxCellsPerRow: 2,
    );

    expect(layout.hasUserLayout, isFalse);
    expect(layout.sessionIds, ['c', 'a', 'b']);
  });

  test('user layout preserves pane order and appends by maxCellsPerRow', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b', 'c'],
      columns: 2,
      hasUserLayout: true,
    ).syncSessions(
      sessionIds: const ['c', 'a', 'b', 'd', 'e'],
      defaultColumns: 4,
      maxCellsPerRow: 2,
    );

    expect(layout.hasUserLayout, isTrue);
    // First non-full row gets filled before opening a new row.
    // Initial layout was rows [a,b][c]; appending d fills row 2 to [c,d];
    // appending e starts a new row [e].
    expect(layout.sessionIds, ['a', 'b', 'c', 'd', 'e']);
    expect(layout.rows.map((row) => row.cells.length), [2, 2, 1]);
  });

  test('new sessions fill earliest non-full row before opening a new one', () {
    // Start with rows [a][b,c] (2-col limit, second row full)
    final base = MultiWindowLayout(
      hasUserLayout: true,
      rows: [
        LayoutRow(weight: 0.5, cells: const [LayoutCell(sessionId: 'a', weight: 1)]),
        LayoutRow(
          weight: 0.5,
          cells: const [
            LayoutCell(sessionId: 'b', weight: 0.5),
            LayoutCell(sessionId: 'c', weight: 0.5),
          ],
        ),
      ],
    );
    final layout = base.syncSessions(
      sessionIds: const ['a', 'b', 'c', 'd'],
      defaultColumns: 2,
      maxCellsPerRow: 2,
    );

    // d should join row 0 (the first non-full row), not start a new row 2.
    expect(layout.rows.map((row) => row.cells.length), [2, 2]);
    expect(layout.rows[0].cells.map((cell) => cell.sessionId), ['a', 'd']);
    expect(layout.rows[1].cells.map((cell) => cell.sessionId), ['b', 'c']);
  });

  test('deleted sessions are removed and empty rows collapse', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b', 'c', 'd'],
      columns: 2,
      hasUserLayout: true,
    ).syncSessions(
      sessionIds: const ['a', 'd'],
      defaultColumns: 2,
      maxCellsPerRow: 2,
    );

    expect(layout.sessionIds, ['a', 'd']);
    expect(layout.rows, hasLength(2));
  });

  test('schema mismatch is treated as corrupted layout', () {
    final layout = MultiWindowLayout.fromJson(<String, dynamic>{
      'schemaVersion': 99,
      'rows': const <Object>[],
    });

    expect(layout, isNull);
  });

  test('resize column keeps normalized weights and minimum size', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b'],
      columns: 2,
      hasUserLayout: true,
    ).resizeColumn(0, 0, 900, 1000);

    final cells = layout.rows.single.cells;
    expect(cells[0].weight, closeTo(0.9, 0.0001));
    expect(cells[1].weight, closeTo(0.1, 0.0001));
    expect(
      cells.fold<double>(0, (sum, cell) => sum + cell.weight),
      closeTo(1, 0.0001),
    );
  });

  test('moveCell inserts on right side of target', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b', 'c'],
      columns: 3,
      hasUserLayout: true,
    ).moveCell(
      fromSessionId: 'a',
      toSessionId: 'c',
      side: DropSide.right,
    );

    expect(layout.rows.single.cells.map((c) => c.sessionId), ['b', 'c', 'a']);
    expect(layout.hasUserLayout, isTrue);
  });

  test('moveCell to top splits into a new row above target', () {
    final layout = MultiWindowLayout.fallback(
      sessionIds: const ['a', 'b'],
      columns: 2,
      hasUserLayout: true,
    ).moveCell(
      fromSessionId: 'a',
      toSessionId: 'b',
      side: DropSide.top,
    );

    expect(layout.rows, hasLength(2));
    expect(layout.rows[0].cells.map((c) => c.sessionId), ['a']);
    expect(layout.rows[1].cells.map((c) => c.sessionId), ['b']);
  });

  test('moveCell collapses empty source row', () {
    // [a][b,c]; move a below c -> b,c remain; a goes into a new row below.
    final base = MultiWindowLayout(
      hasUserLayout: true,
      rows: [
        LayoutRow(weight: 0.5, cells: const [LayoutCell(sessionId: 'a', weight: 1)]),
        LayoutRow(
          weight: 0.5,
          cells: const [
            LayoutCell(sessionId: 'b', weight: 0.5),
            LayoutCell(sessionId: 'c', weight: 0.5),
          ],
        ),
      ],
    );
    final layout = base.moveCell(
      fromSessionId: 'a',
      toSessionId: 'c',
      side: DropSide.bottom,
    );

    expect(layout.rows, hasLength(2));
    expect(layout.rows[0].cells.map((c) => c.sessionId), ['b', 'c']);
    expect(layout.rows[1].cells.map((c) => c.sessionId), ['a']);
  });
}
