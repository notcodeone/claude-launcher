import 'dart:io';

import 'package:path/path.dart' as p;

import '../integrations/claude_links.dart';
import '../profile.dart';

/// Ярлык профиля на рабочем столе: файл со ссылкой `claudelauncher://open/<id>`.
/// Двойной щелчок открывает профиль через лаунчер — и когда тот закрыт.
/// macOS — `.webloc` (его можно перетащить в Dock), Windows — `.url` со
/// значком лаунчера.
abstract final class ProfileShortcut {
  static String fileName(Profile profile, {required bool windows}) {
    // Символы, которых не бывает в именах файлов Windows и macOS.
    final name = profile.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    return 'Claude — $name.${windows ? 'url' : 'webloc'}';
  }

  static String contents(
    Profile profile, {
    required bool windows,
    String? iconFile,
  }) {
    final link = ClaudeLinks.shortcutFor(profile);
    if (windows) {
      return [
        '[InternetShortcut]',
        'URL=$link',
        if (iconFile != null) ...['IconFile=$iconFile', 'IconIndex=0'],
        '',
      ].join('\r\n');
    }
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>$link</string>
</dict>
</plist>
''';
  }

  /// Рабочий стол. Windows: если его перенёс OneDrive — туда.
  static String desktopDir(Map<String, String> environment) {
    if (Platform.isWindows) {
      final oneDrive = environment['OneDrive'];
      if (oneDrive != null) {
        final dir = p.join(oneDrive, 'Desktop');
        if (Directory(dir).existsSync()) return dir;
      }
      return p.join(environment['USERPROFILE'] ?? '', 'Desktop');
    }
    return p.join(environment['HOME'] ?? '', 'Desktop');
  }

  /// Создаёт ярлык (поверх прежнего с тем же именем) и возвращает его файл.
  static Future<File> create(Profile profile, {String? desktop}) async {
    final windows = Platform.isWindows;
    final file = File(
      p.join(
        desktop ?? desktopDir(Platform.environment),
        fileName(profile, windows: windows),
      ),
    );
    await file.writeAsString(
      contents(
        profile,
        windows: windows,
        iconFile: windows ? Platform.resolvedExecutable : null,
      ),
    );
    return file;
  }
}
