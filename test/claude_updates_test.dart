import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/claude/claude_updates.dart';
import 'package:claude_launcher/src/claude/claude_host.dart';
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

  /// Сколько раз установка ещё сорвётся.
  int failures = 0;
  bool safeRecovery = true;
  Future<void> Function()? onInstall;
  final failLaunchDirs = <String?>{};
  bool failProcessScan = false;

  @override
  Future<List<ClaudeInstance>> running() async {
    if (failProcessScan) throw StateError('test process scan failure');
    return super.running();
  }

  @override
  Future<bool> canLaunchAfterUpdateFailure() async => safeRecovery;

  @override
  Future<void> launch(String? dataDir) async {
    if (failLaunchDirs.contains(dataDir)) {
      throw StateError('test launch failed');
    }
    await super.launch(dataDir);
  }

  @override
  String get updateFeed => 'darwin/universal/squirrel';

  @override
  Future<String?> installedVersion() async => version;

  @override
  Future<void> installUpdate(File package, String version) async {
    await onInstall?.call();
    if (failures > 0) {
      failures--;
      throw const FileSystemException('Directory not empty');
    }
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
    late int downloads;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('claude_updates');
      archive = List<int>.generate(100000, (i) => i % 251);
      sha = '${sha256.convert(archive)}';
      downloads = 0;
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
          downloads++;
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
      launcher.dispose();
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
      cacheDir: Directory('${dir.path}/cache'),
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

    test('после обновления восстанавливает все параллельные профили', () async {
      launcher.setParallelLaunch(true);
      final personal = await launcher.addProfile(name: 'Личный');
      host.start(null);
      host.start(launcher.dataDirOf(personal));
      await launcher.refresh();
      final u = updates();
      await u.check();
      await u.install();
      expect(u.error, isNull);
      expect(launcher.runningProfiles, hasLength(2));
      expect(host.calls.where((c) => c.startsWith('launch ')), hasLength(2));
    });

    test(
      'installation excludes launches, links and close, retaining mode snapshot',
      () async {
        launcher.setParallelLaunch(true);
        final second = await launcher.addProfile(name: 'Second');
        final third = await launcher.addProfile(name: 'Third');
        host.start(null);
        host.start(launcher.dataDirOf(second));
        await launcher.refresh();
        final ready = Completer<void>();
        final release = Completer<void>();
        host.onInstall = () async {
          ready.complete();
          await release.future;
        };
        final u = updates();
        await u.check();
        final installing = u.install();
        await ready.future;
        expect(launcher.maintaining, isTrue);
        expect(u.busy, isTrue);
        final calls = List.of(host.calls);
        await launcher.switchTo(third);
        await launcher.openLink(second, Uri.parse('claude://claude.ai/test'));
        await launcher.close(second);
        await u.install();
        expect(host.calls, calls);
        launcher.setParallelLaunch(false);
        release.complete();
        await installing;
        expect(u.error, isNull);
        expect(launcher.runningProfiles, hasLength(2));
        expect(launcher.isRunning(third), isFalse);
        expect(launcher.maintaining, isFalse);
      },
    );

    test(
      'failed install restores every profile only after host verification',
      () async {
        launcher.setParallelLaunch(true);
        final second = await launcher.addProfile(name: 'Second');
        host.start(null);
        host.start(launcher.dataDirOf(second));
        await launcher.refresh();
        host.failures = 1;
        final u = updates();
        await u.check();
        await u.install();
        expect(u.phase, ClaudeUpdatePhase.failed);
        expect(u.error, contains('Directory not empty'));
        expect(launcher.runningProfiles, hasLength(2));
        expect(launcher.maintaining, isFalse);
        expect(u.available, isNotNull);
      },
    );

    test(
      'unsafe failed install leaves profiles closed and reservation released',
      () async {
        host.start(null);
        await launcher.refresh();
        host.failures = 1;
        host.safeRecovery = false;
        final u = updates();
        await u.check();
        await u.install();
        expect(u.phase, ClaudeUpdatePhase.failed);
        expect(host.calls.where((c) => c.startsWith('launch ')), isEmpty);
        expect(launcher.maintaining, isFalse);
      },
    );

    test('failure to restore one profile does not skip the next', () async {
      launcher.setParallelLaunch(true);
      final first = launcher.profiles.single;
      final second = await launcher.addProfile(name: 'Second');
      host.start(null);
      host.start(launcher.dataDirOf(second));
      await launcher.refresh();
      host.failLaunchDirs.add(null);
      final u = updates();
      await u.check();
      await u.install();
      expect(u.phase, ClaudeUpdatePhase.failed);
      expect(u.error, contains(first.name));
      expect(launcher.isRunning(second), isTrue);
      expect(u.available, isNull);
    });

    test(
      'unknown process prevents closing known profiles or installing',
      () async {
        host.start(null);
        host.start('/unlisted');
        await launcher.refresh();
        final u = updates();
        await u.check();
        await u.install();
        expect(u.error, contains('вне списка'));
        expect(host.calls, isEmpty);
        expect(host.installedBytes, isNull);
        expect(launcher.instances, hasLength(2));
      },
    );

    test('emergency kill during install prevents automatic recovery', () async {
      host.start(null);
      await launcher.refresh();
      final ready = Completer<void>();
      final release = Completer<void>();
      host.onInstall = () async {
        ready.complete();
        await release.future;
      };
      final u = updates();
      await u.check();
      final installing = u.install();
      await ready.future;
      await launcher.killAll();
      release.complete();
      await installing;
      expect(u.error, contains('аварийным'));
      expect(host.calls.where((c) => c.startsWith('launch ')), isEmpty);
      expect(launcher.maintaining, isFalse);
    });

    test(
      'failed process scan blocks installation without relying on stale list',
      () async {
        final u = updates();
        await u.check();
        host.failProcessScan = true;
        await u.install();
        expect(u.phase, ClaudeUpdatePhase.failed);
        expect(u.error, contains('process scan failure'));
        expect(host.installedBytes, isNull);
        expect(launcher.maintaining, isFalse);
      },
    );

    test(
      'cancelled close aborts install and retains running profile',
      () async {
        host.start(null);
        host.quitsOnRequest = false;
        await launcher.refresh();
        final u = updates();
        await u.check();
        launcher.addListener(() {
          if (launcher.switchStatus?.phase == SwitchPhase.waitingForUser) {
            launcher.cancelSwitch();
          }
        });
        await u.install();
        expect(u.phase, ClaudeUpdatePhase.failed);
        expect(u.error, contains('отменено'));
        expect(host.installedBytes, isNull);
        expect(launcher.runningProfiles, hasLength(1));
        expect(launcher.maintaining, isFalse);
      },
    );

    test('сумма не сошлась — не ставит', () async {
      final u = updates();
      await u.check();
      sha = null;
      archive = [1, 2, 3];
      await u.install();
      expect(u.phase, ClaudeUpdatePhase.failed);
      expect(host.installedBytes, isNull);
    });

    test('ошибка установки — повтор не качает архив заново', () async {
      final u = updates();
      await u.check();
      host.failures = 1;
      await u.install();
      expect(u.phase, ClaudeUpdatePhase.failed);
      expect(downloads, 1);
      // Архив ждёт повтора — один, без копий.
      final cached = Directory('${dir.path}/cache').listSync();
      expect(cached, hasLength(1));
      expect(cached.single.path, endsWith('Claude.zip'));

      await u.install();
      expect(u.error, isNull);
      expect(downloads, 1);
      expect(host.installedBytes, archive);
      // Поставили — папка загрузки убрана.
      expect(Directory('${dir.path}/cache').existsSync(), isFalse);
    });

    test('остатки прежних загрузок удаляются', () async {
      final cache = Directory('${dir.path}/cache')..createSync();
      File('${cache.path}/Claude-old.zip').writeAsBytesSync([1, 2, 3]);
      File('${cache.path}/Claude.zip.part').writeAsBytesSync([4, 5]);
      final u = updates();
      await u.check();
      host.failures = 1;
      await u.install();
      expect(cache.listSync().map((e) => e.path.split('/').last), [
        'Claude.zip',
      ]);
    });

    test('испорченный архив в папке не ставится — качается заново', () async {
      final cache = Directory('${dir.path}/cache')..createSync();
      File('${cache.path}/Claude.zip').writeAsBytesSync([9, 9, 9]);
      final u = updates();
      await u.check();
      await u.install();
      expect(downloads, 1);
      expect(host.installedBytes, archive);
    });
  });
}
