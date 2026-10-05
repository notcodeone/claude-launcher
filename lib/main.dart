import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_settings.dart';
import 'src/app_window.dart';
import 'src/claude/claude_host.dart';
import 'src/integrations/claude_code_hooks.dart';
import 'src/integrations/claude_code_integration.dart';
import 'src/integrations/code_session_registry.dart';
import 'src/integrations/claude_tray_icon.dart';
import 'src/integrations/notification_handoff.dart';
import 'src/integrations/profile_claude_code.dart';
import 'src/claude/link_handler_platform.dart';
import 'src/integrations/claude_links.dart';
import 'src/integrations/session_overview.dart';
import 'src/integrations/session_sync_service.dart';
import 'src/launcher_controller.dart';
import 'src/claude/claude_icon_keeper.dart';
import 'src/claude/claude_updates.dart';
import 'src/location/cowork_firewall.dart';
import 'src/location/egress_config.dart';
import 'src/location/kill_switch.dart';
import 'src/location/location_guard.dart';
import 'src/location/windows_network_watch.dart';
import 'src/notifications.dart';
import 'src/profile_store.dart';
import 'src/tray.dart';
import 'src/ui/profile_dialog.dart' show showLinkProfileDialog;
import 'src/ui/announcements.dart';
import 'src/ui/home_page.dart';
import 'src/ui/settings_dialog.dart';
import 'src/ui/theme.dart';
import 'src/updates/app_updater.dart';

/// Нужен, чтобы показать окно приветствия из main(), вне дерева виджетов.
final _navigatorKey = GlobalKey<NavigatorState>();

/// Канал к нативной части (см. MainFlutterWindow.swift); оттуда приходит `reopen`.
const _nativeChannel = MethodChannel('claude_launcher/native');

/// Запуск наблюдателя, который вернёт Claude уведомления после выхода из лаунчера.
const _watcherFlag = '--return-claude-notifications';

/// Охранник Kill Switch: держит затвор после выхода из лаунчера, пока открыт
/// закреплённый за ним Claude (см. [_guardKillSwitch]).
const _guardFlag = '--kill-switch-guard';

/// Охраннику: Kill Switch выключен, затвор лишь пропускает всё до закрытия
/// Claude.
const _passthroughFlag = '--passthrough';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  await _moveRenamedSupportDir(supportDir);

  // Удаление: флаг передаёт деинсталлятор Windows, на macOS — пользователь (README).
  // Убираем за собой и выходим, окно не показываем.
  if (args.contains('--cleanup')) {
    await _cleanup(supportDir);
    exit(0);
  }

  if (args.contains(_guardFlag) &&
      !await _guardKillSwitch(
        supportDir,
        passthrough: args.contains(_passthroughFlag),
      )) {
    exit(0);
  }

  if (args.contains(_watcherFlag) &&
      !await _returnClaudeNotifications(supportDir)) {
    exit(0);
  }

  await windowManager.ensureInitialized();
  final host = ClaudeHost.forCurrentPlatform();
  final launcher = LauncherController(
    host: host,
    store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
  );
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  launcher.setParallelLaunch(settings.parallelLaunch);
  settings.addListener(
    () => launcher.setParallelLaunch(settings.parallelLaunch),
  );
  // Страну узнаём сразу, пока грузится остальное: к запуску профиля по
  // умолчанию ответ обычно уже готов.
  final location = LocationGuard(settings: settings);
  if (settings.locationCheck) unawaited(location.check());
  final window = AppWindow();
  final notifier = SystemNotifier();
  final claudeCode = ClaudeCodeIntegration(
    settings: settings,
    launcher: launcher,
    windowVisible: window.visible,
    registry: CodeSessionRegistry(
      File(p.join(supportDir.path, 'code-session-registry.json')),
    ),
    handoff: _handoff(supportDir, host),
    notifier: notifier,
    onOpenWindow: window.show,
  );
  launcher.onNeedsAttention = window.show;
  launcher.launchGuard = location.ensureCanLaunch;
  // Окно открыли — страна могла смениться вместе с сетью: свежий ответ
  // переиспользуется, старый перепроверяется. Пока запускать нельзя, страна
  // перепроверяется и сама.
  window.visible.addListener(() {
    if (window.visible.value && settings.locationCheck) location.check();
  });
  location.recheckWhile(window.visible);
  // Эксперимент: закрыть Claude, если сменилась страна выхода (отключился VPN).
  final killSwitch = KillSwitch(
    settings: settings,
    location: location,
    launcher: launcher,
    notifier: notifier,
    onFired: window.show,
    onLog: _killSwitchLog(supportDir, 'лаунчер'),
  );
  // «Скрывать значок Claude» — настройкой самого Claude в папке профиля.
  final trayIcon = ClaudeTrayIcon(settings: settings, launcher: launcher);
  launcher.prepareClaudeCode = (profile, dir) async {
    await ProfileClaudeCode(
      dir: dir,
      shared: ProfileClaudeCode.sharedDir(Platform.environment),
    ).prepare();
    await claudeCode.prepareProfile(profile, dir);
  };
  // Windows: правило брандмауэра для службы Cowork (см. настройки Kill Switch).
  final coworkFirewall = Platform.isWindows ? CoworkFirewall() : null;
  unawaited(coworkFirewall?.refresh());
  // При Kill Switch и в параллельном режиме Claude обновляет лаунчер.
  final claudeUpdates = ClaudeUpdates(
    host: launcher.host,
    launcher: launcher,
    killSwitch: killSwitch,
    settings: settings,
  );
  // Перед запуском профиля: уведомления Claude — лаунчеру; в параллельном
  // режиме выключить встроенное обновление (иначе один экземпляр заменил бы
  // Claude под работающими соседями); при Kill Switch — закрепить профиль за
  // затвором. Claude читает всё это при запуске.
  launcher.beforeLaunch = (dataDir) async {
    await claudeCode.beforeLaunch(dataDir);
    await trayIcon.beforeLaunch(dataDir);
    await claudeUpdates.beforeLaunch(dataDir);
    await killSwitch.beforeLaunch(dataDir);
  };
  final sessionSync = SessionSyncService(
    launcher: launcher,
    settings: settings,
    supportDir: supportDir,
  )..start();
  // Ссылки `claude://` — нужному профилю.
  final linkPlatform = LinkHandlerPlatform.forCurrentPlatform();
  final links = linkPlatform != null
      ? ClaudeLinkHandler(
          launcher: launcher,
          settings: settings,
          platform: linkPlatform,
          sessionOwner: (id) async {
            for (final entry in await SessionOverview.read(launcher)) {
              if (entry.sessions.any((card) => card.id == id)) {
                return entry.profile;
              }
            }
            return null;
          },
          choose: (candidates, kind) async {
            await window.show();
            final context = _navigatorKey.currentContext;
            if (context == null || !context.mounted) return null;
            return showLinkProfileDialog(
              context,
              candidates: candidates,
              kind: kind,
            );
          },
        )
      : null;

  // Окно создаётся скрытым: приложение живёт в трее, окно — только для настроек.
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'ClaudeLauncher',
      size: const Size(580, 700),
      minimumSize: const Size(480, 480),
      center: true,
      skipTaskbar: true,
      // На macOS контент заходит под заголовок, как в веб-проектах: белое окно без полосы.
      titleBarStyle: Platform.isMacOS
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal,
    ),
    () => windowManager.setPreventClose(true),
  );

  late final TrayController tray;
  // Выход — из меню значка и перед установкой обновления. При обновлении
  // уведомления у Claude не забираем назад и наблюдателя не запускаем: новая
  // версия запустится сразу и заберёт их сама, а наблюдатель — тот же exe —
  // на Windows не дал бы установщику заменить файлы.
  Future<void> quit({bool updating = false}) async {
    await claudeCode.flushSessions();
    try {
      if (!updating && await claudeCode.releaseOnQuit()) {
        await _startWatcher([
          for (final instance in launcher.instances) instance.pid,
        ]);
      }
    } catch (error) {
      debugPrint('Не удалось вернуть уведомления Claude: $error');
    }
    // Kill Switch: открытый Claude закреплён за затвором — без него он
    // останется без сети. Затвор держит охранник, пока Claude не закроют;
    // при обновлении — новая версия.
    try {
      final guard =
          !updating && killSwitch.serving && launcher.instances.isNotEmpty;
      final passthrough = killSwitch.passthrough;
      await killSwitch.shutdown(keepPinned: guard || updating);
      if (guard) {
        final process = await Process.start(Platform.resolvedExecutable, [
          _guardFlag,
          if (passthrough) _passthroughFlag,
        ], mode: ProcessStartMode.detached);
        // Сразу, а не когда охранник загрузится: лаунчер, запущенный снова в
        // эту секунду, должен его найти.
        await _guardPidFile(supportDir).writeAsString('${process.pid}');
      }
    } catch (error) {
      debugPrint('Kill Switch: не удалось передать затвор охраннику: $error');
    }
    // Роль обработчика `claude://` — обратно Claude: без лаунчера ссылки
    // запускали бы его, а не Claude. При обновлении новая версия заберёт её сама.
    if (!updating) await links?.release();
    await tray.dispose();
    exit(0);
  }

  /// Windows завершает сеанс (выход, перезагрузка) или установщик закрывает
  /// лаунчер: быстрый корректный выход — runner ждёт его до 4 секунд, —
  /// без наблюдателя и охранника: их процессы Windows тоже завершит. Kill
  /// Switch остаётся закреплённым: защиту не ослабляем — Claude не пойдёт
  /// мимо затвора, а затвор поднимет лаунчер при следующем запуске.
  Future<void> endSession() async {
    try {
      await claudeCode.releaseOnQuit().timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('Не удалось вернуть уведомления Claude: $error');
    }
    try {
      await killSwitch.shutdown(keepPinned: true);
    } catch (error) {
      debugPrint('Kill Switch: не удалось остановить затвор: $error');
    }
    // Сначала ответ runner'у, потом выход.
    Timer(const Duration(milliseconds: 200), () => exit(0));
  }

  // Версия из самого приложения — её Flutter берёт из pubspec.yaml.
  final version = (await PackageInfo.fromPlatform()).version;
  final updater = AppUpdater(
    currentVersion: version,
    settings: settings,
    quit: () => quit(updating: true),
  );
  tray = TrayController(
    launcher: launcher,
    location: location,
    updater: updater,
    onShowWindow: window.show,
    onQuit: quit,
  );
  // Лаунчер запустили ещё раз (Finder, «Объекты входа», значок в Dock): второй
  // экземпляр система не запускает, а сообщает этому — показываем окно.
  // Выход из Dock или ⌘Q — тем же путём, что из меню значка.
  _nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'reopen') await window.show();
    if (call.method == 'quit') await quit();
    if (call.method == 'endSession') await endSession();
    if (call.method == 'networkChanged') await killSwitch.networkChanged();
    if (call.method == 'linksArrived') await links?.drain();
    if (call.method == 'openUrl' && call.arguments is String) {
      await links?.handleString(call.arguments as String);
    }
  });
  // Окно открыли — заодно проверим обновления, если давно не проверяли.
  window.visible.addListener(() {
    if (window.visible.value) updater.checkIfStale();
  });
  // Значок в Dock — по настройке (macOS).
  if (Platform.isMacOS) {
    var dockIcon = settings.dockIcon;
    if (dockIcon) await windowManager.setSkipTaskbar(false);
    settings.addListener(() {
      if (settings.dockIcon == dockIcon) return;
      dockIcon = settings.dockIcon;
      windowManager.setSkipTaskbar(!dockIcon);
    });
  }
  runApp(
    ClaudeLauncherApp(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
      location: location,
      updater: updater,
      killSwitch: killSwitch,
      claudeUpdates: claudeUpdates,
      coworkFirewall: coworkFirewall,
      sessionSync: sessionSync,
      links: links,
      version: version,
    ),
  );
  // Экран лаунчера — сразу: на нём видно, как проверяется страна и
  // открывается профиль по умолчанию.
  await window.show();
  await tray.init();
  updater.start();
  try {
    await launcher.init();
  } catch (error) {
    launcher.lastError = 'Не удалось загрузить профили: $error';
    await window.show();
    return;
  }

  // Повторно при каждом запуске: на Windows после обновления Claude у его
  // значка появляется новая запись, которую тоже нужно спрятать.
  if (settings.hideClaudeIcon) await launcher.setClaudeIconHidden(true);
  trayIcon.start();
  // Windows: и пока Claude открыт — запись появляется, когда он показал
  // значок, а не когда запустился лаунчер. Это для Claude, открытого до
  // включения настройки: значок уйдёт под стрелку ▲, а совсем пропадёт после
  // перезапуска Claude.
  if (Platform.isWindows) {
    ClaudeIconKeeper(settings: settings, launcher: launcher).start();
  }

  await _stopWaitingWatchers();
  await _stopKillSwitchGuard(supportDir, launcher.host);
  killSwitch.handover = await _takeHandover(
    supportDir,
    launcher.host,
    settings,
  );
  killSwitch.start();
  claudeUpdates.start();
  // Оповещения внизу окна: подсказка, вышедшие обновления и их итог.
  Announcements(
    settings: settings,
    updater: updater,
    claudeUpdates: claudeUpdates,
  ).start();
  // На macOS о смене сети сообщает MainFlutterWindow (networkChanged), на
  // Windows — сама система через iphlpapi.
  if (Platform.isWindows) {
    WindowsNetworkWatch().start(killSwitch.networkChanged);
  }

  // Приём событий Claude Code, если пользователь его включил.
  await claudeCode.start();
  // Лаунчер запустили нажатием на его уведомление — открыть ту сессию.
  await claudeCode.openLaunchNotification();
  // До профиля по умолчанию: если лаунчер запустила ссылка, её профиль
  // откроется первым, а профиль по умолчанию тогда не откроется.
  await links?.start(initial: _openUrlArguments(args));

  // Первый запуск: окно приветствия с настройками.
  if (!settings.onboardingDone) {
    final context = _navigatorKey.currentContext;
    if (context != null && context.mounted) {
      await showWelcomeDialog(
        context,
        launcher: launcher,
        settings: settings,
        claudeCode: claudeCode,
      );
    }
  }

  // Перед запуском профиль ждёт проверку страны (LocationGuard.ensureCanLaunch),
  // а она идёт с самого начала запуска. Окно лаунчера остаётся над Claude.
  await window.keepInFrontDuring(
    settings.parallelLaunch
        ? launcher
              .openOnStartupProfiles(settings.startupProfileIds)
              .then((count) => count > 0)
        : launcher.openOnStartup(settings.startupProfileId),
  );
}

/// До переименования в ClaudeLauncher папка данных на Windows называлась
/// «Claude Launcher»: её имя берётся из названия продукта в exe. Переносим
/// оттуда профили и настройки, если на новом месте их ещё нет.
Future<void> _moveRenamedSupportDir(Directory supportDir) async {
  if (!Platform.isWindows) return;
  final old = Directory(p.join(p.dirname(supportDir.path), 'Claude Launcher'));
  if (!await old.exists()) return;
  try {
    await for (final entity in old.list()) {
      if (entity is! File) continue;
      final target = File(p.join(supportDir.path, p.basename(entity.path)));
      if (!await target.exists()) await entity.copy(target.path);
    }
    await old.delete(recursive: true);
  } catch (error) {
    debugPrint('Не удалось перенести данные из ${old.path}: $error');
  }
}

NotificationHandoff _handoff(Directory supportDir, ClaudeHost host) =>
    NotificationHandoff(
      stateFile: File(p.join(supportDir.path, 'claude-notifications.json')),
      hooks: ClaudeCodeHooks.forCurrentUser(),
      samePath: host.samePath,
    );

/// Лаунчер завершается, а открытым Claude уведомления вернуть пока нельзя:
/// оставляем вместо себя наблюдателя.
///
/// На macOS закрытия Claude ([claudePids]) ждёт оболочка, а лаунчер
/// запускается, только чтобы вернуть настройки: пока работает процесс из
/// бандла, Finder не даёт заменить приложение новой версией, а повторный
/// запуск попал бы в этот процесс. На Windows установщик сам закрывает
/// наблюдателя, поэтому ждёт он сам.
Future<void> _startWatcher(List<int> claudePids) async {
  if (Platform.isMacOS) {
    final anyRunning = claudePids.isEmpty
        ? 'false'
        : claudePids.map((pid) => 'kill -0 $pid 2>/dev/null').join(' || ');
    await Process.start('/bin/sh', [
      '-c',
      'while $anyRunning; do sleep 3; done; exec "\$0" $_watcherFlag',
      Platform.resolvedExecutable,
    ], mode: ProcessStartMode.detached);
    return;
  }
  await Process.start(Platform.resolvedExecutable, [
    _watcherFlag,
  ], mode: ProcessStartMode.detached);
}

File _guardPidFile(Directory supportDir) =>
    File(p.join(supportDir.path, 'kill-switch-guard.pid'));

/// Лаунчер снова запущен — охранник Kill Switch больше не нужен: затвор
/// поднимет сам лаунчер. Конфигурацию Claude охранник не убирает — она нужна.
///
/// pid-файл мог остаться от охранника, которого завершила система (выход из
/// сеанса, установщик), а pid — достаться другому процессу. Поэтому
/// завершаем, только если это и правда наш охранник.
Future<void> _stopKillSwitchGuard(Directory supportDir, ClaudeHost host) async {
  final file = _guardPidFile(supportDir);
  try {
    final guardPid = int.tryParse((await file.readAsString()).trim());
    await file.delete();
    if (guardPid == null || guardPid == pid) return;
    final commandLine = await host.commandLineOf(guardPid);
    final executable = p.basename(Platform.resolvedExecutable).toLowerCase();
    if (commandLine == null ||
        !commandLine.contains(_guardFlag) ||
        !commandLine.toLowerCase().contains(executable)) {
      return;
    }
    Process.killPid(guardPid);
    // Порт затвора освобождается не мгновенно.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  } on FileSystemException {
    // Охранника нет.
  }
}

/// Журнал Kill Switch — `kill-switch.log` в папке лаунчера: что делал затвор,
/// когда Claude остался без сети. Последние ~256 КБ, без адресов сети.
void Function(String) _killSwitchLog(Directory supportDir, String who) {
  final file = File(p.join(supportDir.path, 'kill-switch.log'));
  return (message) {
    try {
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        final text = file.readAsStringSync();
        file.writeAsStringSync(text.substring(text.length ~/ 2));
      }
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [$who $pid] $message\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // Журнал — подспорье; без него лаунчер работает так же.
    }
  };
}

File _handoverFile(Directory supportDir) =>
    File(p.join(supportDir.path, 'kill-switch-handover.json'));

Future<void> _writeHandover(
  Directory supportDir, {
  required int port,
  required List<int> claudePids,
}) async {
  try {
    await _handoverFile(
      supportDir,
    ).writeAsString(jsonEncode({'port': port, 'pids': claudePids}));
  } on FileSystemException catch (error) {
    debugPrint('Kill Switch: не удалось оставить записку: $error');
  }
}

/// Записка закрытого охранника: Claude, открытый через затвор, ещё работает —
/// затвор нужен ему на том же порту. Записка одноразовая.
Future<bool> _takeHandover(
  Directory supportDir,
  ClaudeHost host,
  AppSettings settings,
) async {
  final file = _handoverFile(supportDir);
  try {
    final json = jsonDecode(await file.readAsString());
    await file.delete();
    if (json is! Map) return false;
    final port = json['port'];
    final pids = json['pids'];
    if (port is! int || pids is! List) return false;
    for (final claudePid in pids.whereType<int>()) {
      final commandLine = await host.commandLineOf(claudePid);
      if (commandLine != null && commandLine.contains('Claude')) {
        if (settings.egressPort != port) await settings.setEgressPort(port);
        return true;
      }
    }
  } on FileSystemException {
    // Записки нет.
  } on FormatException {
    // Испорчена — не нужна.
  }
  return false;
}

/// Охранник Kill Switch: из лаунчера вышли, а открытый Claude закреплён за его
/// затвором. Держит затвор и следит за сетью, пока Claude открыт; потом
/// убирает конфигурацию Claude и уходит. Без окна и значка.
///
/// На macOS повторный запуск лаунчера система передаёт этому процессу — тогда
/// охранник запускает свежий лаунчер ([_openFreshLauncher]) и держит затвор,
/// пока тот не заберёт работу: новый лаунчер находит охранника по pid-файлу и
/// завершает (так же и на Windows). Самому становиться лаунчером охраннику
/// нельзя: в таком процессе не определялась страна, и Claude оставался без
/// сети, а после обновления в памяти ещё и старый код.
Future<bool> _guardKillSwitch(
  Directory supportDir, {
  required bool passthrough,
}) async {
  final pidFile = _guardPidFile(supportDir);
  await pidFile.writeAsString('$pid');
  final log = _killSwitchLog(supportDir, 'охранник');
  // Охранника закрывают по имени (⌘Q не дойдёт — окна нет, но так делает,
  // например, команда установки): снимаем настройку, чтобы Claude не остался
  // без сети, если лаунчер больше не запустят.
  final quitRequested = Completer<void>();

  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  final launcher = LauncherController(
    host: ClaudeHost.forCurrentPlatform(),
    store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
  );
  await launcher.init();
  final location = LocationGuard(settings: settings);
  final killSwitch = KillSwitch(
    settings: settings,
    location: location,
    launcher: launcher,
    notifier: SystemNotifier(),
    exactPort: true,
    passthrough: passthrough,
    onLog: log,
  );
  _nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'networkChanged') await killSwitch.networkChanged();
    if (Platform.isMacOS && call.method == 'reopen') {
      log('лаунчер открыли снова — запускаю его');
      await _openFreshLauncher();
    }
    if (call.method == 'quit' && !quitRequested.isCompleted) {
      quitRequested.complete();
    }
  });
  final windowsWatch = Platform.isWindows ? WindowsNetworkWatch() : null;
  windowsWatch?.start(killSwitch.networkChanged);
  killSwitch.start();

  bool ours() {
    try {
      return pidFile.readAsStringSync().trim() == '$pid';
    } on FileSystemException {
      return false;
    }
  }

  // Затвор поднимается не мгновенно — serving уже true (armed или passthrough).
  while (!quitRequested.isCompleted &&
      killSwitch.serving &&
      launcher.instances.isNotEmpty &&
      ours()) {
    await Future.any([
      Future<void>.delayed(const Duration(seconds: 2)),
      quitRequested.future,
    ]);
    await launcher.refresh();
  }
  windowsWatch?.stop();
  final quit = quitRequested.isCompleted;
  final stillOurs = ours();
  // Закрыли, а Claude ещё открыт: настройку снимаем, но оставляем записку —
  // если лаунчер запустят следом (команда установки), он поднимет затвор на
  // том же порту, и этот Claude сети не потеряет.
  if (quit && stillOurs && launcher.instances.isNotEmpty) {
    await _writeHandover(
      supportDir,
      port: killSwitch.gate.port ?? settings.egressPort,
      claudePids: [for (final instance in launcher.instances) instance.pid],
    );
  }
  log(
    'выход: закрыли — $quit, затвор ещё его — $stillOurs, '
    'открытых Claude — ${launcher.instances.length}',
  );
  // Claude закрыт или охранника закрыли — конфигурация не нужна; работу
  // забрал лаунчер — она нужна ему.
  await killSwitch.shutdown(keepPinned: !quit && !stillOurs);
  killSwitch.dispose();
  location.dispose();
  launcher.dispose();
  if (stillOurs) {
    try {
      await pidFile.delete();
    } on FileSystemException {
      // Уже удалён.
    }
  }
  return false;
}

/// Свежий экземпляр лаунчера из его приложения на диске (`open -n`: иначе
/// macOS снова передаст запуск этому фоновому процессу). Не чаще раза в 10 с —
/// повторные нажатия, пока он запускается, не плодят экземпляры.
Future<void> _openFreshLauncher() async {
  final now = DateTime.now();
  if (_freshLaunchAt case final at?
      when now.difference(at) < const Duration(seconds: 10)) {
    return;
  }
  _freshLaunchAt = now;
  // …/ClaudeLauncher.app/Contents/MacOS/ClaudeLauncher → …/ClaudeLauncher.app
  final bundle = p.dirname(
    p.dirname(p.dirname(File(Platform.resolvedExecutable).path)),
  );
  try {
    await Process.start('open', [
      '-n',
      bundle,
    ], mode: ProcessStartMode.detached);
  } catch (error) {
    debugPrint('Не удалось запустить лаунчер: $error');
  }
}

DateTime? _freshLaunchAt;

/// Лаунчер снова запущен и забирает уведомления себе — оболочки, которые ждут
/// закрытия Claude после прошлых выходов (см. [_startWatcher]), больше не
/// нужны, а иначе копятся. Наблюдателей, которые уже возвращают уведомления,
/// не трогаем: они уйдут сами, увидев, что настройки у лаунчера. На Windows
/// ждёт сам наблюдатель и уходит так же.
Future<void> _stopWaitingWatchers() async {
  if (!Platform.isMacOS) return;
  try {
    await Process.run('pkill', [
      '-f',
      r'^/bin/sh -c while .*; do sleep 3; done; exec "\$0" '
          '$_watcherFlag',
    ]);
  } catch (error) {
    debugPrint('Не удалось убрать ожидающих наблюдателей: $error');
  }
}

/// Наблюдатель: лаунчер закрыли при открытом Claude, у которого он выключил
/// уведомления. Claude держит настройки в памяти и перезаписал бы файл,
/// поэтому вернуть их можно только после его закрытия — ждём и возвращаем.
/// Если лаунчер тем временем запустили снова, он забирает всё себе, а
/// наблюдатель уходит.
///
/// На macOS повторный запуск система передаёт этому же процессу (второй
/// экземпляр не запускает) — тогда наблюдатель запускает свежий лаунчер
/// ([_openFreshLauncher]) и уходит, когда тот заберёт настройки себе.
Future<bool> _returnClaudeNotifications(Directory supportDir) async {
  // Только macOS: на Windows повторный запуск будит запущенный лаунчер, а не
  // наблюдателя — тот уйдёт сам, когда новый лаунчер заберёт настройки.
  _nativeChannel.setMethodCallHandler((call) async {
    if (Platform.isMacOS && call.method == 'reopen') await _openFreshLauncher();
  });
  final host = ClaudeHost.forCurrentPlatform();
  final handoff = _handoff(supportDir, host);
  if (!await handoff.claim(onlyIfFree: true)) return false;
  try {
    // На Windows от установки Claude зависит его стандартная папка.
    await host.locate();
  } catch (error) {
    debugPrint('Не удалось найти Claude: $error');
  }
  while (true) {
    try {
      final result = await handoff.sync(
        active: false,
        profiles: const [],
        running: [
          for (final instance in await host.running()) host.dataDirOf(instance),
        ],
      );
      // Всё вернули — или лаунчер запустили снова и настройки теперь у него.
      if (!result.pending) break;
    } catch (error) {
      debugPrint('Не удалось вернуть уведомления Claude: $error');
    }
    await Future<void>.delayed(host.pollInterval);
  }
  await handoff.resign();
  return false;
}

/// Удаление лаунчера: убирает его хуки из `~/.claude/settings.json`, возвращает
/// значок и уведомления Claude, снимает прокси Kill Switch с профилей — иначе
/// Claude без лаунчера остался бы без сети. Профили Claude и их данные не
/// трогает.
Future<void> _cleanup(Directory supportDir) async {
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  // Ссылки `claude://` — снова Claude.
  try {
    final links = LinkHandlerPlatform.forCurrentPlatform();
    await links?.restore(settings.previousLinkHandler);
    await links?.removeShortcuts();
  } catch (error) {
    debugPrint('Не удалось вернуть обработчик claude://: $error');
  }
  final host = ClaudeHost.forCurrentPlatform();
  await ClaudeHost.removeQuietly(
    p.join(supportDir.path, 'code-session-registry.json'),
  );
  // Windows: правило брандмауэра для Cowork — Windows спросит разрешение.
  if (Platform.isWindows) {
    final firewall = CoworkFirewall();
    await firewall.refresh();
    if (firewall.active ?? false) await firewall.disable();
  }
  try {
    await _stopKillSwitchGuard(supportDir, host);
    final launcher = LauncherController(
      host: host,
      store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
    );
    await launcher.init();
    for (final profile in launcher.profiles) {
      await const EgressConfig().unpin(launcher.dataDirOf(profile));
    }
  } catch (error) {
    debugPrint('Не удалось снять прокси Kill Switch: $error');
  }
  try {
    await ClaudeCodeHooks.forCurrentUser().uninstall();
    // И из своих папок Claude Code профилей.
    final launcher = LauncherController(
      host: host,
      store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
    );
    await launcher.init();
    for (final profile in launcher.profiles) {
      if (launcher.claudeConfigDirOf(profile) case final dir?) {
        await ClaudeCodeHooks(File(p.join(dir, 'settings.json'))).uninstall();
      }
    }
  } catch (error) {
    debugPrint('Не удалось убрать хуки Claude Code: $error');
  }
  try {
    final handoff = _handoff(supportDir, host);
    await handoff.claim();
    await host.locate();
    // Даже у открытых Claude: наблюдателя после удаления уже не будет.
    await handoff.sync(
      active: false,
      profiles: const [],
      running: const [],
      force: true,
    );
  } catch (error) {
    debugPrint('Не удалось вернуть уведомления Claude: $error');
  }
  if (settings.hideClaudeIcon) {
    try {
      final launcher = LauncherController(
        host: host,
        store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
      );
      await launcher.init();
      final trayIcon = ClaudeTrayIcon(settings: settings, launcher: launcher);
      for (final profile in launcher.profiles) {
        await trayIcon.apply(launcher.dataDirOf(profile), hidden: false);
      }
    } catch (error) {
      debugPrint('Не удалось вернуть значок Claude: $error');
    }
    try {
      await host.setClaudeIconHidden(false);
    } catch (error) {
      debugPrint('Не удалось вернуть значок Claude: $error');
    }
  }
}

class ClaudeLauncherApp extends StatelessWidget {
  const ClaudeLauncherApp({
    super.key,
    required this.launcher,
    required this.settings,
    required this.claudeCode,
    required this.location,
    required this.updater,
    required this.killSwitch,
    required this.claudeUpdates,
    this.coworkFirewall,
    this.sessionSync,
    this.links,
    required this.version,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;
  final AppUpdater updater;
  final KillSwitch killSwitch;
  final ClaudeUpdates claudeUpdates;
  final CoworkFirewall? coworkFirewall;
  final SessionSyncService? sessionSync;
  final ClaudeLinkHandler? links;
  final String version;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'ClaudeLauncher',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: settings.themeMode,
        home: HomePage(
          launcher: launcher,
          settings: settings,
          claudeCode: claudeCode,
          location: location,
          updater: updater,
          killSwitch: killSwitch,
          claudeUpdates: claudeUpdates,
          coworkFirewall: coworkFirewall,
          sessionSync: sessionSync,
          links: links,
          version: version,
        ),
      ),
    );
  }
}

/// Ссылки из `--open-url <ссылка>`: так Windows запускает лаунчер как
/// обработчик `claude://`.
List<String> _openUrlArguments(List<String> args) => [
  for (var i = 0; i + 1 < args.length; i++)
    if (args[i] == '--open-url') args[i + 1],
];
