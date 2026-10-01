import 'package:claude_launcher/src/ui/home_page.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(ValueNotifier<HeaderStatus?> status) => MaterialApp(
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
  );

  testWidgets('статус в шапке сменяет название и возвращается', (tester) async {
    final status = ValueNotifier<HeaderStatus?>(null);
    addTearDown(status.dispose);
    await tester.pumpWidget(app(status));
    expect(find.text('ClaudeLauncher'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    status.value = const HeaderStatus('country', 'Проверяю страну…');
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

  testWidgets('скачивание: свой значок, проценты меняются на месте', (
    tester,
  ) async {
    final status = ValueNotifier<HeaderStatus?>(
      const HeaderStatus(
        'update-download',
        'Скачиваю 1.3.2… 10%',
        downloading: true,
      ),
    );
    addTearDown(status.dispose);
    await tester.pumpWidget(app(status));
    expect(find.byType(DownloadingIcon), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    status.value = const HeaderStatus(
      'update-download',
      'Скачиваю 1.3.2… 45%',
      downloading: true,
    );
    await tester.pump();
    // Тот же вид занятия — без анимации смены: прежней надписи уже нет.
    expect(find.text('Скачиваю 1.3.2… 10%'), findsNothing);
    expect(find.text('Скачиваю 1.3.2… 45%'), findsOneWidget);

    status.value = const HeaderStatus('update-install', 'Устанавливаю 1.3.2…');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DownloadingIcon), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
