import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/integrations/claude_tray_icon.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

/// Профили — во временной папке, чтобы писать в них по-настоящему.
class TempHost extends FakeHost {
  TempHost(this.base);

  final String base;

  @override
  String get profilesBaseDir => base;

  @override
  String get defaultDataDir => '$base/Claude';
}

void main() {
  late Directory dir;
  late AppSettings settings;
  late TempHost host;
  late LauncherController launcher;
  late ClaudeTrayIcon tray;

  Map<String, Object?> config(String profileDir) =>
      jsonDecode(
            File('$profileDir/claude_desktop_config.json').readAsStringSync(),
          )
          as Map<String, Object?>;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tray_icon');
    settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.load();
    host = TempHost(dir.path);
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    await launcher.init();
    tray = ClaudeTrayIcon(settings: settings, launcher: launcher);
  });

  tearDown(() async {
    tray.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'перед запуском — menuBarEnabled: false, остальное не тронуто',
    () async {
      final claude = Directory('${dir.path}/Claude')..createSync();
      File('${claude.path}/claude_desktop_config.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {'x': 1},
          'preferences': {
            'notificationLevels': {'idle': 'off'},
          },
        }),
      );
      await settings.setHideClaudeIcon(true);
      await tray.beforeLaunch(claude.path);
      final json = config(claude.path);
      expect(json['mcpServers'], {'x': 1});
      final preferences = json['preferences']! as Map;
      expect(preferences['menuBarEnabled'], isFalse);
      expect(preferences['notificationLevels'], {'idle': 'off'});
    },
  );

  test('профиль ещё не открывали — файл создаётся перед запуском', () async {
    await settings.setHideClaudeIcon(true);
    final fresh = '${dir.path}/Claude-New';
    await tray.beforeLaunch(fresh);
    expect((config(fresh)['preferences']! as Map)['menuBarEnabled'], isFalse);
  });

  test('выключили настройку — закрытым профилям значок возвращается', () async {
    final claude = Directory('${dir.path}/Claude')..createSync();
    await settings.setHideClaudeIcon(true);
    await tray.beforeLaunch(claude.path);
    tray.start();
    await settings.setHideClaudeIcon(false);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final preferences = config(claude.path)['preferences']! as Map;
    expect(preferences.containsKey('menuBarEnabled'), isFalse);
  });

  test('открытый Claude не трогаем — он перепишет файл при выходе', () async {
    final claude = Directory('${dir.path}/Claude')..createSync();
    final file = File('${claude.path}/claude_desktop_config.json')
      ..writeAsStringSync('{}');
    host.start(null);
    await launcher.refresh();
    tray.start();
    await settings.setHideClaudeIcon(true);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(file.readAsStringSync(), '{}');
  });
}
