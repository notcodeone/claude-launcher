import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/code_profile_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Map<String, List<String>> roots;
  const resolver = CodeProfileResolver();
  final event = ClaudeCodeEvent(
    kind: ClaudeCodeEventKind.toolUsed,
    time: DateTime(2026),
    hostSessionId: 'local_host',
    sessionId: 'cli-id',
  );

  Future<File> record(
    String profile, {
    String cli = 'cli-id',
    String host = 'local_host',
  }) async {
    final file = File(
      '${roots[profile]!.first}/claude-code-sessions/account/org/local_host.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'sessionId': host, 'cliSessionId': cli}),
    );
    return file;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('code-owner');
    roots = {
      'a': ['${temp.path}/A'],
      'b': ['${temp.path}/B'],
    };
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'matches both IDs in the correct profile, not the working directory',
    () async {
      await record('b');
      expect(await resolver.resolve(event, roots), 'b');
      await record('a', cli: 'other-cli');
      expect(await resolver.resolve(event, roots), 'b');
    },
  );
  test(
    'copied records across profiles are ambiguous, including closed profiles',
    () async {
      await record('a');
      await record('b');
      expect(await resolver.resolve(event, roots), isNull);
    },
  );
  test(
    'MSIX alternatives within one profile are not separate owners',
    () async {
      await record('a');
      roots['a']!.add(roots['a']!.first);
      expect(await resolver.resolve(event, roots), 'a');
    },
  );
  test('no record, mismatched host or malformed record fails closed', () async {
    expect(await resolver.resolve(event, roots), isNull);
    final file = await record('a', host: 'local_other');
    expect(await resolver.resolve(event, roots), isNull);
    await file.writeAsString('{');
    await record('b');
    expect(await resolver.resolve(event, roots), isNull);
  });
  test(
    'symlink to another profile is never treated as proof of ownership',
    () async {
      final file = await record('a');
      final other = File(
        '${roots['b']!.first}/claude-code-sessions/account/org/local_host.json',
      );
      await other.parent.create(recursive: true);
      await Link(other.path).create(file.path);
      expect(await resolver.resolve(event, roots), isNull);
    },
  );
  test('terminal and path traversal host IDs do not resolve', () async {
    await record('a');
    for (final id in ['', '../local_host', 'local_../../x', 'local_a/b']) {
      expect(
        await resolver.resolve(
          ClaudeCodeEvent(
            kind: event.kind,
            time: event.time,
            hostSessionId: id,
            sessionId: 'cli-id',
          ),
          roots,
        ),
        isNull,
      );
    }
  });
}
