import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:claude_launcher/src/integrations/claude_code_integration.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/location_guard.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:claude_launcher/src/ui/home_page.dart';
import 'package:claude_launcher/src/ui/profile_page.dart';
import 'package:claude_launcher/src/ui/snackbar.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;
import 'settings_pages_test.dart' show settle;

void main() {
  testWidgets('страница профиля: создание и правка', (tester) async {
    await tester.binding.setSurfaceSize(const Size(580, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('new_profile'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    final settings = AppSettings(File('${dir!.path}/settings.json'));
    await tester.runAsync(settings.load);
    final launcher = LauncherController(
      host: FakeHost(),
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    await tester.runAsync(launcher.init);
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
        ),
      ),
    );
    await settle(tester);
    final before = launcher.profiles.length;

    await tester.tap(find.text('Добавить'));
    // Середина перехода: кнопка летит в аватар — Hero в полёте.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(ProfileHero), findsWidgets);
    await settle(tester);
    expect(AppPages.current.value, AppPages.newProfile);
    expect(find.text('Новый профиль'), findsOneWidget);
    expect(find.byTooltip('Назад'), findsOneWidget);

    // Без названия — ошибка, профиль не создаётся.
    await tester.tap(find.text('Создать'));
    await tester.pump();
    expect(find.text('Введите название'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Клиент');
    await tester.tap(find.text('Создать'));
    // Запись профиля на диск — настоящий ввод-вывод: даём ему пройти.
    for (var i = 0; i < 30 && AppPages.current.value != AppPages.home; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);
    expect(launcher.profiles.length, before + 1);
    expect(launcher.profiles.last.name, 'Клиент');
    expect(AppPages.current.value, AppPages.home);
    expect(find.text('Клиент'), findsOneWidget);
    // Оповещение внизу — с кнопкой «Открыть».
    expect(find.textContaining('Профиль «Клиент» создан'), findsOneWidget);
    expect(find.text('Открыть'), findsOneWidget);
    AppSnackbar.dismiss();
    await settle(tester);

    // Правка — та же страница: поля заполнены, «Сохранить» меняет профиль.
    final created = launcher.profiles.last;
    AppPages.open(AppPages.editProfile(created.id));
    await settle(tester);
    expect(find.text('Профиль'), findsOneWidget);
    expect(find.text('Сохранить'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Клиент'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Клиент Б');
    await tester.tap(find.text('Сохранить'));
    for (var i = 0; i < 30 && AppPages.current.value != AppPages.home; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);
    expect(AppPages.current.value, AppPages.home);
    expect(launcher.profiles.last.id, created.id);
    expect(launcher.profiles.last.name, 'Клиент Б');
    expect(find.text('Клиент Б'), findsOneWidget);
    expect(find.text('Профиль «Клиент Б» сохранён'), findsOneWidget);
    AppSnackbar.reset();
  });
}
