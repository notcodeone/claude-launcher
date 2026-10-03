import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/pending_code_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026);
  ClaudeCodeEvent event(String id, ClaudeCodeEventKind kind) => ClaudeCodeEvent(
    kind: kind,
    time: now,
    sessionId: id,
    hostSessionId: 'local_$id',
  );
  test('replay preserves order and process ownership snapshot', () {
    final queue = PendingCodeEvents();
    final owners = {
      'a': {1},
      'b': {2},
    };
    queue.add(event('one', ClaudeCodeEventKind.promptSubmitted), owners, now);
    queue.add(event('one', ClaudeCodeEventKind.finished), owners, now);
    owners['a']!.add(3);
    final entries = queue.take('one', 'local_one');
    expect(entries.map((e) => e.event.kind), [
      ClaudeCodeEventKind.promptSubmitted,
      ClaudeCodeEventKind.finished,
    ]);
    expect(entries.first.accepts('a', {1}), isTrue);
    expect(entries.first.accepts('a', {3}), isFalse);
    expect(entries.first.accepts('c', {1}), isFalse);
    expect(queue.isEmpty, isTrue);
  });
  test('bounded lifetime, capacity and exact pair lookup', () {
    final queue = PendingCodeEvents(
      capacity: 2,
      lifetime: const Duration(seconds: 3),
    );
    for (final id in ['one', 'two', 'three']) {
      queue.add(event(id, ClaudeCodeEventKind.finished), {
        'a': {1},
      }, now);
    }
    expect(queue.entries.map((e) => e.event.sessionId), ['two', 'three']);
    expect(queue.take('two', 'local_other'), isEmpty);
    queue.expire(now.add(const Duration(seconds: 3)));
    expect(queue.isEmpty, isTrue);
  });
  test(
    'terminal events and events without running owners are not retained',
    () {
      final queue = PendingCodeEvents();
      queue.add(
        ClaudeCodeEvent(
          kind: ClaudeCodeEventKind.finished,
          time: now,
          sessionId: 'terminal',
        ),
        {
          'a': {1},
        },
        now,
      );
      queue.add(event('one', ClaudeCodeEventKind.finished), {}, now);
      expect(queue.isEmpty, isTrue);
    },
  );
}
