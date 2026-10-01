import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/claude/claude_updates.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/kill_switch.dart';
import 'package:claude_launcher/src/location/location_guard.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

/// Хост, который «обновляется»: запоминает поставленный пакет.
class UpdatableHost extends FakeHost {
  String version = '2.100.0';
  List<int>? installedBytes;

  @override
  String get updateFeed => 'darwin/universal/squirrel';

  @override
  Future<String?> installedVersion() async => version;

  @override
  Future<void> installUpdate(File package, String version) async {
    installedBytes = await package.readAsBytes();
    this.version = version;
  }
}

Map<String, Object?> feed(String version, String url, {String? sha}) => {
  'currentRelease': version,
  'releases': [
    {
      'version': version,
      'updateTo': {'version': version, 'url': url, 'sha256': ?sha},
    },
  ],
};

void main() {
  test('лента: версия, адрес и сумма', () {
    final release = ClaudeRelease.parse(
      feed('2.16120.0', 'https://downloads.claude.ai/a.zip', sha: 'ab'),
    );
    expect(release?.version, '2.16120.0');
    expect(release?.url.host, 'downloads.claude.ai');
    expect(release?.sha256, 'ab');
    expect(ClaudeRelease.parse(feed('1', 'http://insecure/a.zip')), isNull);
    expect(ClaudeRelease.parse({'error': 'x'}), isNull);
  });

  test('сравнение версий, в том числе пакета MSIX', () {
    expect(ClaudeUpdates.isNewer('2.16120.0', '2.16110.0'), isTrue);
    expect(ClaudeUpdates.isNewer('2.16120.0', '2.16120.0.0'), isFalse);
    expect(ClaudeUpdates.isNewer('2.16120.0', '2.16120.1'), isFalse);
    expect(ClaudeUpdates.isNewer('3.0.0', '2.99999.9'), isTrue);
  });

  group('с лентой', () {
    late Directory dir;
    late HttpServer server;
    late AppSettings settings;
    late UpdatableHost host;
    late LauncherController launcher;
    late LocationGuard location;
    late KillSwitch killSwitch;
    late Map<String, String> query;
    late List<int> archive;
    late String? sha;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('claude_updates');
      archive = List<int>.generate(100000, (i) => i % 251);
      sha = '${sha256.convert(archive)}';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path.endsWith('/update')) {
          query = request.uri.queryParameters;
          request.response.write(
            jsonEncode(
              feed(
                '2.200.0',
                // Лента отдаёт https; в тесте подменяем на локальный сервер.
                'https://example.invalid/Claude.zip',
                sha: sha,
              ),
            ),
          );
        } else {
          request.response.add(archive);
        }
        await request.response.close();
      });
      settings = AppSettings(File('${dir.path}/settings.json'));
      await settings.load();
      await settings.setKillSwitch(true);
      host = UpdatableHost();
      launcher = LauncherController(
        host: host,
        store: ProfileStore(File('${dir.path}/profiles.json')),
      );
      await launcher.init();
      location = LocationGuard(
        settings: settings,
        lookup: () async => (country: 'DE', source: 'тест'),
      );
      await location.check();
      killSwitch = KillSwitch(
        settings: settings,
        location: location,
        launcher: launcher,
        fingerprint: () async => 'en0=1',
        useGate: false,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    tearDown(() async {
      killSwitch.dispose();
      location.dispose();
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    ClaudeUpdates updates() => ClaudeUpdates(
      host: host,
      launcher: launcher,
      killSwitch: killSwitch,
      settings: settings,
      feedBase: 'http://127.0.0.1:${server.port}/api/desktop',
      downloadOverride: Uri.parse('http://127.0.0.1:${server.port}/Claude.zip'),
    );

    test('находит новую версию со случайным device_id', () async {
      final u = updates();
      await u.check();
      expect(u.available?.version, '2.200.0');
      expect(query['version'], '2.100.0');
      expect(query['device_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('без проверенной сети не спрашивает', () async {
      await settings.setKillSwitch(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final u = updates();
      await u.check();
      expect(u.available, isNull);
    });

    test('скачивает, сверяет сумму и ставит', () async {
      final u = updates();
      await u.check();
      await u.install();
      expect(u.error, isNull);
      expect(u.phase, ClaudeUpdatePhase.idle);
      expect(host.installedBytes, archive);
      expect(host.version, '2.200.0');
      expect(u.available, isNull);
    });

    test('сумма не сошлась — не ставит', () async {
      final u = updates();
      await u.check();
      sha = null;
      archive = [1, 2, 3];
      await u.install();
      expect(u.phase, ClaudeUpdatePhase.failed);
      expect(host.installedBytes, isNull);
    });
  });
}
