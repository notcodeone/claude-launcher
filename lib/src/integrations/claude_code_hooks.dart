import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Хуки Claude Code, через которые лаунчер узнаёт о событиях: задача завершена
/// (`Stop`) и Claude ждёт пользователя (`Notification`).
///
/// Хуки — официальный механизм Claude Code: работают и в терминале, и во вкладке
/// Code приложения Claude. Лаунчер добавляет HTTP-хуки на свой локальный адрес;
/// если лаунчер не запущен, Claude Code просто продолжает работу.
///
/// Свои записи лаунчер узнаёт по [marker] в адресе и трогает только их.
class ClaudeCodeHooks {
  ClaudeCodeHooks(this.settingsFile);

  /// Файл по умолчанию: `~/.claude/settings.json`.
  factory ClaudeCodeHooks.forCurrentUser() {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']!
        : Platform.environment['HOME']!;
    return ClaudeCodeHooks(File(p.join(home, '.claude', 'settings.json')));
  }

  final File settingsFile;

  static const marker = '/claude-launcher/';
  static const events = ['Stop', 'Notification'];

  static String endpoint(int port) => 'http://127.0.0.1:$port${marker}v1/event';

  /// Исходный файл до первого изменения лаунчером.
  File get backup => File('${settingsFile.path}.claude-launcher-backup');

  /// Добавляет (или обновляет) хуки лаунчера. Остальное содержимое не меняется.
  Future<void> install({required int port, required String token}) async {
    final settings = await _read();
    final hooks = _hooksOf(settings);
    for (final event in events) {
      hooks[event] = [
        ..._withoutOurs(hooks[event]),
        {
          'hooks': [
            {
              'type': 'http',
              'url': endpoint(port),
              'timeout': 5,
              'headers': {'X-Claude-Launcher-Token': token},
            },
          ],
        },
      ];
    }
    settings['hooks'] = hooks;
    await _write(settings);
  }

  /// Убирает только хуки лаунчера; опустевшие разделы тоже убирает.
  Future<void> uninstall() async {
    if (!await settingsFile.exists()) return;
    final settings = await _read();
    final hooks = _hooksOf(settings);
    var changed = false;
    for (final event in events) {
      final before = hooks[event];
      if (before == null) continue;
      final after = _withoutOurs(before);
      if (after.length == (before as List).length) continue;
      changed = true;
      if (after.isEmpty) {
        hooks.remove(event);
      } else {
        hooks[event] = after;
      }
    }
    if (!changed) return;
    if (hooks.isEmpty) {
      settings.remove('hooks');
    } else {
      settings['hooks'] = hooks;
    }
    await _write(settings);
  }

  /// Стоят ли хуки лаунчера на [port] с ключом [token].
  Future<bool> isInstalled({required int port, required String token}) async {
    if (!await settingsFile.exists()) return false;
    final hooks = _hooksOf(await _read());
    return events.every(
      (event) => (hooks[event] as List? ?? const []).any(
        (group) => _ours(group).any(
          (hook) =>
              hook['url'] == endpoint(port) &&
              (hook['headers'] as Map?)?['X-Claude-Launcher-Token'] == token,
        ),
      ),
    );
  }

  Future<Map<String, Object?>> _read() async {
    if (!await settingsFile.exists()) return {};
    final text = await settingsFile.readAsString();
    if (text.trim().isEmpty) return {};
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('в ~/.claude/settings.json не JSON-объект');
    }
    return json;
  }

  Future<void> _write(Map<String, Object?> settings) async {
    await settingsFile.parent.create(recursive: true);
    if (await settingsFile.exists() && !await backup.exists()) {
      await settingsFile.copy(backup.path);
    }
    final tmp = File('${settingsFile.path}.claude-launcher-tmp');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(settings)}\n',
      flush: true,
    );
    await tmp.rename(settingsFile.path);
  }

  static Map<String, Object?> _hooksOf(Map<String, Object?> settings) {
    final hooks = settings['hooks'];
    if (hooks == null) return {};
    if (hooks is! Map<String, Object?>) {
      throw const FormatException('раздел "hooks" — не JSON-объект');
    }
    return Map.of(hooks);
  }

  static List<Object?> _withoutOurs(Object? groups) => [
    for (final group in groups as List? ?? const [])
      if (_ours(group).isEmpty) group,
  ];

  /// Хуки лаунчера внутри группы.
  static List<Map<Object?, Object?>> _ours(Object? group) => [
    if (group is Map)
      for (final hook in group['hooks'] as List? ?? const [])
        if (hook is Map && (hook['url'] as String? ?? '').contains(marker))
          hook,
  ];
}
