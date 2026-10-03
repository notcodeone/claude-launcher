import 'dart:io';

import 'package:claude_launcher/src/updates/app_updater.dart';
import 'package:claude_launcher/src/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'тестовая версия, включая нормализованную macOS, не проверяет stable',
    () async {
      final dir = await Directory.systemTemp.createTemp('preview-updater');
      addTearDown(() => dir.delete(recursive: true));
      for (final version in ['1.5.10-parallelism.1', '1.5.10.1']) {
        final updater = AppUpdater(
          currentVersion: version,
          settings: AppSettings(File('${dir.path}/settings.json')),
          quit: () async {},
        );
        await updater.check();
        expect(updater.checkedAt, isNull);
        expect(updater.error, isNull);
        await updater.check(manual: true);
        expect(updater.error, contains('Тестовая сборка'));
        expect(updater.release, isNull);
        updater.dispose();
      }
    },
  );

  test('сравнение версий', () {
    expect(isNewerVersion('1.2.3', '1.2.2'), isTrue);
    expect(isNewerVersion('1.10.0', '1.9.9'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
    expect(isNewerVersion('1.2.2', '1.2.2'), isFalse);
    expect(isNewerVersion('1.2.1', '1.2.2'), isFalse);
    expect(isNewerVersion('1.3.0', '1.2.2+7'), isTrue);
    expect(isNewerVersion('бета', '1.2.2'), isFalse);
    expect(parseVersion('1.2'), isNull);
  });

  test('выпуск GitHub: версия из тега, файлы по имени', () {
    final release = AppRelease.fromJson({
      'tag_name': 'v1.3.0',
      'html_url':
          'https://github.com/notcodeone/claude-launcher/releases/v1.3.0',
      'assets': [
        {
          'name': 'ClaudeLauncher-1.3.0.dmg',
          'browser_download_url':
              'https://github.com/x/ClaudeLauncher-1.3.0.dmg',
        },
        {
          'name': 'ClaudeLauncher-Setup-1.3.0.exe',
          'browser_download_url':
              'https://github.com/x/ClaudeLauncher-Setup-1.3.0.exe',
        },
        // Не по HTTPS — не скачиваем.
        {
          'name': 'evil.dmg',
          'browser_download_url': 'http://example.com/evil.dmg',
        },
      ],
    })!;
    expect(release.version, '1.3.0');
    expect(release.assets.keys, [
      'ClaudeLauncher-1.3.0.dmg',
      'ClaudeLauncher-Setup-1.3.0.exe',
    ]);
    if (Platform.isMacOS) {
      expect(release.installer?.path, endsWith('ClaudeLauncher-1.3.0.dmg'));
    }
  });

  test('черновики, предварительные и непонятные теги пропускаются', () {
    expect(
      AppRelease.fromJson({
        'tag_name': 'v1.3.0',
        'html_url': 'https://github.com/x',
        'prerelease': true,
      }),
      isNull,
    );
    expect(
      AppRelease.fromJson({'tag_name': 'latest', 'html_url': 'https://x'}),
      isNull,
    );
    expect(AppRelease.fromJson('нет'), isNull);
  });

  test('суммы файлов: от GitHub и из SHA256SUMS.txt', () {
    const hex =
        'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855';
    final release = AppRelease.fromJson({
      'tag_name': 'v1.5.10',
      'html_url': 'https://github.com/x/releases/v1.5.10',
      'assets': [
        {
          'name': 'ClaudeLauncher-1.5.10.dmg',
          'browser_download_url': 'https://github.com/x/a.dmg',
          'digest': 'sha256:$hex',
        },
        {
          'name': 'ClaudeLauncher-Setup-1.5.10.exe',
          'browser_download_url': 'https://github.com/x/a.exe',
          'digest': 'md5:abc',
        },
      ],
    })!;
    expect(release.digests, {'ClaudeLauncher-1.5.10.dmg': hex.toLowerCase()});

    expect(
      parseChecksums(
        '$hex  ClaudeLauncher-1.5.10.dmg\n'
        '${'a' * 64} *ClaudeLauncher-Setup-1.5.10.exe\r\n'
        'мусор\n',
      ),
      {
        'ClaudeLauncher-1.5.10.dmg': hex.toLowerCase(),
        'ClaudeLauncher-Setup-1.5.10.exe': 'a' * 64,
      },
    );
  });
}
