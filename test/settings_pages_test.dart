import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:claude_launcher/src/integrations/claude_code_integration.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/location_guard.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:claude_launcher/src/ui/home_page.dart';
import 'package:claude_launcher/src/ui/settings_pages.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:claude_launcher/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

/// Несколько кадров подряд: pumpAndSettle не дождётся, пока на профилях
/// крутится «Загружаю профили…».
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('настройки — страницы внутри окна: туда и обратно', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(580, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('settings_pages'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    final settings = AppSettings(File('${dir!.path}/settings.json'));
    await tester.runAsync(settings.load);
    final launcher = LauncherController(
      host: FakeHost(),
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    final claudeCode = ClaudeCodeIntegration(
      settings: settings,
      launcher: launcher,
      hooks: ClaudeCodeHooks(File('${dir.path}/.claude/settings.json')),
    );
    final location = LocationGuard(
      settings: settings,
      lookup: () async => (country: 'DE', source: 'тест'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HomePage(
          launcher: launcher,
          settings: settings,
          claudeCode: claudeCode,
          location: location,
          version: '1.4.0',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Профили'), findsOneWidget);
    expect(find.text('Добавить'), findsOneWidget);

    await tester.tap(find.byTooltip('Настройки'));
    await settle(tester);
    expect(AppPages.current.value, AppPages.settings);
    expect(find.text('Профили'), findsNothing);
    for (final section in SettingsSection.values) {
      expect(find.text(section.title), findsOneWidget);
    }
    // Шапка — «← Настройки», кнопки страны и настроек ушли.
    expect(find.byTooltip('Назад'), findsOneWidget);
    expect(find.byTooltip('Страна'), findsNothing);

    // Перед «Экспериментами» — предупреждение: мимо не закрыть, «Назад»
    // оставляет в списке, согласие запоминается.
    await tester.tap(find.text('Эксперименты'));
    await tester.pumpAndSettle();
    expect(find.text('Понимаю, продолжить'), findsOneWidget);
    expect(
      find.text(
        'ClaudeLauncher не собирает и не отправляет ваши личные данные.',
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Понимаю, продолжить'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Назад'));
    await tester.pumpAndSettle();
    expect(AppPages.current.value, AppPages.settings);
    expect(settings.experimentsAccepted, isFalse);

    await tester.tap(find.text('Эксперименты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Понимаю, продолжить'));
    await tester.pumpAndSettle();
    expect(settings.experimentsAccepted, isTrue);
    expect(find.text('Лимиты профиля'), findsOneWidget);
    expect(settings.usageLimits, isFalse);
    expect(find.text('Kill Switch'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(settings.usageLimits, isTrue);

    // Esc — на шаг назад, затем к профилям.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(AppPages.current.value, AppPages.settings);
    expect(find.text('Опасная зона!'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await settle(tester);
    expect(AppPages.current.value, AppPages.home);
    expect(find.text('Профили'), findsOneWidget);
    expect(find.byTooltip('Страна'), findsOneWidget);

    await tester.tap(find.byTooltip('Настройки'));
    await settle(tester);
    await tester.tap(find.text('Основные'));
    await tester.pumpAndSettle();
    expect(find.text('Тема окна'), findsOneWidget);
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    claudeCode.dispose();
    location.dispose();
  });
}
