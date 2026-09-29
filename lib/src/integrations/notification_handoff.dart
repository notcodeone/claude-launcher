import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'claude_code_hooks.dart';

/// Уведомления Claude Code — только от лаунчера, пока он запущен: свои
/// уведомления Claude лаунчер выключает, а когда перестаёт показывать их сам,
/// возвращает как было.
///
/// - Claude Code в терминале: `preferredNotifChannel` в `~/.claude/settings.json`.
///   Он читает его при каждом уведомлении, так что меняется сразу.
/// - Приложение Claude: `preferences.notificationLevels` в
///   `claude_desktop_config.json` в папке профиля. Этот файл Claude читает один
///   раз при запуске, а потом переписывает целиком из памяти. Поэтому его
///   трогаем, только пока Claude этого профиля закрыт: перед запуском и после
///   закрытия.
///
/// Как было до лаунчера — в [stateFile]. Его же читает наблюдатель, который
/// после выхода из лаунчера ждёт закрытия Claude (см. `main.dart`), поэтому
/// менять настройки может только владелец ([claim]).
class NotificationHandoff {
  NotificationHandoff({
    required this.stateFile,
    required this.hooks,
    required this.samePath,
    int? ownerId,
  }) : ownerId = ownerId ?? pid;

  final File stateFile;
  final ClaudeCodeHooks hooks;
  final bool Function(String a, String b) samePath;

  /// Кто распоряжается настройками: процесс лаунчера или наблюдателя.
  final int ownerId;

  static const cliOff = 'notifications_disabled';

  /// Разрешение, вопрос и завершение задачи — всё, чем приложение Claude
  /// уведомляет о сессиях.
  static const desktopOff = {
    'permission': 'off',
    'question': 'off',
    'idle': 'off',
  };

  static const desktopConfigName = 'claude_desktop_config.json';

  Future<void> _queue = Future.value();

  /// По очереди: иначе две правки одного файла перемешаются.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Становится владельцем. [onlyIfFree] — только если владельца нет:
  /// наблюдатель не отнимает настройки у снова запущенного лаунчера.
  Future<bool> claim({bool onlyIfFree = false}) => _serial(() async {
    final state = await _load();
    if (onlyIfFree && state.owner != null && state.owner != ownerId) {
      return false;
    }
    state.owner = ownerId;
    await _save(state);
    return true;
  });

  /// Отдаёт владение: дальше настройки вернёт наблюдатель или следующий запуск.
  Future<void> resign() => _serial(() async {
    final state = await _load();
    if (state.owner != ownerId) return;
    state.owner = null;
    await _save(state);
  });

  /// Приводит настройки Claude к нужному виду. [active] — уведомления
  /// показывает лаунчер; [profiles] — папки профилей; [running] — папки
  /// запущенных Claude, их файлы не трогаем. [force] — вернуть всё, даже
  /// у запущенных (при удалении лаунчера: лучше так, чем никак).
  ///
  /// `pending` — остались профили с выключенными уведомлениями: при [active]
  /// это все выключенные, иначе — те, что вернутся после закрытия Claude.
  Future<({bool pending, String? error})> sync({
    required bool active,
    required List<String> profiles,
    required List<String> running,
    bool force = false,
  }) => _serial(() async {
    final state = await _load();
    if (state.owner != ownerId) return (pending: false, error: null);
    String? error;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        error ??= '$e';
      }
    }

    bool isRunning(String dir) =>
        !force && running.any((other) => samePath(other, dir));
    bool isProfile(String dir) => profiles.any((other) => samePath(other, dir));

    await attempt(() => active ? _takeCli(state) : _releaseCli(state));
    if (active) {
      for (final dir in profiles) {
        if (isRunning(dir)) continue;
        await attempt(() => _takeDesktop(state, dir, create: false));
      }
    }
    for (final dir in state.desktop.keys.toList()) {
      if (isRunning(dir) || (active && isProfile(dir))) continue;
      await attempt(() => _releaseDesktop(state, dir));
    }
    return (pending: state.desktop.isNotEmpty, error: error);
  });

  /// Перед запуском Claude с папкой [dir] (он закрыт): выключает его
  /// уведомления, даже если файла настроек ещё нет. Возвращает ошибку.
  Future<String?> takeBeforeLaunch(String dir) => _serial(() async {
    final state = await _load();
    if (state.owner != ownerId) return null;
    try {
      await _takeDesktop(state, dir, create: true);
      return null;
    } catch (e) {
      return '$e';
    }
  });

  // ------------------------------------------------------------------ терминал

  Future<void> _takeCli(_State state) async {
    final current = await hooks.notificationChannel();
    // Уже выключено: нами или самим пользователем — тогда возвращать нечего.
    if (current == cliOff) return;
    state.cli = _Original(current);
    await _save(state);
    await hooks.setNotificationChannel(cliOff);
  }

  Future<void> _releaseCli(_State state) async {
    final original = state.cli;
    if (original == null) return;
    // Если пользователь сам поменял настройку, пока она была у нас, — не трогаем.
    if (await hooks.notificationChannel() == cliOff) {
      await hooks.setNotificationChannel(original.value);
    }
    state.cli = null;
    await _save(state);
  }

  // ------------------------------------------------------------- приложение

  Future<void> _takeDesktop(
    _State state,
    String dir, {
    required bool create,
  }) async {
    final file = File(p.join(dir, desktopConfigName));
    if (!create && !await file.exists()) return;
    final config = await _readConfig(file);
    if (config == null) return;
    final levels = _levelsOf(config);
    if (_isOff(levels)) return;
    state.desktop[_keyOf(state, dir)] = _Original(levels);
    // Сначала запоминаем, потом меняем: так сбой посередине ничего не потеряет.
    await _save(state);
    await _writeConfig(file, _withLevels(config, desktopOff));
  }

  Future<void> _releaseDesktop(_State state, String dir) async {
    final file = File(p.join(dir, desktopConfigName));
    try {
      final config = await file.exists() ? await _readConfig(file) : null;
      if (config != null && _isOff(_levelsOf(config))) {
        await _writeConfig(
          file,
          _withLevels(config, state.desktop[dir]!.value),
        );
      }
    } on FormatException {
      // Файл испорчен — вернуть уже нечего, забываем о нём.
    }
    state.desktop.remove(dir);
    await _save(state);
  }

  String _keyOf(_State state, String dir) =>
      state.desktop.keys.where((key) => samePath(key, dir)).firstOrNull ?? dir;

  static Object? _levelsOf(Map<String, Object?> config) =>
      (config['preferences'] as Map?)?['notificationLevels'];

  static bool _isOff(Object? levels) =>
      levels is Map &&
      levels.length == desktopOff.length &&
      desktopOff.entries.every((entry) => levels[entry.key] == entry.value);

  static Map<String, Object?> _withLevels(
    Map<String, Object?> config,
    Object? levels,
  ) {
    final preferences = Map<String, Object?>.of(
      config['preferences'] as Map<String, Object?>? ?? const {},
    );
    if (levels == null) {
      preferences.remove('notificationLevels');
    } else {
      preferences['notificationLevels'] = levels;
    }
    return {...config, 'preferences': preferences};
  }

  /// `null` — пустой файл: такой Claude считает испорченным, его не трогаем.
  static Future<Map<String, Object?>?> _readConfig(File file) async {
    if (!await file.exists()) return {};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return null;
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw FormatException('${file.path}: не JSON-объект');
    }
    return json;
  }

  static Future<void> _writeConfig(
    File file,
    Map<String, Object?> config,
  ) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.claude-launcher-tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  // --------------------------------------------------------------- состояние

  Future<_State> _load() async {
    if (!await stateFile.exists()) return _State();
    try {
      final json = jsonDecode(await stateFile.readAsString());
      if (json is Map<String, Object?>) return _State.fromJson(json);
    } on FormatException {
      // Повреждённый файл — начинаем заново.
    }
    return _State();
  }

  Future<void> _save(_State state) async {
    await stateFile.parent.create(recursive: true);
    final tmp = File('${stateFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
      flush: true,
    );
    await tmp.rename(stateFile.path);
  }
}

/// Значение настройки до лаунчера; `null` внутри — настройки не было.
class _Original {
  const _Original(this.value);

  final Object? value;

  Map<String, Object?> toJson() => {'original': value};

  static _Original? fromJson(Object? json) =>
      json is Map ? _Original(json['original']) : null;
}

class _State {
  _State();

  factory _State.fromJson(Map<String, Object?> json) {
    final desktop = json['desktop'];
    return _State()
      ..owner = json['owner'] as int?
      ..cli = _Original.fromJson(json['cli'])
      ..desktop = {
        if (desktop is Map)
          for (final MapEntry(:key, :value) in desktop.entries)
            '$key': ?_Original.fromJson(value),
      };
  }

  int? owner;

  /// Есть — канал уведомлений Claude Code выключил лаунчер.
  _Original? cli;

  /// Папки профилей, где уведомления приложения выключил лаунчер.
  Map<String, _Original> desktop = {};

  Map<String, Object?> toJson() => {
    'owner': owner,
    'cli': cli?.toJson(),
    'desktop': {
      for (final MapEntry(:key, :value) in desktop.entries) key: value.toJson(),
    },
  };
}
