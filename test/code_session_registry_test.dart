import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/integrations/code_session_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  late CodeSessionRegistry registry;
  final now = DateTime.utc(2026, 10, 3);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_registry');
    file = File('${dir.path}/sessions.json');
    registry = CodeSessionRegistry(file);
  });
  tearDown(() => dir.delete(recursive: true));

  CodeSession session(String id) =>
      CodeSession(id: id, profileId: 'p', startedAt: now)
        ..hostSessionId = 'local_$id'
        ..cwd = '/private/project'
        ..transcriptPath = '/private/transcript.jsonl'
        ..message = 'private notification';

  test('round trip stores only identifiers and timestamps', () async {
    final value = session('s')..state = CodeSessionState.needsPermission;
    await registry.save([value], now: now);
    final saved = await registry.load(now: now);
    expect(saved.single.id, 's');
    expect(saved.single.profileId, 'p');
    final raw = await file.readAsString();
    expect(raw, isNot(contains('private')));
    expect(raw, isNot(contains('needsPermission')));
    final json = jsonDecode(raw) as Map;
    expect((json['sessions'] as List).single.keys.toSet(), {
      'sessionId',
      'hostSessionId',
      'profileId',
      'startedAt',
      'updatedAt',
    });
  });

  test('old references, future dates and duplicate IDs fail closed', () async {
    final value = session('s');
    await registry.save([value], now: now);
    expect(
      await registry.load(now: now.add(const Duration(hours: 1))),
      isEmpty,
    );
    expect(
      await registry.load(now: now.subtract(const Duration(seconds: 1))),
      isEmpty,
    );
    final json = jsonDecode(await file.readAsString()) as Map;
    (json['sessions'] as List).add(
      Map.from((json['sessions'] as List).single)..['profileId'] = 'other',
    );
    await file.writeAsString(jsonEncode(json));
    expect(await registry.load(now: now), isEmpty);
  });

  test('corrupt schema and oversized files report errors', () async {
    for (final raw in [
      '{',
      '{"version":2,"sessions":[]}',
      'x' * (CodeSessionRegistry.maxBytes + 1),
    ]) {
      await file.writeAsString(raw);
      await expectLater(registry.load(now: now), throwsFormatException);
    }
  });

  test(
    'write order makes explicit clear final and capacity is bounded',
    () async {
      final write = registry.save(
        List.generate(300, (i) => session('s$i')),
        now: now,
      );
      final clear = registry.save([], now: now);
      await Future.wait([write, clear]);
      expect(await registry.load(now: now), isEmpty);
      await registry.save(List.generate(300, (i) => session('s$i')), now: now);
      expect(
        await registry.load(now: now),
        hasLength(CodeSessionRegistry.capacity),
      );
    },
  );

  test('IO failure can be retried and temporary files are cleaned', () async {
    await Directory(file.path).create();
    await expectLater(
      registry.save([session('s')], now: now),
      throwsA(isA<FileSystemException>()),
    );
    await Directory(file.path).delete();
    await registry.save([session('s')], now: now);
    expect(await registry.load(now: now), hasLength(1));
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test('restored reference remains unknown until a fresh event', () {
    final sessions = ClaudeCodeSessions();
    sessions.restore(
      id: 's',
      hostSessionId: 'local_s',
      profileId: 'p',
      startedAt: now,
      updatedAt: now,
    );
    expect(sessions.byId('s')!.state, CodeSessionState.unknown);
    expect(sessions.anyWorking, isFalse);
    sessions.handle(
      ClaudeCodeEvent(
        kind: ClaudeCodeEventKind.toolUsed,
        time: now,
        sessionId: 's',
        hostSessionId: 'local_s',
      ),
      'p',
    );
    expect(sessions.byId('s')!.state, CodeSessionState.working);
  });

  test(
    'verified owner change replaces row instead of mutating another profile',
    () {
      final sessions = ClaudeCodeSessions();
      sessions.restore(
        id: 's',
        hostSessionId: 'local_s',
        profileId: 'p',
        startedAt: now,
        updatedAt: now,
      );
      sessions.handle(
        ClaudeCodeEvent(
          kind: ClaudeCodeEventKind.sessionEnded,
          time: now,
          sessionId: 's',
        ),
        'other',
      );
      // Восстановленная сессия на карточке не видна, но владелец прежний.
      expect(sessions.of('p'), isEmpty);
      expect(sessions.byId('s')?.profileId, 'p');
      sessions.handle(
        ClaudeCodeEvent(
          kind: ClaudeCodeEventKind.toolUsed,
          time: now,
          sessionId: 's',
        ),
        'other',
      );
      expect(sessions.of('p'), isEmpty);
      expect(sessions.of('other'), hasLength(1));
    },
  );

  test('восстановленная сессия не показывается до нового события', () {
    final sessions = ClaudeCodeSessions();
    sessions.restore(
      id: 's',
      hostSessionId: 'local_s',
      profileId: 'p',
      startedAt: now,
      updatedAt: now,
    );
    expect(sessions.of('p'), isEmpty);
    sessions.handle(
      ClaudeCodeEvent(
        kind: ClaudeCodeEventKind.promptSubmitted,
        time: now,
        sessionId: 's',
      ),
      'p',
    );
    expect(sessions.of('p').single.state, CodeSessionState.working);
  });
}
