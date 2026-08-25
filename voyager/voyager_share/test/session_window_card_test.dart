import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager_share/src/widgets/session_window_card.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('space reaches the terminal in a multi-window card', (
    tester,
  ) async {
    final received = <String>[];
    final terminal = Terminal();
    terminal.onOutput = received.add;
    final controller = TerminalController();
    final scrollController = ScrollController();
    final viewKey = GlobalKey<TerminalViewState>();
    addTearDown(controller.dispose);
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 320,
            child: SessionWindowCard(
              sessionId: 'S1',
              terminal: terminal,
              controller: controller,
              scrollController: scrollController,
              viewKey: viewKey,
              label: 'pane',
              isActive: true,
              showHHKB: false,
              hardwareKeyboardOnly: true,
              terminalStyle: const TerminalStyle(fontSize: 8),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(TerminalView));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(received.join(), contains(' '));
  });
}
