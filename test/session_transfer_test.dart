import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:claude_launcher/src/integrations/session_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const acc = '0a5308d1-efb5-463a-9e16-65f034f9f57f';
const org = 'f9318940-bb09-4fa1-a2e2-273952297901';
const otherAcc = '52d1dac1-c41a-44d6-ae9f-b382e13d501b';
const otherOrg = '180de3f2-1ddb-4192-a153-a24c9955281c';

void main() {
  late Directory root;
  late SessionTransfer transfer;
  late TransferSide work;
  late TransferSide home;

  String folder(String account, String organization) =>
      p.join('claude-code-sessions', account, organization);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('transfer');
    transfer = SessionTransfer(
      journalRoot: Directory(p.join(root.path, 'transfers')),
    );
    work = TransferSide(
      name: 'Рабочий',
      dataDirs: [p.join(root.path, 'Claude-Work')],
      claudeCodeDir: p.join(root.path, 'Claude-Work', 'claude-config'),
      identity: const ProfileIdentity(accountUuid: acc, orgUuid: org),
    );
    home = TransferSide(
      name: 'Личный',
      dataDirs: [p.join(root.path, 'Claude-Home')],
      claudeCodeDir: p.join(root.path, 'Claude-Home', 'claude-config'),
      identity: const ProfileIdentity(accountUuid: otherAcc, orgUuid: otherOrg),
    );
    final card = File(
      p.join(work.dataDirs.first, folder(acc, org), 'local_1.json'),
    );
    await card.parent.create(recursive: true);
    await card.writeAsString(
      jsonEncode({
        'sessionId': 'local_1',
        'cliSessionId': 'cli1',
        'cwd': '/code/app',
        'lastActivityAt': 1000,
        'title': 'Вход',
        'remoteMcpServersConfig': ['большое'],
        'alwaysAllowedReasons': ['Bash'],
      }),
    );
    final transcript = File(
      p.join(work.claudeCodeDir, 'projects', '-code-app', 'cli1.jsonl'),
    );
    await transcript.parent.create(recursive: true);
    await transcript.writeAsString('переписка');
    await File(
      p.join(work.claudeCodeDir, 'projects', '-code-app', 'cli1', 'a.jsonl'),
    ).create(recursive: true);
  });
  tearDown(() => root.delete(recursive: true));

  File homeCard() => File(
    p.join(home.dataDirs.first, folder(otherAcc, otherOrg), 'local_1.json'),
  );
  File workCard() =>
      File(p.join(work.dataDirs.first, folder(acc, org), 'local_1.json'));
  File homeTranscript() =>
      File(p.join(home.claudeCodeDir, 'projects', '-code-app', 'cli1.jsonl'));

  test(
    'копия: карточка под аккаунт цели, переписка и подагенты, без MCP',
    () async {
      await transfer.run(sessionId: 'local_1', source: work, target: home);
      final json = jsonDecode(await homeCard().readAsString()) as Map;
      expect(json['title'], 'Вход');
      expect(json.containsKey('remoteMcpServersConfig'), isFalse);
      expect(json['alwaysAllowedReasons'], isEmpty);
      expect(await homeTranscript().readAsString(), 'переписка');
      expect(
        File(
          p.join(
            home.claudeCodeDir,
            'projects',
            '-code-app',
            'cli1',
            'a.jsonl',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        workCard().existsSync(),
        isTrue,
        reason: 'копия — исходная на месте',
      );
    },
  );

  test('уже есть или удалена в цели — отказ', () async {
    await transfer.run(sessionId: 'local_1', source: work, target: home);
    await expectLater(
      transfer.run(sessionId: 'local_1', source: work, target: home),
      throwsA(isA<TransferRefused>()),
    );
    await homeCard().delete();
    await File(
      p.join(homeCard().parent.path, 'deleted_cli1'),
    ).writeAsString('1');
    await expectLater(
      transfer.run(sessionId: 'local_1', source: work, target: home),
      throwsA(
        isA<TransferRefused>().having(
          (e) => e.message,
          'message',
          contains('удалили'),
        ),
      ),
    );
  });

  test('аккаунт цели не определён — отказ, ничего не записано', () async {
    final unknown = TransferSide(
      name: 'Новый',
      dataDirs: [p.join(root.path, 'Claude-New')],
      claudeCodeDir: p.join(root.path, 'Claude-New', 'claude-config'),
      identity: ProfileIdentity.unknown,
    );
    await expectLater(
      transfer.run(sessionId: 'local_1', source: work, target: unknown),
      throwsA(isA<TransferRefused>()),
    );
    expect(Directory(p.join(root.path, 'Claude-New')).existsSync(), isFalse);
  });

  test(
    'перенос и отмена: карточка уходит и возвращается, копии убраны',
    () async {
      final record = await transfer.run(
        sessionId: 'local_1',
        source: work,
        target: home,
        mode: TransferMode.move,
      );
      expect(workCard().existsSync(), isFalse);
      expect(homeCard().existsSync(), isTrue);

      await transfer.undo(record);
      expect(workCard().existsSync(), isTrue);
      expect(homeCard().existsSync(), isFalse);
      expect(homeTranscript().existsSync(), isFalse);
    },
  );

  test('отмена после того, как сессию продолжили, — отказ', () async {
    final record = await transfer.run(
      sessionId: 'local_1',
      source: work,
      target: home,
    );
    await homeTranscript().writeAsString('переписка и новый ответ');
    await expectLater(transfer.undo(record), throwsA(isA<TransferRefused>()));
    expect(homeTranscript().existsSync(), isTrue);
  });

  test('общая папка Claude Code — переписку не копируем', () async {
    final shared = TransferSide(
      name: 'Личный',
      dataDirs: home.dataDirs,
      claudeCodeDir: work.claudeCodeDir,
      identity: home.identity,
    );
    final record = await transfer.run(
      sessionId: 'local_1',
      source: work,
      target: shared,
    );
    final manifest =
        jsonDecode(await record.manifest.readAsString())
            as Map<String, Object?>;
    expect((manifest['created'] as Map).keys.single, homeCard().path);
  });
}
