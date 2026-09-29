import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/ui/code_sessions_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File transcript;
  late ClaudeCodeSessions sessions;
  final start = DateTime(2026, 9, 29, 14);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_launcher_sessions');
    transcript = File('${dir.path}/s1.jsonl');
    sessions = ClaudeCodeSessions();
  });
  tearDown(() => dir.delete(recursive: true));

  void event(
    ClaudeCodeEventKind kind, {
    String session = 's1',
    int minute = 0,
    String message = '',
    String profile = 'work',
  }) => sessions.handle(
    ClaudeCodeEvent(
      kind: kind,
      time: start.add(Duration(minutes: minute)),
      sessionId: session,
      transcriptPath: session == 's1' ? transcript.path : '',
      cwd: '/Users/me/parking-server',
      message: message,
    ),
    profile,
  );

  void write(List<Map<String, Object?>> lines, {bool finished = true}) {
    final text = lines.map(jsonEncode).join('\n');
    transcript.writeAsStringSync(
      finished ? '$text\n' : text,
      mode: FileMode.append,
    );
  }

  /// Строка ответа, как её пишет Claude Code: один блок на строку. В расходе
  /// много токенов — там и скрытые рассуждения, которых в переписке нет.
  var nextUuid = 0;
  Map<String, Object?> answer(
    Map<String, Object?> block, {
    String? uuid,
    bool sidechain = false,
  }) => {
    'type': 'assistant',
    'uuid': uuid ?? 'u${nextUuid++}',
    'isSidechain': sidechain,
    'message': {
      'id': 'msg',
      'content': [block],
      'usage': {'input_tokens': 3, 'output_tokens': 5000},
    },
  };
  Map<String, Object?> text(int chars) => {'type': 'text', 'text': 'я' * chars};

  CodeSession only() => sessions.of('work').single;

  group('состояния', () {
    test('работает → ожидает → работает → готово', () {
      event(ClaudeCodeEventKind.promptSubmitted);
      expect(only().state, CodeSessionState.working);

      event(
        ClaudeCodeEventKind.needsPermission,
        minute: 1,
        message: 'Claude needs your permission to use Bash',
      );
      expect(only().state, CodeSessionState.needsPermission);
      expect(only().message, contains('Bash'));

      // Разрешили — та же задача продолжается, время не сбрасывается.
      event(ClaudeCodeEventKind.toolUsed, minute: 2);
      expect(only().state, CodeSessionState.working);
      expect(only().startedAt, start);
      expect(only().message, isEmpty);

      event(ClaudeCodeEventKind.needsAnswer, minute: 3);
      expect(only().state, CodeSessionState.needsAnswer);

      event(ClaudeCodeEventKind.finished, minute: 4);
      expect(only().state, CodeSessionState.done);
      expect(only().updatedAt, start.add(const Duration(minutes: 4)));
    });

    test('работа после «Готово» — новая задача', () {
      event(ClaudeCodeEventKind.promptSubmitted);
      event(ClaudeCodeEventKind.finished, minute: 1);
      event(ClaudeCodeEventKind.toolUsed, minute: 5);
      expect(only().state, CodeSessionState.working);
      expect(only().startedAt, start.add(const Duration(minutes: 5)));
    });

    test('закрытая сессия исчезает', () {
      event(ClaudeCodeEventKind.promptSubmitted);
      event(ClaudeCodeEventKind.sessionEnded, minute: 1);
      expect(sessions.of('work'), isEmpty);
    });

    test('событие без сессии не учитывается', () {
      event(ClaudeCodeEventKind.promptSubmitted, session: '');
      expect(sessions.isEmpty, isTrue);
    });

    test('последние сверху, у каждого профиля — свои', () {
      event(ClaudeCodeEventKind.promptSubmitted, session: 'a');
      event(ClaudeCodeEventKind.promptSubmitted, session: 'b', minute: 2);
      event(ClaudeCodeEventKind.finished, session: 'a', minute: 3);
      event(ClaudeCodeEventKind.promptSubmitted, session: 'c', profile: 'home');
      expect(sessions.of('work').map((s) => s.id), ['a', 'b']);
      expect(sessions.of('home').map((s) => s.id), ['c']);
      expect(sessions.anyWorking, isTrue);
    });
  });

  group('переписка', () {
    test(
      'токены — как в Claude Code: длина ответа / 4, только текущей задачи',
      () async {
        write([answer(text(4000))]); // прошлая задача, до знакомства с сессией
        event(ClaudeCodeEventKind.promptSubmitted);
        write([
          answer({'type': 'thinking', 'thinking': '', 'signature': 'скрыто'}),
          answer(text(40), uuid: 'text'),
          // {"command":"ls -la"} — 20 символов.
          answer({
            'type': 'tool_use',
            'name': 'Bash',
            'input': {'command': 'ls -la'},
          }),
          answer(text(400), sidechain: true), // субагент
        ]);
        await sessions.readTranscripts();
        expect(only().tokens, 15);

        // Недописанная строка ждёт конца; перезаписанная не считается дважды.
        write([answer(text(40), uuid: 'text')], finished: false);
        await sessions.readTranscripts();
        expect(only().tokens, 15);
        transcript.writeAsStringSync('\n', mode: FileMode.append);
        await sessions.readTranscripts();
        expect(only().tokens, 15);
        write([answer(text(200))]);
        await sessions.readTranscripts();
        expect(only().tokens, 65);

        // Новая задача считается с нуля.
        event(ClaudeCodeEventKind.finished, minute: 9);
        event(ClaudeCodeEventKind.promptSubmitted, minute: 10);
        write([answer(text(28))]);
        await sessions.readTranscripts();
        expect(only().tokens, 7);
      },
    );

    test(
      'сообщение посреди работы задачу не начинает: время и токены идут дальше',
      () async {
        event(ClaudeCodeEventKind.promptSubmitted);
        write([answer(text(400))]);
        await sessions.readTranscripts();
        expect(only().tokens, 100);

        // Так приходят и своя дописка, и отчёт фонового агента: хук срабатывает,
        // а в переписку сообщение попадает вложением, не сообщением пользователя.
        event(ClaudeCodeEventKind.promptSubmitted, minute: 5);
        write([
          {'type': 'queue-operation', 'operation': 'remove'},
          {
            'type': 'attachment',
            'attachment': {'type': 'queued_command', 'prompt': 'и ещё вот что'},
          },
          answer(text(40)),
        ]);
        await sessions.readTranscripts();
        expect(only().startedAt, start);
        expect(only().tokens, 110);
        expect(only().state, CodeSessionState.working);

        // Посреди ожидания разрешения — тоже, и разрешение всё ещё ждут.
        event(
          ClaudeCodeEventKind.needsPermission,
          minute: 6,
          message: 'Claude needs your permission to use Bash',
        );
        event(ClaudeCodeEventKind.promptSubmitted, minute: 7);
        expect(only().startedAt, start);
        expect(only().state, CodeSessionState.needsPermission);
        expect(only().message, contains('Bash'));
      },
    );

    test('после прерывания новую задачу видно по переписке', () async {
      event(ClaudeCodeEventKind.promptSubmitted);
      write([answer(text(400))]);
      await sessions.readTranscripts();

      // Прервали — Stop не приходит; следом новая задача.
      write([
        {
          'type': 'user',
          'timestamp': '2026-09-29T11:04:00.000Z',
          'message': {
            'content': [
              {'type': 'text', 'text': '[Request interrupted by user]'},
            ],
          },
        },
      ]);
      await sessions.readTranscripts();
      expect(only().startedAt, start, reason: 'прерывание — не новая задача');
      expect(only().tokens, 100);

      event(ClaudeCodeEventKind.promptSubmitted, minute: 5);
      write([
        {
          'type': 'user',
          'timestamp': '2026-09-29T11:05:00.000Z',
          'origin': {'kind': 'human'},
          'message': {'content': 'сделай иначе'},
        },
        answer(text(40)),
      ]);
      await sessions.readTranscripts();
      expect(only().startedAt, DateTime.utc(2026, 9, 29, 11, 5).toLocal());
      expect(only().tokens, 10);
    });

    test('пересказ после сжатия контекста — не новая задача', () async {
      event(ClaudeCodeEventKind.promptSubmitted);
      write([
        answer(text(400)),
        {
          'type': 'user',
          'isCompactSummary': true,
          'timestamp': '2026-09-29T11:05:00.000Z',
          'message': {'content': 'This session is being continued…'},
        },
        answer(text(40)),
      ]);
      await sessions.readTranscripts();
      expect(only().startedAt, start);
      expect(only().tokens, 110);
    });

    test(
      'знакомство посреди задачи: начало — последнее сообщение пользователя',
      () async {
        Map<String, Object?> user(Object content, {String? at}) => {
          'type': 'user',
          'uuid': 'u${nextUuid++}',
          'timestamp': ?at,
          'message': {'role': 'user', 'content': content},
        };
        write([
          user('прошлая задача', at: '2026-09-29T10:00:00.000Z'),
          answer(text(4000)),
          user([
            {'type': 'image'},
            {'type': 'text', 'text': 'текущая задача'},
          ], at: '2026-09-29T11:58:30.000Z'),
          answer(text(40)),
          // Не начало задачи: ответ инструмента и сообщение во время работы.
          user([
            {'type': 'tool_result', 'content': 'вывод'},
          ], at: '2026-09-29T11:59:00.000Z'),
          {'type': 'queue-operation', 'operation': 'enqueue', 'content': 'ещё'},
          {
            'type': 'attachment',
            'attachment': {'type': 'queued_command'},
          },
          answer(text(20)),
        ]);
        // Лаунчер перезапустили: первое событие — посреди работы.
        event(ClaudeCodeEventKind.toolUsed, minute: 5);
        await sessions.readTranscripts();
        expect(only().startedAt.toUtc(), DateTime.utc(2026, 9, 29, 11, 58, 30));
        expect(only().tokens, 15);

        // Дальше — как обычно.
        write([answer(text(40))]);
        await sessions.readTranscripts();
        expect(only().tokens, 25);
      },
    );

    test('новая задача не ищет начало в прошлом', () async {
      write([
        {
          'type': 'user',
          'timestamp': '2026-09-29T10:00:00.000Z',
          'message': {'content': 'прошлая задача'},
        },
        answer(text(400)),
      ]);
      event(ClaudeCodeEventKind.promptSubmitted);
      await sessions.readTranscripts();
      expect(only().startedAt, start);
      expect(only().tokens, 0);
    });

    test('название: своё, иначе от Claude, иначе папка проекта', () async {
      event(ClaudeCodeEventKind.promptSubmitted);
      expect(only().name, 'parking-server');

      write([
        {'type': 'ai-title', 'aiTitle': 'Настройка сервера'},
      ]);
      await sessions.readTranscripts();
      expect(only().name, 'Настройка сервера');

      write([
        {'type': 'custom-title', 'customTitle': 'Парковка'},
        {'type': 'ai-title', 'aiTitle': 'Другое'},
      ]);
      await sessions.readTranscripts();
      expect(only().name, 'Парковка');
    });

    test('название уже есть в файле до знакомства с сессией', () async {
      write([
        {'type': 'custom-title', 'customTitle': 'Парковка'},
        {'type': 'user', 'message': 'не json-объект — не страшно'},
      ]);
      transcript.writeAsStringSync('{ битая строка\n', mode: FileMode.append);
      event(ClaudeCodeEventKind.toolUsed);
      await sessions.readTranscripts();
      expect(only().name, 'Парковка');
      expect(only().tokens, 0);
    });
  });

  test('ссылка — только на сессии приложения Claude', () {
    ClaudeCodeEvent from(String session, String host) => ClaudeCodeEvent(
      kind: ClaudeCodeEventKind.promptSubmitted,
      time: start,
      sessionId: session,
      hostSessionId: host,
    );
    sessions
      ..handle(
        from('app', 'local_d1f7d51d-ea2a-415c-a8a6-108bdc6f7492'),
        'work',
      )
      ..handle(from('terminal', ''), 'work')
      // Если переменной нет, заголовок может прийти неподставленным.
      ..handle(from('odd', r'$CLAUDE_CODE_HOST_SESSION_ID'), 'work');
    final links = {
      for (final session in sessions.of('work')) session.id: session.link,
    };
    expect(
      links['app'],
      Uri.parse(
        'claude://claude.ai/epitaxy/local_d1f7d51d-ea2a-415c-a8a6-108bdc6f7492',
      ),
    );
    expect(links['terminal'], isNull);
    expect(links['odd'], isNull);
  });

  test('уборка: закрытые профили и давно готовые задачи', () {
    event(ClaudeCodeEventKind.promptSubmitted, session: 'working');
    event(ClaudeCodeEventKind.finished, session: 'done');
    event(ClaudeCodeEventKind.finished, session: 'fresh', minute: 50);
    event(
      ClaudeCodeEventKind.promptSubmitted,
      session: 'home',
      profile: 'home',
    );

    final changed = sessions.prune(
      runningProfileIds: {'work'},
      now: start.add(const Duration(minutes: 70)),
    );
    expect(changed, isTrue);
    expect(sessions.of('work').map((s) => s.id), ['fresh', 'working']);
    expect(sessions.of('home'), isEmpty);
    expect(
      sessions.prune(
        runningProfileIds: {'work'},
        now: start.add(const Duration(minutes: 70)),
      ),
      isFalse,
    );
  });

  group('подписи', () {
    test('время работы', () {
      expect(formatElapsed(const Duration(seconds: 12)), '12 с');
      expect(
        formatElapsed(const Duration(minutes: 2, seconds: 59)),
        '2 мин 59 с',
      );
      expect(formatElapsed(const Duration(minutes: 3)), '3 мин 0 с');
      expect(formatElapsed(const Duration(hours: 1, minutes: 5)), '1 ч 5 мин');
      expect(formatElapsed(const Duration(hours: 2)), '2 ч');
      expect(formatElapsed(const Duration(seconds: -1)), '0 с');
    });

    test('токены', () {
      expect(formatTokens(1), '1 токен');
      expect(formatTokens(3), '3 токена');
      expect(formatTokens(11), '11 токенов');
      expect(formatTokens(22), '22 токена');
      expect(formatTokens(850), '850 токенов');
      expect(formatTokens(1000), '1 тыс. токенов');
      expect(formatTokens(3142), '3,1 тыс. токенов');
      expect(formatTokens(9960), '10 тыс. токенов');
      expect(formatTokens(125400), '125 тыс. токенов');
      expect(formatTokens(999600), '1 млн токенов');
      expect(formatTokens(1260000), '1,3 млн токенов');
    });
  });
}
