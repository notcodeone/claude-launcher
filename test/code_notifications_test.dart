import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/integrations/code_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

ClaudeCodeEvent event(
  ClaudeCodeEventKind kind, {
  bool inApp = true,
  String message = '',
  String type = '',
}) => ClaudeCodeEvent(
  kind: kind,
  time: DateTime(2026),
  sessionId: 's1',
  hostSessionId: inApp ? 'local_1' : '',
  message: message,
  notificationType: type,
);

void main() {
  test('разрешение — с названием инструмента, если оно есть', () {
    expect(
      notificationBody(
        event(
          ClaudeCodeEventKind.needsPermission,
          message: 'Claude needs your permission to use Bash',
        ),
      ),
      'Нужно разрешение: Bash',
    );
    expect(
      notificationBody(
        event(ClaudeCodeEventKind.needsPermission, message: 'Something else'),
      ),
      'Нужно разрешение',
    );
  });

  test(
    'приложение: о готовой задаче — со временем, «ждёт ввода» следом — нет',
    () {
      expect(
        notificationBody(
          event(ClaudeCodeEventKind.finished),
          elapsed: const Duration(minutes: 2, seconds: 14),
        ),
        'Готово за 2 мин 14 с',
      );
      final idle = event(ClaudeCodeEventKind.needsAnswer, type: 'idle_prompt');
      expect(notificationBody(idle, before: CodeSessionState.done), isNull);
      expect(
        notificationBody(idle, before: CodeSessionState.working),
        isNotNull,
      );
      expect(
        notificationBody(
          event(ClaudeCodeEventKind.needsAnswer, type: 'elicitation_dialog'),
          before: CodeSessionState.done,
        ),
        'Ждёт ответа',
      );
    },
  );

  test(
    'терминал: как сам Claude Code — о завершении не сразу, а когда ждёт',
    () {
      expect(
        notificationBody(event(ClaudeCodeEventKind.finished, inApp: false)),
        isNull,
      );
      expect(
        notificationBody(
          event(
            ClaudeCodeEventKind.needsAnswer,
            inApp: false,
            type: 'idle_prompt',
          ),
          before: CodeSessionState.done,
        ),
        'Ждёт ответа',
      );
    },
  );

  test('сообщение посреди ожидания разрешения уведомление не убирает', () {
    final prompt = event(ClaudeCodeEventKind.promptSubmitted);
    expect(
      clearsNotification(prompt, after: CodeSessionState.needsPermission),
      isFalse,
    );
    expect(clearsNotification(prompt, after: CodeSessionState.working), isTrue);
  });

  test('вопрос с вариантами ответа — вопрос, а не разрешение', () {
    final json = {
      'hook_event_name': 'Notification',
      'notification_type': 'permission_prompt',
      'message': 'Claude needs your permission to use AskUserQuestion',
      'session_id': 's1',
    };
    final question = ClaudeCodeEvent.fromHookJson(json)!;
    expect(question.kind, ClaudeCodeEventKind.needsAnswer);
    expect(notificationBody(question), 'Задаёт вопрос');
    final bash = ClaudeCodeEvent.fromHookJson({
      ...json,
      'message': 'Claude needs your permission to use Bash',
    })!;
    expect(bash.kind, ClaudeCodeEventKind.needsPermission);
  });

  test('работа и закрытие сессии убирают уведомление', () {
    for (final kind in ClaudeCodeEventKind.values) {
      expect(
        clearsNotification(event(kind)),
        const {
          ClaudeCodeEventKind.promptSubmitted,
          ClaudeCodeEventKind.toolUsed,
          ClaudeCodeEventKind.sessionEnded,
        }.contains(kind),
        reason: '$kind',
      );
      if (clearsNotification(event(kind))) {
        expect(notificationBody(event(kind)), isNull, reason: '$kind');
      }
    }
  });
}
