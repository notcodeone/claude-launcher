import 'dart:io';

import 'package:claude_launcher/src/ui/announcements.dart';
import 'package:claude_launcher/src/ui/snackbar.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:claude_launcher/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
        Align(alignment: Alignment.bottomCenter, child: const SnackbarHost()),
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

  testWidgets('пока видно оповещение, кнопка страницы скрыта', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      _app(
        Stack(
          children: [
            Positioned(
              right: 0,
              bottom: 0,
              child: FabSlot(
                child: AppFab(
                  icon: AppIcons.add,
                  label: 'Добавить',
                  onPressed: () => pressed++,
                ),
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SnackbarHost(),
            ),
          ],
        ),
      ),
    );
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byType(AppFab),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacity(), 1);

    AppSnackbar.show(
      const Snack(id: 'x', text: 'Вышел Claude', duration: null),
    );
    await tester.pumpAndSettle();
    expect(opacity(), 0);
    // Скрытая кнопка не нажимается.
    await tester.tap(find.byType(AppFab), warnIfMissed: false);
    expect(pressed, 0);

    AppSnackbar.dismiss();
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    AppSnackbar.reset();
  });

  // Шрифт системы — тексты меряются так же, как в окне (в тестах по умолчанию
  // шрифт-заглушка с квадратными буквами, он шире). Где его нет — пропускаем.
  final sf = File('/System/Library/Fonts/SFNS.ttf');
  testWidgets('каждое оповещение — в одну строку окна', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.view(sf.readAsBytesSync().buffer))))
          .load();
    });
    void none() {}
    final snacks = [
      Snacks.trayHint(onDismiss: none),
      // Обе подсказки: на macOS и на Windows текст свой.
      const Snack(
        id: 'w',
        text: 'ClaudeLauncher живёт в трее',
        action: 'Понятно',
      ),
      Snacks.launcherUpdate('1.10.10', none),
      Snacks.launcherFailed(none),
      Snacks.claudeUpdate('2.19675.0', none),
      Snacks.claudeUpdated('2.19675.0'),
      Snacks.claudeFailed(none),
      Snacks.profileCreated('Рабочий', none),
      Snacks.profileSaved('Рабочий'),
    ];
    // Окно 560 с полями по 24 — кнопка страницы скрыта, вся ширина.
    const width = 560.0 - 2 * 24;
    for (final snack in snacks) {
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SnackView(snack: snack),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(snack.text),
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '«${snack.text}» не влезает в строку',
      );
    }
  }, skip: !sf.existsSync());
}
