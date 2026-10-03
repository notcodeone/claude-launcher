import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_claude_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String shared;
  late String dir;
  late ProfileClaudeCode home;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('profile_claude_code');
    shared = p.join(root.path, '.claude');
    dir = p.join(root.path, 'Claude-Work', ProfileClaudeCode.folder);
    home = ProfileClaudeCode(dir: dir, shared: shared);
  });
  tearDown(() => root.delete(recursive: true));

  File sharedFile(String path) => File(p.join(shared, path));
  File own(String path) => File(p.join(dir, path));

  Future<void> write(File file, String text) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  test('общий CLAUDE.md — импортом, один раз', () async {
    await home.prepare();
    expect(own('CLAUDE.md').existsSync(), isFalse, reason: 'общего нет');

    await write(sharedFile('CLAUDE.md'), 'общие правила');
    await home.prepare();
    expect(
      own('CLAUDE.md').readAsStringSync(),
      '@${sharedFile('CLAUDE.md').absolute.path}\n',
    );

    await own('CLAUDE.md').writeAsString('своё');
    await home.prepare();
    expect(own('CLAUDE.md').readAsStringSync(), 'своё');
  });

  test('агенты, команды и навыки копируются и обновляются', () async {
    await write(sharedFile('agents/review.md'), 'v1');
    await write(sharedFile('skills/pdf/SKILL.md'), 'skill');
    await write(sharedFile('projects/x/memory/m.md'), 'память');
    await home.prepare();
    expect(own('agents/review.md').readAsStringSync(), 'v1');
    expect(own('skills/pdf/SKILL.md').readAsStringSync(), 'skill');
    expect(own('projects/x/memory/m.md').existsSync(), isFalse);

    await write(sharedFile('agents/review.md'), 'v2');
    await home.prepare();
    expect(own('agents/review.md').readAsStringSync(), 'v2');
  });

  test('изменённое в профиле не перезаписывается', () async {
    await write(sharedFile('commands/a.md'), 'общее');
    await home.prepare();
    await own('commands/a.md').writeAsString('своё');
    await write(sharedFile('commands/a.md'), 'общее 2');
    await home.prepare();
    expect(own('commands/a.md').readAsStringSync(), 'своё');

    // Свой файл с тем же именем, которого лаунчер не копировал, — тоже.
    await write(own('agents/b.md'), 'свой');
    await write(sharedFile('agents/b.md'), 'общий');
    await home.prepare();
    expect(own('agents/b.md').readAsStringSync(), 'свой');
  });

  test(
    'удалённое в профиле не возвращается, удалённое в общей — убирается',
    () async {
      await write(sharedFile('agents/a.md'), 'a');
      await write(sharedFile('agents/b.md'), 'b');
      await home.prepare();

      await own('agents/a.md').delete();
      await sharedFile('agents/b.md').delete();
      await home.prepare();
      expect(own('agents/a.md').existsSync(), isFalse);
      expect(own('agents/b.md').existsSync(), isFalse);
    },
  );

  test(
    'перенос: переписка сессий профиля и память выбранных проектов',
    () async {
      final data = p.join(root.path, 'Claude-Work');
      Future<void> card(String name, String id, String cwd) => write(
        File(p.join(data, 'claude-code-sessions', 'acc', 'org', name)),
        '{"sessionId":"$name","cliSessionId":"$id","cwd":"$cwd"}',
      );
      await card('local_1.json', 's1', '/code/app');
      await card('local_2.json', 's2', '/code/site');
      await write(
        File(
          p.join(data, 'claude-code-sessions', 'acc', 'org', 'local_bad.json'),
        ),
        '{',
      );
      await write(sharedFile('projects/-code-app/s1.jsonl'), 'app');
      await write(sharedFile('projects/-code-app/s1/agent.jsonl'), 'sub');
      await write(
        sharedFile('projects/-code-app/memory/MEMORY.md'),
        'память app',
      );
      await write(sharedFile('projects/-code-site/s2.jsonl'), 'site');
      await write(
        sharedFile('projects/-code-site/memory/MEMORY.md'),
        'память site',
      );
      await write(sharedFile('projects/-code-other/x.jsonl'), 'чужая');

      final migration = ClaudeCodeMigration(
        shared: shared,
        dir: dir,
        dataDirs: [data],
      );
      final plan = await migration.plan();
      expect(plan.transcripts, [
        p.join('projects', '-code-app', 's1.jsonl'),
        p.join('projects', '-code-site', 's2.jsonl'),
      ]);
      expect(
        [for (final project in plan.projects) project.cwd],
        ['/code/app', '/code/site'],
      );

      final copied = await migration.apply(plan, memoryOf: {'-code-app'});
      expect(copied, 4);
      expect(own('projects/-code-app/s1.jsonl').readAsStringSync(), 'app');
      expect(own('projects/-code-app/s1/agent.jsonl').existsSync(), isTrue);
      expect(own('projects/-code-app/memory/MEMORY.md').existsSync(), isTrue);
      expect(own('projects/-code-site/memory/MEMORY.md').existsSync(), isFalse);
      expect(own('projects/-code-other/x.jsonl').existsSync(), isFalse);
      expect(sharedFile('projects/-code-app/s1.jsonl').existsSync(), isTrue);

      // Повторно — ничего не перезаписывает.
      await own('projects/-code-app/s1.jsonl').writeAsString('продолжили');
      expect(await migration.apply(plan, memoryOf: {'-code-app'}), 0);
      expect(
        own('projects/-code-app/s1.jsonl').readAsStringSync(),
        'продолжили',
      );
    },
  );
}
