import 'dart:async';

import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:claude_launcher/src/ui/profile_usage_menu.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'меню: использование, обновление, закрытый профиль · $brightness',
      (tester) async {
        final running = ValueNotifier(true);
        addTearDown(running.dispose);
        var calls = 0;
        Future<ProfileUsage?> load() async {
          calls++;
          return ProfileUsage(
            updatedAt: DateTime(2026, 9, 1),
            limits: [
              UsageLimit(
                label: 'За 5 часов',
                usedPercent: calls == 1 ? 20 : 30,
              ),
            ],
          );
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(brightness),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: ProfileUsageButton(
                  load: load,
                  activity: running,
                  isRunning: () => running.value,
                ),
              ),
            ),
          ),
        );
        expect(calls, 0);
        await tester.tap(find.byTooltip('Лимиты профиля'));
        await tester.pumpAndSettle();
        expect(find.text('Использовано 20%'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
        expect(find.textContaining('Данные устарели.'), findsNothing);
        expect(calls, 1);
        expect(find.textContaining('Данные получены ·'), findsNothing);
        expect(find.text('Рабочий'), findsNothing);
        expect(find.text('Данные Claude'), findsNothing);
        expect(
          tester.widget<Text>(find.text('Остаток лимитов')).style?.fontSize,
          20,
        );
        await tester.tap(find.text('Проверить снова'));
        await tester.pumpAndSettle();
        expect(find.text('Остаток лимитов'), findsNothing);
        expect(calls, 2);
        await tester.tap(find.byTooltip('Лимиты профиля'));
        await tester.pumpAndSettle();
        expect(find.text('Использовано 30%'), findsOneWidget);
        running.value = false;
        await tester.pump();
        expect(find.textContaining('Профиль закрыт.'), findsOneWidget);
        expect(find.text('Использовано 30%'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.text('Остаток лимитов'), findsNothing);
      },
    );
  }

  testWidgets('ошибка и отсутствие данных не показывают вымышленные проценты', (
    tester,
  ) async {
    final activity = ValueNotifier(true);
    addTearDown(activity.dispose);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ProfileUsageMenu(
            activity: activity,
            isRunning: () => true,
            load: () async {
              if (calls++ == 0) throw const FormatException();
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось прочитать лимиты.'), findsOneWidget);
    await tester.tap(find.text('Проверить снова'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Claude ещё не сохранил лимиты'),
      findsOneWidget,
    );
    expect(find.textContaining('Использовано'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('использование и сброс в одной строке, тонкая полоса', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final activity = ValueNotifier(true);
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ProfileUsageButton(
            activity: activity,
            isRunning: () => true,
            load: () async => ProfileUsage(
              updatedAt: DateTime.now(),
              limits: const [
                UsageLimit(
                  label: 'За 5 часов',
                  usedPercent: 1,
                  resetDescription: 'Resets in 2 hr 1 min',
                ),
                UsageLimit(
                  label: 'За неделю · все модели',
                  usedPercent: 67,
                  resetDescription: 'Resets Sun 9:00 PM',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Лимиты профиля'));
    await tester.pumpAndSettle();
    final label = tester.getRect(find.text('За неделю · все модели'));
    final reset = tester.getRect(find.text('Сброс вс, 21:00'));
    final used = tester.getRect(find.text('Использовано 67%'));
    expect(reset.right, lessThan(used.left));
    expect(label.center.dy, closeTo(used.center.dy, 1));
    expect(reset.center.dy, closeTo(used.center.dy, 1));
    expect(find.text('Сброс через 2 ч 1 мин'), findsOneWidget);
    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars.map((bar) => bar.value), [0.01, 0.67]);
    expect(bars.every((bar) => bar.minHeight == 4), isTrue);
    expect(tester.takeException(), isNull);
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
    // 8 px между карточкой и меню, 14 px верхнего отступа заголовка.
    expect(
      tester.getTopLeft(find.text('Остаток лимитов')).dy,
      card.bottom + 22,
    );
    await tester.tapAt(card.center);
    await tester.pumpAndSettle();
    expect(find.text('Остаток лимитов'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'закрытие меню во время чтения и длинный список без переполнения',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      final pending = Completer<ProfileUsage?>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: ProfileUsageButton(
              activity: activity,
              isRunning: () => true,
              load: () => pending.future,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Лимиты профиля'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(460, 460));
      await tester.pump(const Duration(milliseconds: 300));
      pending.complete(
        ProfileUsage(
          updatedAt: DateTime.now(),
          limits: List.generate(
            9,
            (i) => UsageLimit(label: 'Лимит $i', usedPercent: 50),
          ),
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
    },
  );
}
