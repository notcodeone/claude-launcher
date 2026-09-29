import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import 'claude_code_events.dart';
import 'claude_code_hooks.dart';
import 'claude_code_sessions.dart';

/// События Claude Code: подключение хуков, приём событий и сессии открытого
/// профиля (показываются на его карточке). Задел для уведомлений в Telegram.
class ClaudeCodeIntegration extends ChangeNotifier {
  ClaudeCodeIntegration({
    required this.settings,
    required this.launcher,
    ClaudeCodeHooks? hooks,
    ValueListenable<bool>? windowVisible,
    this.tickInterval = const Duration(seconds: 1),
  }) : hooks = hooks ?? ClaudeCodeHooks.forCurrentUser(),
       windowVisible = windowVisible ?? ValueNotifier(true) {
    launcher.addListener(_onLauncherChanged);
    this.windowVisible.addListener(_updateWatching);
  }

  final AppSettings settings;
  final LauncherController launcher;
  final ClaudeCodeHooks hooks;

  /// Открыто ли окно лаунчера. Пока закрыто, время и токены не считаем.
  final ValueListenable<bool> windowVisible;

  /// Как часто обновлять время и токены работающих сессий.
  final Duration tickInterval;

  ClaudeCodeEventServer? _server;
  Timer? _ticker;
  Future<void> _reading = Future.value();
  String _watchKey = '';
  bool _disposed = false;

  final sessions = ClaudeCodeSessions();

  /// Почему не удалось подключить или отключить события — видно в настройках.
  String? error;

  bool get connected => _server?.port != null;

  /// При запуске лаунчера: поднимает приём, если события включены.
  Future<void> start() async {
    if (settings.claudeCodeEvents) await _connect();
  }

  Future<void> setEnabled(bool enabled) async {
    await settings.setClaudeCodeEvents(enabled);
    if (enabled) {
      await _connect();
    } else {
      await _disconnect();
    }
  }

  Future<void> _connect() async {
    try {
      final server = _server ??= ClaudeCodeEventServer(
        token: settings.eventsToken,
        onEvent: _onEvent,
      );
      final port = await server.start(settings.eventsPort);
      if (port != settings.eventsPort) await settings.setEventsPort(port);
      final token = settings.eventsToken;
      // Обновление лаунчера с новыми событиями тоже переустановит хуки.
      if (!await hooks.isInstalled(port: port, token: token)) {
        await hooks.install(port: port, token: token);
      }
      error = null;
    } catch (e) {
      await _server?.stop();
      _server = null;
      error = 'Не удалось подключить события Claude Code: $e';
    }
    _notify();
  }

  Future<void> _disconnect() async {
    await _server?.stop();
    _server = null;
    _ticker?.cancel();
    _ticker = null;
    sessions.clear();
    try {
      await hooks.uninstall();
      error = null;
    } catch (e) {
      error = 'Не удалось убрать хуки из ~/.claude/settings.json: $e';
    }
    _notify();
  }

  /// Одновременно открыт один профиль — событие относится к нему.
  /// Состояние (и точка на свёрнутой карточке) меняется сразу, а переписку
  /// дочитываем, только если время и токены сейчас видны.
  Future<void> _onEvent(ClaudeCodeEvent event) async {
    final running = launcher.runningProfiles;
    if (running.length != 1) return;
    sessions.handle(event, running.single.id);
    _notify();
    await _refresh();
  }

  /// Время и токены видны, только когда окно открыто, а карточка профиля
  /// развёрнута. Переписку остальных сессий не читаем вовсе.
  bool _watched(CodeSession session) {
    if (!windowVisible.value) return false;
    for (final profile in launcher.profiles) {
      if (profile.id == session.profileId) return !profile.sessionsCollapsed;
    }
    return false;
  }

  void _onLauncherChanged() {
    _prune();
    _updateWatching();
  }

  /// Окно открыли или карточку развернули — сразу догоняем переписку;
  /// закрыли или свернули — перестаём обновлять.
  void _updateWatching() {
    final key = [
      windowVisible.value,
      for (final profile in launcher.profiles)
        if (!profile.sessionsCollapsed) profile.id,
    ].join(',');
    if (key == _watchKey) return;
    _watchKey = key;
    _refresh();
  }

  Future<void> _refresh() async {
    await _readWatched();
    _syncTicker();
    _notify();
  }

  /// По очереди: два чтения одного файла начали бы с одного места.
  Future<void> _readWatched() => _reading = _reading.then((_) async {
    try {
      await sessions.readTranscripts(where: _watched);
    } on FileSystemException catch (error) {
      debugPrint('Не удалось прочитать переписку Claude Code: $error');
    }
  });

  /// Тикаем раз в [tickInterval], пока есть видимая работающая сессия.
  void _syncTicker() {
    final needed =
        !_disposed &&
        sessions.all.any(
          (session) =>
              session.state == CodeSessionState.working && _watched(session),
        );
    if (!needed) {
      _ticker?.cancel();
      _ticker = null;
    } else {
      _ticker ??= Timer.periodic(tickInterval, (_) => _refresh());
    }
  }

  /// Сессии закрытого профиля и давно выполненные задачи убираем.
  void _prune() {
    final changed = sessions.prune(
      runningProfileIds: {
        for (final profile in launcher.runningProfiles) profile.id,
      },
      now: DateTime.now(),
    );
    if (changed) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    launcher.removeListener(_onLauncherChanged);
    windowVisible.removeListener(_updateWatching);
    _ticker?.cancel();
    _server?.stop();
    super.dispose();
  }
}
