import 'package:claude_launcher/src/ui/parallel_report_dialog.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('report is generated once and copied only on explicit click', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    var captures = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showParallelReport(context, () async {
              captures++;
              return '{"schema":1}';
            }),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(copied, isNull);
    expect(find.text('{"schema":1}'), findsOneWidget);
    await tester.tap(find.text('Копировать отчёт'));
    await tester.pumpAndSettle();
    expect(copied, '{"schema":1}');
    expect(captures, 1);
    expect(find.text('Скопировано'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
