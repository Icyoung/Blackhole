import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:voyager_share/src/widgets/session_window_card.dart';

void main() {
  testWidgets('multi-window terminal card forwards Space to terminal', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    final viewKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 320,
            child: SessionWindowCard(
              sessionId: 'session',
              terminal: terminal,
              controller: TerminalController(),
              scrollController: ScrollController(),
              viewKey: viewKey,
              label: 'session',
              isActive: true,
              showHHKB: false,
              deleteDetection: false,
              hardwareKeyboardOnly: true,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    viewKey.currentState!.requestKeyboard();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(output, [' ']);
  });
}
