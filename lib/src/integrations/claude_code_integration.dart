import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import 'claude_code_events.dart';
import 'claude_code_hooks.dart';

/// События Claude Code: подключение хуков и приём событий. Задел для
/// уведомлений в Telegram — сейчас последнее событие видно на карточке профиля.
class ClaudeCodeIntegration extends ChangeNotifier {
  ClaudeCodeIntegration({
    required this.settings,
    required this.launcher,
    ClaudeCodeHooks? hooks,
  }) : hooks = hooks ?? ClaudeCodeHooks.forCurrentUser();

  final AppSettings settings;
  final LauncherController launcher;
  final ClaudeCodeHooks hooks;

  ClaudeCodeEventServer? _server;

  /// Последнее событие для каждого профиля (по id).
  final Map<String, ClaudeCodeEvent> lastEvents = {};

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
    lastEvents.clear();
    try {
      await hooks.uninstall();
      error = null;
    } catch (e) {
      error = 'Не удалось убрать хуки из ~/.claude/settings.json: $e';
    }
    notifyListeners();
  }

  /// Одновременно открыт один профиль — событие относится к нему.
  void _onEvent(ClaudeCodeEvent event) {
    final running = launcher.runningProfiles;
    if (running.length != 1) return;
    lastEvents[running.single.id] = event;
    notifyListeners();
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }
}
