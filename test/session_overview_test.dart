import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/session_overview.dart';
import 'package:claude_launcher/src/profile.dart';
import 'package:claude_launcher/src/ui/sessions_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const acc = '0a5308d1-efb5-463a-9e16-65f034f9f57f';
const org = 'f9318940-bb09-4fa1-a2e2-273952297901';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('overview'));
  tearDown(() => root.delete(recursive: true));

  Future<String> profileDir(String name, Map<String, Object?> cards) async {
    final data = p.join(root.path, name);
    await Directory(data).create(recursive: true);
    await File(
      p.join(data, 'config.json'),
    ).writeAsString(jsonEncode({'lastKnownAccountUuid': acc}));
    final folder = p.join(data, 'claude-code-sessions', acc, org);
    await Directory(folder).create(recursive: true);
    for (final MapEntry(:key, :value) in cards.entries) {
      await File(
        p.join(folder, key),
      ).writeAsString(value is String ? value : jsonEncode(value));
    }
    return data;
  }

  Map<String, Object?> card(String id, String cwd, int at, {String? title}) => {
    'sessionId': id,
    'cliSessionId': 'cli-$id',
    'cwd': cwd,
    'lastActivityAt': at,
    'title': ?title,
    'model': 'claude-opus-5-5',
  };

  test('карточки профиля: архив скрыт, незнакомые посчитаны', () async {
    final data = await profileDir('Claude-Work', {
      'local_a.json': card(
        'local_a',
        '/code/app',
        2000,
        title: 'Починить вход',
      ),
      'local_b.json': card('local_b', '/code/app', 3000),
      'local_c.json': {
        ...card('local_c', '/code/site', 1000),
        'isArchived': true,
      },
      'local_d.json': {'sessionId': 'local_d'},
      'deleted_local_x': '',
      'scheduled-tasks.json': '{}',
    });
    final result = await SessionOverview.readProfile(
      const Profile(id: 'w', name: 'Рабочий', folderName: 'Claude-Work'),
      dataDirs: [data],
      claudeCodeConfigs: const [],
    );
    expect(result.identity.resolved, isTrue);
    expect([for (final s in result.sessions) s.id], ['local_b', 'local_a']);
    expect(result.sessions.last.title, 'Починить вход');
    expect(result.sessions.first.title, 'app', reason: 'без названия — папка');
    expect(result.unreadable, 1);
    expect(result.formatKnown, isFalse);
  });

  test('проекты по профилям, свежие сверху', () async {
    final work = await SessionOverview.readProfile(
      const Profile(id: 'w', name: 'Рабочий', folderName: 'Claude-Work'),
      dataDirs: [
        await profileDir('Claude-Work', {
          'local_a.json': card('local_a', '/code/app', 1000),
        }),
      ],
      claudeCodeConfigs: const [],
    );
    final test = await SessionOverview.readProfile(
      const Profile(id: 't', name: 'Тест', folderName: 'Claude-Test'),
      dataDirs: [
        await profileDir('Claude-Test', {
          'local_b.json': card('local_b', '/code/site', 5000),
          'local_c.json': card('local_c', '/code/app', 2000),
        }),
      ],
      claudeCodeConfigs: const [],
    );
    final projects = SessionOverview.projects([work, test]);
    expect(
      [for (final project in projects) project.cwd],
      ['/code/site', '/code/app'],
    );
    expect(projects.last.byProfile.keys, unorderedEquals(['w', 't']));
  });

  test('подписи', () {
    expect([1, 2, 5, 11, 21, 22, 112].map(sessionCount), [
      '1 сессия',
      '2 сессии',
      '5 сессий',
      '11 сессий',
      '21 сессия',
      '22 сессии',
      '112 сессий',
    ]);
    final now = DateTime(2026, 10, 3, 18);
    expect(when(DateTime(2026, 10, 3, 9, 5), now), '09:05');
    expect(when(DateTime(2026, 10, 2, 23), now), 'вчера');
    expect(when(DateTime(2026, 9, 1), now), '01.09');
    expect(when(DateTime(2025, 9, 1), now), '01.09.2025');
    expect(modelName('claude-opus-5-5[1m]'), 'Opus 5.5');
    expect(modelName('claude-haiku-4-5-20251001'), 'Haiku 4.5');
    expect(modelName('custom'), 'custom');
  });

  test('токены за сегодня и размеры', () async {
    final data = await profileDir('Claude-Work', {});
    final now = DateTime(2026, 10, 3, 18);
    expect(await SessionOverview.tokensToday([data], now), isNull);
    await File(p.join(data, 'buddy-tokens.json')).writeAsString(
      jsonEncode({
        'tokens-today': {'date': '2026-10-03', 'tokens': 12400},
      }),
    );
    expect(await SessionOverview.tokensToday([data], now), 12400);
    expect(
      await SessionOverview.tokensToday([data], DateTime(2026, 10, 4)),
      isNull,
      reason: 'счётчик вчерашний',
    );
    expect(tokens(12400), '12\u202F400 токенов');
    expect(tokens(1), '1 токен');
    expect(tokens(1234567), '1\u202F234\u202F567 токенов');
    expect(size(271 * 1024 * 1024), '271 МБ');
    expect(size(1288490188), '1,2 ГБ');
    expect(await SessionOverview.diskUsage([data]), greaterThan(0));
  });
}
