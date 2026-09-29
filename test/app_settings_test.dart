import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(
    () async =>
        dir = await Directory.systemTemp.createTemp('claude_launcher_settings'),
  );
  tearDown(() => dir.delete(recursive: true));

  test('тема по умолчанию — как в системе', () async {
    final settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.load();
    expect(settings.themeMode, ThemeMode.system);
  });

  test('выбранная тема сохраняется между запусками', () async {
    final file = File('${dir.path}/nested/settings.json');
    await AppSettings(file).setThemeMode(ThemeMode.light);

    final reloaded = AppSettings(file);
    await reloaded.load();
    expect(reloaded.themeMode, ThemeMode.light);
  });

  test('приветствие, значок и профиль при запуске сохраняются', () async {
    final file = File('${dir.path}/settings.json');
    final settings = AppSettings(file);
    await settings.load();
    expect(settings.onboardingDone, isFalse);
    expect(settings.hideClaudeIcon, isFalse);
    expect(settings.startupProfileId, isNull);

    await settings.setHideClaudeIcon(true);
    await settings.setStartupProfile('abc');
    await settings.completeOnboarding();

    final reloaded = AppSettings(file);
    await reloaded.load();
    expect(reloaded.onboardingDone, isTrue);
    expect(reloaded.hideClaudeIcon, isTrue);
    expect(reloaded.startupProfileId, 'abc');
  });

  test('повреждённый файл не ломает запуск', () async {
    final file = File('${dir.path}/settings.json')
      ..writeAsStringSync('{не json');
    final settings = AppSettings(file);
    await settings.load();
    expect(settings.themeMode, ThemeMode.system);
  });
}
