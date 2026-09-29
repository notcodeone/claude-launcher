import 'dart:async';

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
    this.tickInterval = const Duration(seconds: 2),
  }) : hooks = hooks ?? ClaudeCodeHooks.forCurrentUser() {
    launcher.addListener(_prune);
  }

  final AppSettings settings;
  final LauncherController launcher;
  final ClaudeCodeHooks hooks;

  /// Как часто дочитывать переписку работающих сессий (время и токены).
  final Duration tickInterval;

  ClaudeCodeEventServer? _server;
  Timer? _ticker;

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
    notifyListeners();
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
    notifyListeners();
  }

  /// Одновременно открыт один профиль — событие относится к нему.
  Future<void> _onEvent(ClaudeCodeEvent event) async {
    final running = launcher.runningProfiles;
    if (running.length != 1) return;
    sessions.handle(event, running.single.id);
    await sessions.readTranscripts();
    _ensureTicker();
    notifyListeners();
  }

  /// Пока Claude работает, раз в [tickInterval] обновляем время и токены.
  void _ensureTicker() {
    if (_ticker != null || !sessions.anyWorking) return;
    _ticker = Timer.periodic(tickInterval, (_) async {
      await sessions.readTranscripts();
      if (!sessions.anyWorking) {
        _ticker?.cancel();
        _ticker = null;
      }
      notifyListeners();
    });
  }

  /// Сессии закрытого профиля и давно выполненные задачи убираем.
  void _prune() {
    final changed = sessions.prune(
      runningProfileIds: {
        for (final profile in launcher.runningProfiles) profile.id,
      },
      now: DateTime.now(),
    );
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    launcher.removeListener(_prune);
    _ticker?.cancel();
    _server?.stop();
    super.dispose();
  }
}
