import 'dart:async';

import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:claude_launcher/src/ui/profile_usage_menu.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 1, 12);

  Widget app({
    required Future<ProfileUsage?> Function() load,
    required ValueNotifier<bool> running,
    Brightness brightness = Brightness.light,
  }) => MaterialApp(
    theme: buildTheme(brightness),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: ProfileUsageButton(
          load: load,
          activity: running,
          isRunning: () => running.value,
        ),
      ),
    ),
  );

  group('текст сброса', () {
    UsageLimit session({
      DateTime? resetsAt,
      double used = 10,
      bool approximate = false,
    }) => UsageLimit(
      label: 'За 5 часов',
      usedPercent: used,
      window: UsageWindow.session,
      resetsAt: resetsAt,
      resetApproximate: approximate,
    );

    test('через часы и минуты, округление до минуты', () {
      expect(
        resetText(
          session(
            resetsAt: now.add(
              const Duration(hours: 2, minutes: 9, seconds: 59),
            ),
          ),
          now,
        ),
        'Сброс через 2 ч 10 мин',
      );
      expect(
        resetText(session(resetsAt: now.add(const Duration(minutes: 45))), now),
        'Сброс через 45 мин',
      );
      expect(
        resetText(session(resetsAt: now.add(const Duration(hours: 3))), now),
        'Сброс через 3 ч',
      );
      expect(
        resetText(
          session(
            resetsAt: now.add(const Duration(hours: 1)),
            approximate: true,
          ),
          now,
        ),
        'Сброс примерно через 1 ч',
      );
    });

    test('дальше суток — день недели и время; окно не идёт; неизвестно', () {
      // 4 октября 2026 — воскресенье.
      expect(
        resetText(session(resetsAt: DateTime(2026, 10, 4, 20, 59, 59)), now),
        'Сброс в вс, 21:00',
      );
      expect(resetText(session(used: 0), now), 'Начнётся с первого запроса');
      expect(
        resetText(
          UsageLimit(
            label: 'За 5 часов',
            usedPercent: 0,
            window: UsageWindow.session,
            wasResetAt: DateTime(2026, 10, 1, 15, 9, 59, 980),
          ),
          now,
        ),
        'Сброшен в 15:10',
      );
      expect(resetText(session(), now), isNull);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('меню: лимиты, перечитывание без закрытия · $brightness', (
      tester,
    ) async {
      final running = ValueNotifier(true);
      addTearDown(running.dispose);
      var calls = 0;
      Future<ProfileUsage?> load() async {
        calls++;
        return ProfileUsage(
          limits: [
            UsageLimit(
              label: 'За 5 часов',
              usedPercent: calls == 1 ? 20 : 30,
              window: UsageWindow.session,
              resetsAt: DateTime.now().add(
                const Duration(hours: 2, minutes: 1),
              ),
            ),
            const UsageLimit(
              label: 'За неделю · все модели',
              usedPercent: 67,
              window: UsageWindow.weekly,
            ),
          ],
        );
      }

      await tester.pumpWidget(
        app(load: load, running: running, brightness: brightness),
      );
      expect(calls, 0);
      await tester.tap(find.byTooltip('Лимиты профиля'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.widget<Text>(find.text('Лимиты')).style?.fontSize, 20);
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('67%'), findsOneWidget);
      expect(find.textContaining('Сброс через 2 ч'), findsOneWidget);
      // Неизвестный сброс не заменяется прочерком.
      expect(find.text('—'), findsNothing);

      await tester.tap(find.text('Проверить снова'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Лимиты'), findsOneWidget);
      expect(find.text('30%'), findsOneWidget);

      running.value = false;
      await tester.pump();
      expect(find.textContaining('Профиль закрыт.'), findsOneWidget);
      expect(find.text('30%'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(10, 300));
      await tester.pumpAndSettle();
      expect(find.text('Лимиты'), findsNothing);
    });
  }

  testWidgets('ошибка и отсутствие данных не показывают вымышленные проценты', (
    tester,
  ) async {
    final running = ValueNotifier(true);
    addTearDown(running.dispose);
    var fail = true;
    await tester.pumpWidget(
      app(
        running: running,
        load: () async => fail ? throw const FormatException() : null,
      ),
    );
    await tester.tap(find.byTooltip('Лимиты профиля'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось прочитать лимиты Claude.'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    fail = false;
    await tester.tap(find.text('Проверить снова'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claude ещё не сохранил'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('меню привязано к карточке и закрывается нажатием на неё', (
    tester,
  ) async {
    final activity = ValueNotifier(true);
    addTearDown(activity.dispose);
    const cardKey = ValueKey('card');
    const highlightKey = ValueKey('highlight');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Builder(
                builder: (cardContext) => SizedBox(
                  key: cardKey,
                  width: 430,
                  height: 100,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ProfileUsageButton(
                      menuAnchorContext: cardContext,
                      menuHighlight: const SizedBox(
                        key: highlightKey,
                        width: 430,
                        height: 100,
                      ),
                      activity: activity,
                      isRunning: () => true,
                      load: () async => null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final card = tester.getRect(find.byKey(cardKey));
    await tester.tap(find.byTooltip('Лимиты профиля'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(highlightKey)), card);
    // Меню — под карточкой, по её правому краю, шириной как меню страны.
    final menu = tester.getRect(find.byType(ProfileUsageMenu));
    expect(menu.top, card.bottom + 8);
    expect(menu.right, card.right);
    expect(menu.width, ProfileUsageMenu.width);
    await tester.tapAt(card.center);
    await tester.pumpAndSettle();
    expect(find.text('Лимиты'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('закрытие во время чтения и длинный список без переполнения', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final running = ValueNotifier(true);
    addTearDown(running.dispose);
    final pending = Completer<ProfileUsage?>();
    await tester.pumpWidget(app(running: running, load: () => pending.future));
    await tester.tap(find.byTooltip('Лимиты профиля'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(10, 460));
    await tester.pump(const Duration(milliseconds: 300));
    pending.complete(
      ProfileUsage(
        limits: [
          for (var i = 0; i < 9; i++)
            UsageLimit(
              label: 'Лимит $i',
              usedPercent: 50,
              window: UsageWindow.weekly,
              resetsAt: DateTime.now().add(const Duration(days: 3)),
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Лимиты профиля'));
    await tester.pumpAndSettle();
    expect(find.text('Лимит 0'), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(find.text('Лимит 8'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
