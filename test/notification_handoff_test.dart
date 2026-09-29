import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:claude_launcher/src/integrations/notification_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File cliSettings;
  late String main;
  late String work;
  late NotificationHandoff handoff;

  NotificationHandoff create({int ownerId = 1}) => NotificationHandoff(
    stateFile: File('${dir.path}/launcher/claude-notifications.json'),
    hooks: ClaudeCodeHooks(cliSettings),
    samePath: (a, b) => a.toLowerCase() == b.toLowerCase(),
    ownerId: ownerId,
  );

  File configOf(String profile) =>
      File('$profile/${NotificationHandoff.desktopConfigName}');

  Map<String, Object?> read(File file) =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  Object? levelsOf(String profile) =>
      (read(configOf(profile))['preferences'] as Map)['notificationLevels'];

  void write(File file, Map<String, Object?> json) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(json));
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_launcher_handoff');
    cliSettings = File('${dir.path}/.claude/settings.json');
    main = '${dir.path}/Claude';
    work = '${dir.path}/Claude-Work';
    write(cliSettings, {'model': 'opus'});
    write(configOf(main), {
      'coworkUserFilesPath': '/Users/me/Claude',
      'preferences': {'sidebarMode': 'chat'},
    });
    write(configOf(work), {
      'preferences': {
        'notificationLevels': {'permission': 'badge'},
      },
    });
    handoff = create();
    expect(await handoff.claim(), isTrue);
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'выключает у закрытых Claude, запоминает и возвращает как было',
    () async {
      final taken = await handoff.sync(
        active: true,
        profiles: [main, work],
        running: const [],
      );
      expect(taken, (pending: true, error: null));
      expect(read(cliSettings), {
        'model': 'opus',
        'preferredNotifChannel': 'notifications_disabled',
      });
      expect(levelsOf(main), NotificationHandoff.desktopOff);
      expect(levelsOf(work), NotificationHandoff.desktopOff);
      expect(
        read(configOf(main))['coworkUserFilesPath'],
        '/Users/me/Claude',
        reason: 'остальные настройки Claude не трогаем',
      );
      expect(
        (read(configOf(main))['preferences'] as Map)['sidebarMode'],
        'chat',
      );

      final released = await handoff.sync(
        active: false,
        profiles: [main, work],
        running: const [],
      );
      expect(released, (pending: false, error: null));
      expect(read(cliSettings), {'model': 'opus'});
      expect(read(configOf(main)), {
        'coworkUserFilesPath': '/Users/me/Claude',
        'preferences': {'sidebarMode': 'chat'},
      });
      expect(levelsOf(work), {'permission': 'badge'});
    },
  );

  test('файл запущенного Claude не трогает, пока тот не закроется', () async {
    await handoff.sync(active: true, profiles: [main, work], running: [work]);
    expect(levelsOf(work), {'permission': 'badge'});
    expect(levelsOf(main), NotificationHandoff.desktopOff);

    // Закрыли лаунчер, а основной Claude открыт: вернуть можно только потом.
    var result = await handoff.sync(
      active: false,
      profiles: [main, work],
      running: [main.toUpperCase()],
    );
    expect(result.pending, isTrue);
    expect(levelsOf(main), NotificationHandoff.desktopOff);
    expect(read(cliSettings), {'model': 'opus'}, reason: 'терминал — сразу');

    result = await handoff.sync(
      active: false,
      profiles: const [],
      running: const [],
    );
    expect(result.pending, isFalse);
    expect(
      (read(configOf(main))['preferences'] as Map).containsKey(
        'notificationLevels',
      ),
      isFalse,
    );
  });

  test('если пользователь сам поменял настройку — оставляет его выбор', () async {
    write(cliSettings, {'preferredNotifChannel': 'iterm2'});
    await handoff.sync(active: true, profiles: [main], running: const []);

    // Пока настройки были у лаунчера, их включили в самом Claude и в терминале.
    write(configOf(main), {
      'preferences': {
        'notificationLevels': {'idle': 'banner'},
      },
    });
    write(cliSettings, {'preferredNotifChannel': 'terminal_bell'});
    await handoff.sync(active: false, profiles: [main], running: const []);
    expect(levelsOf(main), {'idle': 'banner'});
    expect(read(cliSettings), {'preferredNotifChannel': 'terminal_bell'});
  });

  test('уже выключенное пользователем не присваивает', () async {
    write(cliSettings, {'preferredNotifChannel': 'notifications_disabled'});
    write(configOf(main), {
      'preferences': {'notificationLevels': NotificationHandoff.desktopOff},
    });
    await handoff.sync(active: true, profiles: [main], running: const []);
    await handoff.sync(active: false, profiles: [main], running: const []);
    expect(read(cliSettings), {
      'preferredNotifChannel': 'notifications_disabled',
    });
    expect(levelsOf(main), NotificationHandoff.desktopOff);
  });

  test('перед запуском создаёт настройки нового профиля', () async {
    final fresh = '${dir.path}/Claude-Fresh';
    await handoff.sync(active: true, profiles: [fresh], running: const []);
    expect(
      configOf(fresh).existsSync(),
      isFalse,
      reason: 'пока профиль не запускают, его папку не создаём',
    );
    expect(await handoff.takeBeforeLaunch(fresh), isNull);
    expect(levelsOf(fresh), NotificationHandoff.desktopOff);

    // Профиль убрали из списка — ему тоже возвращаем.
    await handoff.sync(active: true, profiles: [main], running: const []);
    expect(
      (read(configOf(fresh))['preferences'] as Map).containsKey(
        'notificationLevels',
      ),
      isFalse,
    );
  });

  test('испорченный файл Claude не трогает и сообщает об ошибке', () async {
    configOf(main).writeAsStringSync('{ не json');
    final result = await handoff.sync(
      active: true,
      profiles: [main, work],
      running: const [],
    );
    expect(result.error, isNotNull);
    expect(configOf(main).readAsStringSync(), '{ не json');
    expect(levelsOf(work), NotificationHandoff.desktopOff);
  });

  test('менять может только владелец; наблюдатель не отнимает', () async {
    final watcher = create(ownerId: 2);
    expect(await watcher.claim(onlyIfFree: true), isFalse);
    await watcher.sync(active: true, profiles: [main], running: const []);
    expect(levelsOf(main), isNull, reason: 'не владелец — ничего не меняет');

    await handoff.sync(active: true, profiles: [main], running: [main]);
    await handoff.resign();
    expect(await watcher.claim(onlyIfFree: true), isTrue);
    expect(
      (await handoff.sync(
        active: false,
        profiles: [main],
        running: const [],
      )).pending,
      isFalse,
      reason: 'лаунчер больше не владелец',
    );
    expect(
      read(cliSettings)['preferredNotifChannel'],
      'notifications_disabled',
    );

    // Лаунчер запустили снова — он забирает настройки себе.
    expect(await handoff.claim(), isTrue);
    await watcher.sync(active: false, profiles: const [], running: const []);
    expect(
      read(cliSettings)['preferredNotifChannel'],
      'notifications_disabled',
    );
  });
}
