import 'package:claude_launcher/src/ui/theme.dart';
import 'package:claude_launcher/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('длинная подпись переносится, а не вылезает за край', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusDot(
                    label: 'Защита снимется, когда закроете Claude, — и ещё',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final text = tester.getSize(find.byType(Text));
    expect(text.width, lessThanOrEqualTo(200));
    expect(text.height, greaterThan(20)); // Две строки.
  });
}
