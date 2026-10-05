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

  test(
    'приветствие, подсказка, значок и профиль при запуске сохраняются',
    () async {
      final file = File('${dir.path}/settings.json');
      final settings = AppSettings(file);
      await settings.load();
      expect(settings.onboardingDone, isFalse);
      expect(settings.trayHintDismissed, isFalse);
      expect(settings.hideClaudeIcon, isFalse);
      expect(settings.startupProfileId, isNull);

      await settings.setHideClaudeIcon(true);
      await settings.setStartupProfile('abc');
      await settings.completeOnboarding();
      await settings.dismissTrayHint();

      final reloaded = AppSettings(file);
      await reloaded.load();
      expect(reloaded.onboardingDone, isTrue);
      expect(reloaded.trayHintDismissed, isTrue);
      expect(reloaded.hideClaudeIcon, isTrue);
      expect(reloaded.startupProfileId, 'abc');
    },
  );

  test(
    'лимиты профиля выключены, сохраняются, прежний переключатель переносится',
    () async {
      final file = File('${dir.path}/settings.json');
      final settings = AppSettings(file);
      await settings.load();
      expect(settings.usageLimits, isFalse);
      await settings.setUsageLimits(true);

      final reloaded = AppSettings(file);
      await reloaded.load();
      expect(reloaded.usageLimits, isTrue);

      final old = File('${dir.path}/old.json')
        ..writeAsStringSync('{"experimentalFeatures": true}');
      final migrated = AppSettings(old);
      await migrated.load();
      expect(migrated.usageLimits, isTrue);
    },
  );

  test(
    'параллельный режим включён по умолчанию, сохранённый выбор — нет',
    () async {
      final file = File('${dir.path}/settings.json');
      final settings = AppSettings(file);
      await settings.load();
      expect(settings.parallelLaunch, isTrue);
      await settings.setParallelLaunch(false);
      final reloaded = AppSettings(file);
      await reloaded.load();
      expect(reloaded.parallelLaunch, isFalse);
    },
  );

  test(
    'старый автозапуск переносится в набор, явный пустой набор сохраняется',
    () async {
      final file = File('${dir.path}/settings.json')
        ..writeAsStringSync('{"startupProfileId":"old"}');
      final settings = AppSettings(file);
      await settings.load();
      expect(settings.startupProfileIds, ['old']);
      await settings.toggleParallelStartupProfile('old');
      final reloaded = AppSettings(file);
      await reloaded.load();
      expect(reloaded.startupProfileId, 'old');
      expect(reloaded.startupProfileIds, isEmpty);
    },
  );

  test(
    'набор и одиночный автозапуск выбираются независимо; удаление чистит оба',
    () async {
      final file = File('${dir.path}/settings.json');
      final settings = AppSettings(file);
      await settings.load();
      await settings.setStartupProfile('a');
      await settings.toggleParallelStartupProfile('a');
      await settings.toggleParallelStartupProfile('b');
      await settings.setParallelLaunch(true);
      final reloaded = AppSettings(file);
      await reloaded.load();
      expect(reloaded.startsProfile('a'), isTrue);
      expect(reloaded.startsProfile('b'), isTrue);
      await reloaded.removeStartupProfile('a');
      expect(reloaded.startupProfileId, isNull);
      expect(reloaded.startupProfileIds, ['b']);
      await reloaded.setParallelLaunch(false);
      expect(reloaded.startsProfile('b'), isFalse);
    },
  );

  test('повторяющиеся и нестроковые ID набора не переносятся', () async {
    final file = File('${dir.path}/settings.json')
      ..writeAsStringSync('{"startupProfileIds":["a",null,1,"","a","b"]}');
    final settings = AppSettings(file);
    await settings.load();
    expect(settings.startupProfileIds, ['a', 'b']);
  });

  test('повреждённый файл не ломает запуск', () async {
    final file = File('${dir.path}/settings.json')
      ..writeAsStringSync('{не json');
    final settings = AppSettings(file);
    await settings.load();
    expect(settings.themeMode, ThemeMode.system);
  });
}
