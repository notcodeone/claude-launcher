import 'dart:io';

import 'package:claude_launcher/src/claude/profile_shortcut.dart';
import 'package:claude_launcher/src/integrations/claude_links.dart';
import 'package:claude_launcher/src/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const profile = Profile(id: 'abc123', name: 'Работа: клиент/A');

  test('имя файла без недопустимых символов', () {
    expect(
      ProfileShortcut.fileName(profile, windows: true),
      'Claude — Работа  клиент A.url',
    );
    expect(
      ProfileShortcut.fileName(profile, windows: false),
      'Claude — Работа  клиент A.webloc',
    );
  });

  test('ссылка ярлыка ведёт на профиль', () {
    final link = ClaudeLinks.shortcutFor(profile);
    expect('$link', 'claudelauncher://open/abc123');
    expect(ClaudeLinks.shortcutProfileId(link), 'abc123');
    expect(ClaudeLinks.shortcutProfileId(Uri.parse('claude://open/x')), isNull);
  });

  test('содержимое .url и .webloc', () {
    final url = ProfileShortcut.contents(
      profile,
      windows: true,
      iconFile: r'C:\Apps\claude_launcher.exe',
    );
    expect(url, contains('URL=claudelauncher://open/abc123\r\n'));
    expect(url, contains(r'IconFile=C:\Apps\claude_launcher.exe'));
    final webloc = ProfileShortcut.contents(profile, windows: false);
    expect(webloc, contains('<string>claudelauncher://open/abc123</string>'));
  });

  test('создаёт файл на рабочем столе', () async {
    final desktop = await Directory.systemTemp.createTemp('desktop');
    try {
      final file = await ProfileShortcut.create(profile, desktop: desktop.path);
      expect(file.existsSync(), isTrue);
      expect(
        await file.readAsString(),
        contains('claudelauncher://open/abc123'),
      );
    } finally {
      await desktop.delete(recursive: true);
    }
  });
}
