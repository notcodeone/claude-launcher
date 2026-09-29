import '../ui/code_sessions_view.dart' show formatElapsed;
import 'claude_code_events.dart';
import 'claude_code_sessions.dart';

/// Уведомление о сессии одно: новое заменяет прежнее.
int notificationIdOf(String sessionId) => sessionId.hashCode & 0x7fffffff;

/// Пользователь уже ответил или сессию закрыли — уведомление о ней не нужно.
/// [after] — состояние сессии после события, если лаунчер её ведёт: сообщение
/// посреди ожидания разрешения само разрешение не даёт.
bool clearsNotification(ClaudeCodeEvent event, {CodeSessionState? after}) =>
    switch (event.kind) {
      ClaudeCodeEventKind.sessionEnded => true,
      ClaudeCodeEventKind.promptSubmitted || ClaudeCodeEventKind.toolUsed =>
        after == null || after == CodeSessionState.working,
      _ => false,
    };

/// Текст уведомления по событию; `null` — не уведомлять. Как сами Claude:
/// приложение сообщает о разрешении, вопросе и завершении задачи, а Claude Code
/// в терминале — о разрешении и о том, что давно ждёт ввода (о завершении
/// сразу он не сообщает). [before] — состояние сессии до события, [elapsed] —
/// сколько шла задача.
String? notificationBody(
  ClaudeCodeEvent event, {
  CodeSessionState? before,
  Duration? elapsed,
}) {
  final inApp = event.hostSessionId.isNotEmpty;
  return switch (event.kind) {
    ClaudeCodeEventKind.needsPermission => _permissionText(event.message),
    // О завершении уже сообщили — «ждёт ввода» следом не повторяем.
    ClaudeCodeEventKind.needsAnswer
        when inApp &&
            event.notificationType == 'idle_prompt' &&
            before == CodeSessionState.done =>
      null,
    ClaudeCodeEventKind.needsAnswer
        when event.notificationType == 'permission_prompt' =>
      'Задаёт вопрос',
    ClaudeCodeEventKind.needsAnswer => 'Ждёт ответа',
    ClaudeCodeEventKind.finished when inApp =>
      elapsed == null ? 'Готово' : 'Готово за ${formatElapsed(elapsed)}',
    _ => null,
  };
}

/// «Claude needs your permission to use Bash» → «Нужно разрешение: Bash».
String _permissionText(String message) {
  final tool = RegExp(
    r'permission to use (.+?)\.?$',
  ).firstMatch(message.trim())?.group(1);
  return tool == null ? 'Нужно разрешение' : 'Нужно разрешение: $tool';
}
