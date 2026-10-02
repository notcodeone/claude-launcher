import 'package:claude_launcher/src/ui/snackbar.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:claude_launcher/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(24), child: child),
  ),
);

void main() {
  tearDown(AppSnackbar.reset);

  testWidgets('оповещения по очереди; уходят сами; кнопка срабатывает', (
    tester,
  ) async {
    var updated = 0;
    await tester.pumpWidget(
      _app(
        const Align(alignment: Alignment.bottomCenter, child: SnackbarHost()),
      ),
    );
    AppSnackbar.show(
      Snack(
        id: 'a',
        text: 'Вышел ClaudeLauncher 9.0.0',
        action: 'Обновить',
        onAction: () => updated++,
      ),
    );
    AppSnackbar.show(const Snack(id: 'b', text: 'Профиль «Клиент» создан'));
    await tester.pumpAndSettle();
    expect(find.text('Вышел ClaudeLauncher 9.0.0'), findsOneWidget);
    expect(find.text('Профиль «Клиент» создан'), findsNothing);

    await tester.tap(find.text('Обновить'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(updated, 1);
    expect(find.text('Профиль «Клиент» создан'), findsOneWidget);

    // Ушло само через 6 секунд.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Профиль «Клиент» создан'), findsNothing);
  });

  testWidgets('то же оповещение заменяет прежнее, а не встаёт в очередь', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SnackbarHost()));
    AppSnackbar.show(const Snack(id: 'c', text: 'Скачиваю…', duration: null));
    AppSnackbar.show(const Snack(id: 'c', text: 'Claude обновлён'));
    await tester.pumpAndSettle();
    expect(find.text('Скачиваю…'), findsNothing);
    expect(find.text('Claude обновлён'), findsOneWidget);
    AppSnackbar.reset();
  });

  testWidgets('важное — компактной строкой, подробности по нажатию', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 400,
          child: NoticeRow(
            icon: AppIcons.shieldAlert,
            title: 'Kill Switch закрыл Claude',
            detail:
                'Страна сменилась: Германия → Россия. Проверьте VPN, прежде '
                'чем снова открывать Claude.',
            onClose: () => closed++,
          ),
        ),
      ),
    );
    final detail = find.textContaining('Страна сменилась');
    final collapsed = tester.getSize(detail).height;
    await tester.tap(find.text('Kill Switch закрыл Claude'));
    await tester.pumpAndSettle();
    expect(tester.getSize(detail).height, greaterThan(collapsed));
    await tester.tap(find.byTooltip('Закрыть'));
    expect(closed, 1);
  });
}
