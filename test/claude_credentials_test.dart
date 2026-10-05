import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:claude_launcher/src/claude/claude_credentials.dart';
import 'package:claude_launcher/src/integrations/live_usage.dart';
import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'launcher_controller_test.dart' show FakeHost;

const account = 'aaaaaaaa-0000-0000-0000-000000000001';
const org = 'bbbbbbbb-0000-0000-0000-000000000002';
const otherOrg = 'cccccccc-0000-0000-0000-000000000003';

/// Шифрует так же, как Claude на macOS (OSCrypt v10, AES-128-CBC).
Uint8List encryptMac(List<int> plain, String password) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters(
          ParametersWithIV(
            KeyParameter(ClaudeCredentials.macKey(password)),
            Uint8List(16)..fillRange(0, 16, 0x20),
          ),
          null,
        ),
      );
  return Uint8List.fromList([
    ...ascii.encode('v10'),
    ...cipher.process(Uint8List.fromList(plain)),
  ]);
}

/// Как на Windows: v10 + nonce + AES-256-GCM с тегом.
Uint8List encryptWindows(List<int> plain, Uint8List key) {
  final nonce = Uint8List.fromList(List.generate(12, (i) => i + 1));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  return Uint8List.fromList([
    ...ascii.encode('v10'),
    ...nonce,
    ...cipher.process(Uint8List.fromList(plain)),
  ]);
}

class FixedKey implements SafeStorageKey {
  FixedKey(this.secret);
  final SafeStorageSecret? secret;
  int reads = 0;

  @override
  Future<SafeStorageSecret?> read(String dataDir) async {
    reads++;
    return secret;
  }

  @override
  Future<bool> unlock() async => secret != null;
}

void main() {
  final now = DateTime(2026, 10, 5, 12);
  final later = now.add(const Duration(hours: 1)).millisecondsSinceEpoch;

  Map<String, Object?> cache() => {
    // Чужая организация и токен без user:profile — не годятся.
    'acct:$account|${ClaudeCredentials.desktopClient}:$otherOrg:https://api.anthropic.com:user:profile':
        {'token': 'other-org', 'expiresAt': later},
    'acct:$account|${ClaudeCredentials.desktopClient}:$org:https://api.anthropic.com:user:inference':
        {'token': 'no-profile-scope', 'expiresAt': later},
    'acct:$account|a473d7bb-17ac-43a7-abc0-a1343d7c2805:$org:https://api.anthropic.com:user:inference user:profile user:sessions:claude_code':
        {'token': 'code-tab', 'expiresAt': later},
    'acct:$account|${ClaudeCredentials.desktopClient}:$org:https://api.anthropic.com:user:inference user:file_upload user:profile':
        {'token': 'desktop', 'expiresAt': later, 'refreshToken': 'r'},
    'acct:$account|x:$org:https://api.anthropic.com:user:profile': null,
  };

  group('выбор токена', () {
    test('клиент Claude Desktop нужного аккаунта и организации', () {
      expect(
        ClaudeCredentials.pickToken(
          cache(),
          account: account,
          org: org,
          now: now,
        ),
        'desktop',
      );
    });

    test('истёкший не берём — берём другой действующий', () {
      final entries = cache();
      (entries.values.elementAt(3)! as Map)['expiresAt'] =
          now.millisecondsSinceEpoch;
      expect(
        ClaudeCredentials.pickToken(
          entries,
          account: account,
          org: org,
          now: now,
        ),
        'code-tab',
      );
    });

    test('другой аккаунт — ничего', () {
      expect(
        ClaudeCredentials.pickToken(
          cache(),
          account: 'dddddddd-0000-0000-0000-000000000004',
          org: org,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('расшифровка', () {
    final plain = utf8.encode(jsonEncode(cache()));

    test('macOS', () {
      final data = encryptMac(plain, 'пароль-связки');
      expect(
        ClaudeCredentials.decrypt(data, const MacSecret('пароль-связки')),
        plain,
      );
      expect(
        ClaudeCredentials.decrypt(data, const MacSecret('другой')),
        isNull,
      );
    });

    test('Windows', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final data = encryptWindows(plain, key);
      expect(ClaudeCredentials.decrypt(data, WindowsSecret(key)), plain);
      expect(
        ClaudeCredentials.decrypt(data, WindowsSecret(Uint8List(32))),
        isNull,
      );
    });

    test('не v10 — ничего', () {
      expect(
        ClaudeCredentials.decrypt(
          Uint8List.fromList(utf8.encode('plain')),
          const MacSecret('x'),
        ),
        isNull,
      );
    });

    test('из config.json профиля', () async {
      final dir = await Directory.systemTemp.createTemp('creds');
      try {
        await File(p.join(dir.path, 'config.json')).writeAsString(
          jsonEncode({
            'oauth:tokenCacheV2': base64Encode(encryptMac(plain, 'k')),
          }),
        );
        final key = FixedKey(const MacSecret('k'));
        final token = await ClaudeCredentials(
          key: key,
        ).accessToken(dataDir: dir.path, account: account, org: org, now: now);
        expect(token, 'desktop');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  test('ответ /api/oauth/usage', () {
    final usage = ProfileUsage.fromOAuthUsage({
      'five_hour': {'utilization': 19, 'resets_at': '2026-10-05T11:09:59.878Z'},
      'seven_day': {'utilization': 4.0, 'resets_at': '2026-10-11T17:59:59Z'},
      'seven_day_opus': null,
      'limits': [
        {
          'kind': 'weekly_scoped',
          'percent': 0,
          'resets_at': '2026-10-11T18:00:00Z',
          'scope': {
            'model': {'display_name': 'Fable'},
          },
        },
      ],
      'extra_usage': {'is_enabled': false, 'utilization': null},
    })!;
    expect(usage.limits.map((l) => l.label), [
      'За 5 часов',
      'За неделю · все модели',
      'За неделю · Fable',
    ]);
    expect(usage.limits.first.usedPercent, 19);
    expect(usage.limits.first.window, UsageWindow.session);
    expect(
      usage.limits.first.resetsAt,
      DateTime.utc(2026, 10, 5, 11, 9, 59, 878).toLocal(),
    );
    expect(ProfileUsage.fromOAuthUsage({}), isNull);
  });

  group('запрос лимитов', () {
    late Directory dir;
    late LauncherController launcher;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('live');
      launcher = LauncherController(
        host: FakeHost(),
        store: ProfileStore(File('${dir.path}/p.json')),
      );
      await launcher.init();
      launcher.identities = {
        launcher.profiles.single.id: const ProfileIdentity(
          accountUuid: account,
          orgUuid: org,
        ),
      };
    });
    tearDown(() => dir.delete(recursive: true));

    LiveUsage live({
      required List<String> requests,
      required DateTime Function() clock,
      bool Function()? allowed,
    }) => LiveUsage(
      launcher: launcher,
      credentials: _TokenOnly('token'),
      allowed: allowed,
      now: clock,
      request: (token) async {
        requests.add(token);
        return {
          'five_hour': {'utilization': requests.length * 10},
        };
      },
    );

    test('не чаще раза в минуту, без запроса — последний ответ', () async {
      final requests = <String>[];
      var clock = now;
      final usage = live(requests: requests, clock: () => clock);
      final profile = launcher.profiles.single;
      expect(usage.cached(profile), isNull);
      expect((await usage.fetch(profile))!.limits.single.usedPercent, 10);
      expect((await usage.fetch(profile))!.limits.single.usedPercent, 10);
      expect(requests, ['token']);
      expect(usage.cached(profile)!.limits.single.usedPercent, 10);
      clock = now.add(const Duration(minutes: 1));
      expect((await usage.fetch(profile))!.limits.single.usedPercent, 20);
      expect(requests, hasLength(2));
    });

    test('«Проверить снова» — раньше минуты, но не чаще 10 секунд', () async {
      final requests = <String>[];
      var clock = now;
      final usage = live(requests: requests, clock: () => clock);
      final profile = launcher.profiles.single;
      var notified = 0;
      usage.addListener(() => notified++);
      final first = usage.fetch(profile);
      expect(usage.fetching, isTrue);
      await first;
      expect(usage.fetching, isFalse);
      expect(notified, 2); // начало и конец — статус в шапке
      clock = now.add(const Duration(seconds: 5));
      await usage.fetch(profile, manual: true);
      expect(requests, hasLength(1));
      clock = now.add(const Duration(seconds: 11));
      await usage.fetch(profile, manual: true);
      expect(requests, hasLength(2));
    });

    test('сеть нельзя (Kill Switch) — не спрашивает', () async {
      final requests = <String>[];
      final usage = live(
        requests: requests,
        clock: () => now,
        allowed: () => false,
      );
      expect(await usage.fetch(launcher.profiles.single), isNull);
      expect(requests, isEmpty);
    });

    test('аккаунт профиля неизвестен — не спрашивает', () async {
      launcher.identities = const {};
      final requests = <String>[];
      final usage = live(requests: requests, clock: () => now);
      expect(await usage.fetch(launcher.profiles.single), isNull);
      expect(requests, isEmpty);
    });
  });
}

class _TokenOnly extends ClaudeCredentials {
  _TokenOnly(this.token) : super(key: FixedKey(null));
  final String token;

  @override
  Future<String?> accessToken({
    required String dataDir,
    required String account,
    required String org,
    DateTime? now,
  }) async => token;
}
