import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const acc = '0a5308d1-efb5-463a-9e16-65f034f9f57f';
const oldAcc = '831d5df4-5da9-4f6b-9dbb-44c1b0f63184';
const org = 'f9318940-bb09-4fa1-a2e2-273952297901';
const oldOrg = 'b9cb6133-86c9-44c0-b586-8e88128bb4e0';

void main() {
  late Directory root;
  late String data;
  late String code;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('identity');
    data = p.join(root.path, 'Claude-Work');
    code = p.join(data, 'claude-config', '.claude.json');
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> json(String path, Object? value) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(value));
  }

  Future<void> cards(String account, String organization) => Directory(
    p.join(data, 'claude-code-sessions', account, organization),
  ).create(recursive: true);

  Future<ProfileIdentity> read() =>
      ProfileIdentity.read(dataDirs: [data], claudeCodeConfigs: [code]);

  Future<void> signedIn({String? blocklistOrg = org}) async {
    await json(p.join(data, 'config.json'), {
      'lastKnownAccountUuid': acc,
      'dxt:allowlistLastUpdated:$org': 1,
    });
    await json(p.join(data, 'cowork-enabled-cli-ops.json'), {
      'ownerAccountId': acc,
    });
    if (blocklistOrg != null) {
      await json(p.join(data, 'extensions-blocklist.json'), [
        {
          'url':
              'https://claude.ai/api/organizations/$blocklistOrg/dxt/blocklist',
        },
      ]);
    }
    await cards(oldAcc, oldOrg); // прежний вход в этот профиль
    await cards(acc, org);
  }

  test(
    'аккаунт, организация, почта и название — когда источники согласны',
    () async {
      await signedIn();
      await json(code, {
        'oauthAccount': {
          'accountUuid': acc,
          'organizationUuid': org,
          'emailAddress': 'anna@example.com',
          'organizationName': 'NotCode',
        },
      });
      final id = await read();
      expect(id.accountUuid, acc);
      expect(id.orgUuid, org);
      expect(id.email, 'anna@example.com');
      expect(id.orgName, 'NotCode');
      expect(id.sessionsFolder, p.join('claude-code-sessions', acc, org));
    },
  );

  test('Claude Code другого аккаунта не используется', () async {
    await signedIn();
    await json(code, {
      'oauthAccount': {
        'accountUuid': oldAcc,
        'emailAddress': 'old@example.com',
      },
    });
    final id = await read();
    expect(id.orgUuid, org);
    expect(id.email, isNull);
  });

  test('источники аккаунта расходятся — не определён', () async {
    await signedIn();
    await json(p.join(data, 'cowork-enabled-cli-ops.json'), {
      'ownerAccountId': oldAcc,
    });
    expect((await read()).accountUuid, isNull);
  });

  test('организации расходятся — не определена', () async {
    await signedIn();
    await json(code, {
      'oauthAccount': {'accountUuid': acc, 'organizationUuid': oldOrg},
    });
    final id = await read();
    expect(id.accountUuid, acc);
    expect(id.orgUuid, isNull);
    expect(id.resolved, isFalse);
  });

  test('без списка расширений — единственная папка сессий аккаунта', () async {
    await signedIn(blocklistOrg: null);
    expect((await read()).orgUuid, org);
  });

  test('профиль без входа — ничего', () async {
    final id = await read();
    expect(id.accountUuid, isNull);
    expect(id.resolved, isFalse);
  });
}
