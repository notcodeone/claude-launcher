import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_settings_copy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('copy'));
  tearDown(() => root.delete(recursive: true));

  Future<void> write(String dir, String name, Object json) async {
    final file = File(p.join(root.path, dir, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(json));
  }

  Map<String, dynamic> read(String dir, String name) =>
      jsonDecode(File(p.join(root.path, dir, name)).readAsStringSync())
          as Map<String, dynamic>;

  test(
    'берёт только разрешённое, без аккаунта и того, что у лаунчера',
    () async {
      await write('from', 'claude_desktop_config.json', {
        'preferences': {
          'sidebarMode': 'epitaxy',
          'chicagoEnabled': true,
          'menuBarEnabled': false,
          'notificationLevels': {'x': 1},
          'bypassPermissionsOptInByAccount': {'acc': true},
          'epitaxyPrefs': {
            'claude-code-preferred-editor': 'cursor',
            'starred-local-code-sessions': ['local_1'],
            'epitaxy-auto-mode-denial-count.acc': 3,
          },
        },
        'mcpServers': {
          'secret': {
            'env': {'TOKEN': 'x'},
          },
        },
      });
      await write('from', 'config.json', {'darkMode': 'dark', 'oauth': 'x'});
      final copied = await ProfileSettingsCopy.copy(
        from: p.join(root.path, 'from'),
        to: p.join(root.path, 'to'),
      );
      expect(copied, 4);
      expect(read('to', 'claude_desktop_config.json'), {
        'preferences': {
          'sidebarMode': 'epitaxy',
          'chicagoEnabled': true,
          'epitaxyPrefs': {'claude-code-preferred-editor': 'cursor'},
        },
      });
      expect(read('to', 'config.json'), {'darkMode': 'dark'});
    },
  );

  test('дописывает в существующие файлы, не стирая своё', () async {
    await write('from', 'claude_desktop_config.json', {
      'preferences': {'sidebarMode': 'chat'},
    });
    await write('to', 'claude_desktop_config.json', {
      'preferences': {'sidebarMode': 'code', 'menuBarEnabled': false},
      'coworkUserFilesPath': '/x',
    });
    await ProfileSettingsCopy.copy(
      from: p.join(root.path, 'from'),
      to: p.join(root.path, 'to'),
    );
    expect(read('to', 'claude_desktop_config.json'), {
      'preferences': {'sidebarMode': 'chat', 'menuBarEnabled': false},
      'coworkUserFilesPath': '/x',
    });
  });

  test('нечего брать — ничего не создаёт', () async {
    final copied = await ProfileSettingsCopy.copy(
      from: p.join(root.path, 'none'),
      to: p.join(root.path, 'to'),
    );
    expect(copied, 0);
    expect(Directory(p.join(root.path, 'to')).existsSync(), isFalse);
  });
}
