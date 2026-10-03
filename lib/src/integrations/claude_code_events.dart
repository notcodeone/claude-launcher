import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'claude_code_hooks.dart';

enum ClaudeCodeEventKind {
  /// Отправлена задача (`UserPromptSubmit`).
  promptSubmitted,

  /// Отработал инструмент (`PostToolUse`) — значит, Claude работает.
  toolUsed,

  /// Claude ждёт разрешения (`Notification` с `permission_prompt`).
  needsPermission,

  /// Claude ждёт ответа (`Notification` с `idle_prompt` или вопросом).
  needsAnswer,

  /// Claude закончил ответ (`Stop`).
  finished,

  /// Сессию закрыли (`SessionEnd`).
  sessionEnded,
}

/// Событие Claude Code, пришедшее от хука.
class ClaudeCodeEvent {
  const ClaudeCodeEvent({
    required this.kind,
    required this.time,
    this.sessionId = '',
    this.hostSessionId = '',
    this.transcriptPath = '',
    this.message = '',
    this.notificationType = '',
    this.cwd = '',
    this.profileId = '',
  });

  /// Разбор тела запроса хука; поля — по документации хуков Claude Code.
  static ClaudeCodeEvent? fromHookJson(
    Map<String, Object?> json, {
    String hostSessionId = '',
    String profileId = '',
    DateTime? time,
  }) {
    final kind = switch ((json['hook_event_name'], json['notification_type'])) {
      ('UserPromptSubmit', _) => ClaudeCodeEventKind.promptSubmitted,
      ('PostToolUse', _) => ClaudeCodeEventKind.toolUsed,
      // Вопрос с вариантами ответа приходит как разрешение на AskUserQuestion.
      ('Notification', 'permission_prompt')
          when '${json['message']}'.contains('AskUserQuestion') =>
        ClaudeCodeEventKind.needsAnswer,
      ('Notification', 'permission_prompt') =>
        ClaudeCodeEventKind.needsPermission,
      ('Notification', 'idle_prompt' || 'elicitation_dialog') =>
        ClaudeCodeEventKind.needsAnswer,
      ('Stop', _) => ClaudeCodeEventKind.finished,
      ('SessionEnd', _) => ClaudeCodeEventKind.sessionEnded,
      // Прочие уведомления (auth_success и т.п.) ни о чём не просят.
      _ => null,
    };
    if (kind == null) return null;
    return ClaudeCodeEvent(
      kind: kind,
      time: time ?? DateTime.now(),
      sessionId: json['session_id'] as String? ?? '',
      hostSessionId: hostSessionId,
      transcriptPath: json['transcript_path'] as String? ?? '',
      // Текст запроса и ответа не сохраняем: там может быть код.
      message: json['message'] as String? ?? '',
      notificationType: json['notification_type'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      profileId: profileId,
    );
  }

  final ClaudeCodeEventKind kind;
  final DateTime time;

  /// Сессия Claude Code (как в имени файла переписки).
  final String sessionId;

  /// Сессия в приложении Claude (`local_…`); пусто для терминала.
  final String hostSessionId;

  /// Файл переписки — из него берутся название сессии и токены.
  final String transcriptPath;

  /// Текст уведомления Claude Code (для ожидания).
  final String message;

  /// Вид уведомления Claude Code (`permission_prompt`, `idle_prompt`, …).
  final String notificationType;

  /// Папка проекта сессии.
  final String cwd;

  /// Профиль из адреса хука — у профилей со своей папкой Claude Code; пусто —
  /// хук общей `~/.claude`.
  final String profileId;
}

/// Локальный приёмник событий: слушает только 127.0.0.1 и принимает только
/// запросы с ключом лаунчера.
class ClaudeCodeEventServer {
  ClaudeCodeEventServer({required this.token, required this.onEvent});

  static const tokenHeader = ClaudeCodeHooks.tokenHeader;

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
        final event = ClaudeCodeEvent.fromHookJson(
          json,
          hostSessionId:
              request.headers.value(ClaudeCodeHooks.hostSessionHeader) ?? '',
          profileId:
              request.uri.queryParameters[ClaudeCodeHooks.profileQuery] ?? '',
        );
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
