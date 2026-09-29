import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'claude_code_hooks.dart';

enum ClaudeCodeEventKind {
  /// Claude закончил ответ (`Stop`).
  finished,

  /// Claude ждёт разрешения (`Notification` с `permission_prompt`).
  needsPermission,

  /// Claude ждёт ввода (остальные `Notification`).
  waiting,
}

/// Событие Claude Code, пришедшее от хука.
class ClaudeCodeEvent {
  const ClaudeCodeEvent({
    required this.kind,
    required this.time,
    this.message = '',
    this.cwd = '',
  });

  /// Разбор тела запроса хука; поля — по документации хуков Claude Code.
  static ClaudeCodeEvent? fromHookJson(
    Map<String, Object?> json, {
    DateTime? time,
  }) {
    final kind = switch ((json['hook_event_name'], json['notification_type'])) {
      ('Stop', _) => ClaudeCodeEventKind.finished,
      ('Notification', 'permission_prompt') =>
        ClaudeCodeEventKind.needsPermission,
      ('Notification', _) => ClaudeCodeEventKind.waiting,
      _ => null,
    };
    if (kind == null) return null;
    return ClaudeCodeEvent(
      kind: kind,
      time: time ?? DateTime.now(),
      // Текст ответа (`last_assistant_message`) не сохраняем: там может быть код.
      message: json['message'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
    );
  }

  final ClaudeCodeEventKind kind;
  final DateTime time;

  /// Текст уведомления Claude Code (для `Notification`).
  final String message;

  /// Папка проекта сессии.
  final String cwd;
}

/// Локальный приёмник событий: слушает только 127.0.0.1 и принимает только
/// запросы с ключом лаунчера.
class ClaudeCodeEventServer {
  ClaudeCodeEventServer({required this.token, required this.onEvent});

  static const tokenHeader = 'X-Claude-Launcher-Token';

  final String token;
  final void Function(ClaudeCodeEvent event) onEvent;

  HttpServer? _server;

  int? get port => _server?.port;

  /// Занимает [preferredPort], а если он занят — один из следующих.
  Future<int> start(int preferredPort) async {
    await stop();
    SocketException? lastError;
    for (var port = preferredPort; port < preferredPort + 20; port++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        server.listen(_handle);
        _server = server;
        return server.port;
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw lastError!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'POST' ||
          !request.uri.path.startsWith(ClaudeCodeHooks.marker) ||
          request.headers.value(tokenHeader) != token) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final json = jsonDecode(await utf8.decoder.bind(request).join());
      if (json is Map<String, Object?>) {
        final event = ClaudeCodeEvent.fromHookJson(json);
        if (event != null) onEvent(event);
      }
      // Пустое тело и 200: для Claude Code это «хук отработал успешно».
      // Любой текст в ответе он посчитал бы ошибкой хука.
      response.statusCode = HttpStatus.ok;
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } finally {
      await response.close();
    }
  }
}
