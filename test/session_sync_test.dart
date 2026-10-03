import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:claude_launcher/src/integrations/session_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const acc = '0a5308d1-efb5-463a-9e16-65f034f9f57f';
const org = 'f9318940-bb09-4fa1-a2e2-273952297901';

void main() {
  late Directory root;
  late SessionSync sync;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync');
    sync = SessionSync(
      transfer: SessionTransfer(
        journalRoot: Directory(p.join(root.path, 'transfers')),
      ),
      stateFile: File(p.join(root.path, 'sync-state.json')),
    );
  });
  tearDown(() => root.delete(recursive: true));

  SyncMember member(String name, {bool running = false}) => SyncMember(
    id: name,
    running: running,
    side: TransferSide(
      name: name,
      dataDirs: [p.join(root.path, name)],
      claudeCodeDir: p.join(root.path, name, 'claude-config'),
      identity: const ProfileIdentity(accountUuid: acc, orgUuid: org),
    ),
  );

  File card(String profile, String id) => File(
    p.join(root.path, profile, 'claude-code-sessions', acc, org, '$id.json'),
  );

  Future<void> write(
    String profile,
    String id,
    int at, {
    String title = '',
  }) async {
    final file = card(profile, id);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'sessionId': id,
        'cliSessionId': 'cli-$id',
        'cwd': '/code/app',
        'lastActivityAt': at,
        'title': title,
      }),
    );
  }

  Future<String> title(String profile, String id) async =>
      (jsonDecode(await card(profile, id).readAsString()) as Map)['title']
          as String;

  test('недостающее копируется, старое обновляется свежим', () async {
    await write('A', 'local_1', 1000, title: 'старое');
    await write('B', 'local_1', 2000, title: 'свежее');
    await write('A', 'local_2', 1000);
    final result = await sync.run([member('A'), member('B')]);
    expect(result.copied, 1);
    expect(result.updated, 1);
    expect(await title('A', 'local_1'), 'свежее');
    expect(card('B', 'local_2').existsSync(), isTrue);
  });

  test('удалённое в одном профиле убирается из остальных', () async {
    await write('A', 'local_1', 1000);
    await write('B', 'local_1', 1000);
    await sync.run([member('A'), member('B')]);
    await card('A', 'local_1').delete();
    final result = await sync.run([member('A'), member('B')]);
    expect(result.removed, 1);
    expect(card('B', 'local_1').existsSync(), isFalse);
    // И не возвращается.
    await sync.run([member('A'), member('B')]);
    expect(card('A', 'local_1').existsSync(), isFalse);
  });

  test('открытый профиль не трогаем — догоняем потом', () async {
    await write('A', 'local_1', 1000);
    final result = await sync.run([member('A'), member('B', running: true)]);
    expect(result.copied, 0);
    expect(result.skipped, ['B']);
    expect(card('B', 'local_1').existsSync(), isFalse);
    await sync.run([member('A'), member('B')]);
    expect(card('B', 'local_1').existsSync(), isTrue);
  });

  test('много удалений сразу — защита, и они не возвращаются', () async {
    for (var i = 0; i < 10; i++) {
      await write('A', 'local_$i', 1000);
      await write('B', 'local_$i', 1000);
    }
    await sync.run([member('A'), member('B')]);
    for (var i = 0; i < 7; i++) {
      await card('A', 'local_$i').delete();
    }
    final result = await sync.run([member('A'), member('B')]);
    expect(result.deletionsStopped, isTrue);
    expect(result.removed, 0);
    expect(card('B', 'local_0').existsSync(), isTrue);
    await sync.run([member('A'), member('B')]);
    expect(card('A', 'local_0').existsSync(), isFalse, reason: 'не воскрешаем');
  });

  test('только выбранные проекты', () async {
    await write('A', 'local_1', 1000);
    final result = await sync.run(
      [member('A'), member('B')],
      projects: {'/code/other'},
    );
    expect(result.copied, 0);
  });
}
