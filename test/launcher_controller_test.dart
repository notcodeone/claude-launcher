import 'dart:io';

import 'package:claude_launcher/src/claude/claude_host.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Поддельный Claude: экземпляры живут в списке, вызовы записываются.
class FakeHost extends ClaudeHost {
  final instances = <ClaudeInstance>[];
  final calls = <String>[];

  /// Закрывается ли Claude по просьбе (на Windows он может уйти в трей).
  bool quitsOnRequest = true;
  int _nextPid = 100;

  @override
  String get profilesBaseDir => '/support';

  @override
  String get defaultDataDir => '/support/Claude';

  @override
  Duration get pollInterval => const Duration(hours: 1);

  @override
  Duration get manualQuitHintAfter => const Duration(milliseconds: 100);

  @override
  String get manualQuitHint => 'закройте вручную';

  @override
  Future<String?> locate() async => '/Applications/Claude.app';

  @override
  Future<List<ClaudeInstance>> running() async => List.of(instances);

  ClaudeInstance start(String? dataDir) {
    final instance = ClaudeInstance(pid: _nextPid++, dataDir: dataDir);
    instances.add(instance);
    return instance;
  }

  @override
  Future<void> launch(String? dataDir) async {
    calls.add('launch ${dataDir ?? 'default'}');
    start(dataDir);
  }

  @override
  Future<void> activate(ClaudeInstance instance) async {
    calls.add('activate ${instance.pid}');
  }

  @override
  Future<void> requestQuit(ClaudeInstance instance) async {
    calls.add('quit ${instance.pid}');
    if (quitsOnRequest) instances.remove(instance);
  }
}

void main() {
  late Directory dir;
  late FakeHost host;
  late LauncherController launcher;
  late Profile work;
  late Profile personal;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_launcher_test');
    host = FakeHost();
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    await launcher.init();
    work = launcher.profiles.single; // стандартный профиль создаётся сам
    personal = await launcher.addProfile(name: 'Личный', marker: '🔵');
  });

  tearDown(() async {
    launcher.dispose();
    await dir.delete(recursive: true);
  });

  test('первый запуск создаёт стандартный профиль', () {
    expect(work.usesDefaultFolder, isTrue);
    expect(personal.folderName, 'Claude-Lichnyy');
    expect(launcher.dataDirOf(personal), '/support/Claude-Lichnyy');
  });

  test(
    'экземпляр без --user-data-dir относится к стандартному профилю',
    () async {
      host.start(null);
      await launcher.refresh();
      expect(launcher.isRunning(work), isTrue);
      expect(launcher.isRunning(personal), isFalse);
      expect(launcher.unknownInstances, isEmpty);
    },
  );

  test('переключение закрывает открытый профиль и запускает нужный', () async {
    final running = host.start(null);
    await launcher.switchTo(personal);

    expect(host.calls, [
      'quit ${running.pid}',
      'launch /support/Claude-Lichnyy',
    ]);
    expect(launcher.isRunning(personal), isTrue);
    expect(launcher.isRunning(work), isFalse);
    expect(launcher.switchStatus, isNull);
    expect(launcher.lastError, isNull);
    final saved = launcher.profiles.firstWhere(
      (profile) => profile.id == personal.id,
    );
    expect(saved.lastLaunchedAt, isNotNull);
  });

  test('уже открытый профиль просто выводится вперёд', () async {
    final running = host.start('/support/Claude-Lichnyy');
    await launcher.switchTo(personal);
    expect(host.calls, ['activate ${running.pid}']);
  });

  test('закрывает и экземпляры с неизвестной папкой', () async {
    final stranger = host.start('/somewhere/else');
    await launcher.refresh();
    expect(launcher.unknownInstances.single.pid, stranger.pid);

    await launcher.switchTo(work);
    expect(host.calls, ['quit ${stranger.pid}', 'launch default']);
  });

  test(
    'если Claude не закрылся, просит пользователя; отмена не запускает профиль',
    () async {
      host.quitsOnRequest = false;
      host.start(null);
      var attention = 0;
      launcher.onNeedsAttention = () => attention++;

      final switching = launcher.switchTo(personal);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(launcher.switchStatus?.phase, SwitchPhase.waitingForUser);
      expect(attention, 1);

      launcher.cancelSwitch();
      await switching;
      expect(launcher.switchStatus, isNull);
      expect(host.calls.where((call) => call.startsWith('launch')), isEmpty);
    },
  );

  test(
    'если пользователь закрыл Claude сам, переключение продолжается',
    () async {
      host.quitsOnRequest = false;
      final stuck = host.start(null);

      final switching = launcher.switchTo(personal);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      host.instances.remove(stuck); // пользователь закрыл Claude из трея
      await switching;

      expect(host.calls.last, 'launch /support/Claude-Lichnyy');
    },
  );

  test('профили сохраняются между запусками', () async {
    await launcher.updateProfile(
      work.copyWith(name: 'Рабочий', email: 'me@work.com'),
    );
    final reloaded = await ProfileStore(
      File('${dir.path}/profiles.json'),
    ).load();
    expect(reloaded.map((profile) => profile.name), ['Рабочий', 'Личный']);
    expect(reloaded.first.email, 'me@work.com');
  });
}
