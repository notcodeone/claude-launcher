import 'package:claude_launcher/src/ui/home_page.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('статус в шапке сменяет название и возвращается', (tester) async {
    final status = ValueNotifier<String?>(null);
    addTearDown(status.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: ValueListenableBuilder(
              valueListenable: status,
              builder: (_, value, _) => HeaderTitle(status: value),
            ),
          ),
        ),
      ),
    );
    expect(find.text('ClaudeLauncher'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    status.value = 'Проверяю страну…';
    await tester.pump(const Duration(milliseconds: 100));
    // Посреди смены видны обе надписи.
    expect(find.text('ClaudeLauncher'), findsOneWidget);
    expect(find.text('Проверяю страну…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ClaudeLauncher'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    status.value = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Проверяю страну…'), findsNothing);
    expect(find.text('ClaudeLauncher'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
