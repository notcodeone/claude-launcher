import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// «Взять настройки из профиля…» при создании профиля: настройки Claude, не
/// привязанные к аккаунту, — из папки другого профиля в папку нового.
///
/// Только по списку (research, «Безопасные ключи»). Не берём то, что привязано
/// к аккаунту (`…ByAccount`, ключи с id аккаунта), и то, чем управляет сам
/// лаунчер: значок (`menuBarEnabled`), уведомления (`notificationLevels`).
abstract final class ProfileSettingsCopy {
  /// `claude_desktop_config.json` → `preferences`.
  static const preferences = [
    'sidebarMode',
    'quickEntryShortcut',
    'chicagoEnabled',
    'coworkScheduledTasksEnabled',
    'ccdScheduledTasksEnabled',
    'coworkWebSearchEnabled',
    'coworkBrowserToolsEnabled',
    'coworkPreferredBrowser',
    'launchPreviewPersistSession',
  ];

  /// `preferences.epitaxyPrefs` — настройки вкладки Code без привязки к аккаунту.
  static const codePreferences = [
    'claude-code-preferred-editor',
    'cc-landing-worktree-enabled',
    'epitaxy-transcript-links-in-preview',
  ];

  /// `config.json` — вид окна.
  static const window = ['darkMode', 'scale', 'multiTitleBar'];

  /// Копирует из [from] в [to] (папки данных профилей). [to] — профиль, который
  /// сейчас закрыт: Claude переписывает эти файлы из памяти. Сколько настроек
  /// перенесено.
  static Future<int> copy({required String from, required String to}) async {
    var copied = 0;
    final source = await _read(p.join(from, 'claude_desktop_config.json'));
    final prefs = source['preferences'];
    if (prefs is Map<String, dynamic>) {
      final picked = <String, Object?>{
        for (final key in preferences)
          if (prefs.containsKey(key)) key: prefs[key],
      };
      final code = prefs['epitaxyPrefs'];
      final pickedCode = <String, Object?>{
        if (code is Map<String, dynamic>)
          for (final key in codePreferences)
            if (code.containsKey(key)) key: code[key],
      };
      if (picked.isNotEmpty || pickedCode.isNotEmpty) {
        final file = p.join(to, 'claude_desktop_config.json');
        final target = await _read(file);
        final targetPrefs = <String, dynamic>{
          ...?target['preferences'] as Map<String, dynamic>?,
          ...picked,
        };
        if (pickedCode.isNotEmpty) {
          targetPrefs['epitaxyPrefs'] = <String, dynamic>{
            ...?targetPrefs['epitaxyPrefs'] as Map<String, dynamic>?,
            ...pickedCode,
          };
        }
        target['preferences'] = targetPrefs;
        await _write(file, target);
        copied += picked.length + pickedCode.length;
      }
    }
    final config = await _read(p.join(from, 'config.json'));
    final view = <String, Object?>{
      for (final key in window)
        if (config.containsKey(key)) key: config[key],
    };
    if (view.isNotEmpty) {
      final file = p.join(to, 'config.json');
      await _write(file, {...await _read(file), ...view});
      copied += view.length;
    }
    return copied;
  }

  static Future<Map<String, dynamic>> _read(String path) async {
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  /// Атомарно: временный файл и переименование.
  static Future<void> _write(String path, Map<String, dynamic> json) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final tmp = File('$path.claude-launcher-tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      flush: true,
    );
    await tmp.rename(path);
  }
}
