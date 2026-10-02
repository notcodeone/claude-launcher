import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Хуки Claude Code, через которые лаунчер узнаёт, что делает Claude Code:
/// работает, ждёт пользователя или закончил задачу (см. [events]).
///
/// Хуки — официальный механизм Claude Code: работают и в терминале, и во вкладке
/// Code приложения Claude. Лаунчер добавляет HTTP-хуки на свой локальный адрес;
/// если лаунчер не запущен, Claude Code просто продолжает работу.
///
/// Свои записи лаунчер узнаёт по [marker] в адресе и трогает только их.
class ClaudeCodeHooks {
  ClaudeCodeHooks(this.settingsFile);

  /// Файл настроек Claude Code: `~/.claude/settings.json`, а если задана
  /// переменная `CLAUDE_CONFIG_DIR` — в её папке, как у самого Claude Code.
  factory ClaudeCodeHooks.forCurrentUser() =>
      ClaudeCodeHooks(File(settingsPath(Platform.environment)));

  @visibleForTesting
  static String settingsPath(Map<String, String> environment) {
    final custom = environment['CLAUDE_CONFIG_DIR']?.trim();
    if (custom != null && custom.isNotEmpty) {
      return p.join(custom, 'settings.json');
    }
    final home = Platform.isWindows
        ? environment['USERPROFILE']!
        : environment['HOME']!;
    return p.join(home, '.claude', 'settings.json');
  }

  final File settingsFile;

  static const marker = '/claude-launcher/';

  /// Начало задачи, работа инструментов (запасной признак «работает»: в
  /// приложении начало задачи приходит не всегда), ожидание, конец, закрытие сессии.
  static const events = [
    'UserPromptSubmit',
    'PostToolUse',
    'Notification',
    'Stop',
    'SessionEnd',
  ];

  /// Заголовок с идентификатором сессии в приложении Claude (`local_…`).
  static const hostSessionHeader = 'X-Claude-Host-Session';
  static const tokenHeader = 'X-Claude-Launcher-Token';

  static String endpoint(int port) => 'http://127.0.0.1:$port${marker}v1/event';

  /// Исходный файл до первого изменения лаунчером.
  File get backup => File('${settingsFile.path}.claude-launcher-backup');

  /// Хук лаунчера. Короткий таймаут: если лаунчер завис, Claude Code ждёт недолго.
  static Map<String, Object?> hookFor({
    required int port,
    required String token,
  }) => {
    'type': 'http',
    'url': endpoint(port),
    'timeout': 2,
    'headers': {
      tokenHeader: token,
      hostSessionHeader: r'$CLAUDE_CODE_HOST_SESSION_ID',
    },
    'allowedEnvVars': ['CLAUDE_CODE_HOST_SESSION_ID'],
  };

  /// Добавляет (или обновляет) хуки лаунчера. Остальное содержимое не меняется.
  Future<void> install({required int port, required String token}) async {
    final settings = await _read();
    // Сначала убираем свои записи отовсюду — в том числе от прошлых версий.
    final hooks = _withoutOursEverywhere(_hooksOf(settings));
    for (final event in events) {
      hooks[event] = [
        ...?hooks[event] as List?,
        {
          'hooks': [hookFor(port: port, token: token)],
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
    final before = _hooksOf(settings);
    final hooks = _withoutOursEverywhere(before);
    if (jsonEncode(hooks) == jsonEncode(before)) return;
    if (hooks.isEmpty) {
      settings.remove('hooks');
    } else {
      settings['hooks'] = hooks;
    }
    await _write(settings);
  }

  /// Стоят ли ровно такие хуки лаунчера, как ставит [install] для [port] и [token].
  Future<bool> isInstalled({required int port, required String token}) async {
    if (!await settingsFile.exists()) return false;
    final hooks = _hooksOf(await _read());
    final expected = jsonEncode(hookFor(port: port, token: token));
    return events.every(
      (event) => (hooks[event] as List? ?? const []).any(
        (group) => _ours(group).any((hook) => jsonEncode(hook) == expected),
      ),
    );
  }

  /// Как Claude Code в терминале сам сообщает, что ждёт или закончил.
  static const notificationChannelKey = 'preferredNotifChannel';

  /// Значение [notificationChannelKey]; `null` — не задано.
  Future<Object?> notificationChannel() async =>
      (await _read())[notificationChannelKey];

  /// Меняет [notificationChannelKey]; `null` — убирает. Остальное не трогает.
  Future<void> setNotificationChannel(Object? channel) async {
    if (channel == null && !await settingsFile.exists()) return;
    final settings = await _read();
    if (channel == null) {
      settings.remove(notificationChannelKey);
    } else {
      settings[notificationChannelKey] = channel;
    }
    await _write(settings);
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

  /// Все разделы без записей лаунчера; опустевшие разделы убираются.
  static Map<String, Object?> _withoutOursEverywhere(
    Map<String, Object?> hooks,
  ) => {
    for (final MapEntry(:key, :value) in hooks.entries)
      if (value is! List)
        key: value
      else if (_withoutOurs(value) case final rest when rest.isNotEmpty)
        key: rest,
  };

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
