import 'dart:async';
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
import 'src/integrations/notification_handoff.dart';
import 'src/launcher_controller.dart';
import 'src/location/location_guard.dart';
import 'src/notifications.dart';
import 'src/profile_store.dart';
import 'src/tray.dart';
import 'src/ui/home_page.dart';
import 'src/ui/settings_dialog.dart';
import 'src/ui/theme.dart';

/// Нужен, чтобы показать окно приветствия из main(), вне дерева виджетов.
final _navigatorKey = GlobalKey<NavigatorState>();

/// Канал к нативной части (см. MainFlutterWindow.swift); оттуда приходит `reopen`.
const _nativeChannel = MethodChannel('claude_launcher/native');

/// Запуск наблюдателя, который вернёт Claude уведомления после выхода из лаунчера.
const _watcherFlag = '--return-claude-notifications';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  await _moveRenamedSupportDir(supportDir);

  // Запускает деинсталлятор Windows: убираем за собой и выходим, окно не показываем.
  if (args.contains('--cleanup')) {
    await _cleanup(supportDir);
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
  // Страну узнаём сразу, пока грузится остальное: к запуску профиля по
  // умолчанию ответ обычно уже готов.
  final location = LocationGuard(settings: settings);
  if (settings.locationCheck) unawaited(location.check());
  final window = AppWindow();
  final claudeCode = ClaudeCodeIntegration(
    settings: settings,
    launcher: launcher,
    windowVisible: window.visible,
    handoff: _handoff(supportDir, host),
    notifier: SystemNotifier(),
    onOpenWindow: window.show,
  );
  launcher.onNeedsAttention = window.show;
  launcher.beforeLaunch = claudeCode.beforeLaunch;
  launcher.launchGuard = location.ensureCanLaunch;
  // Окно открыли — страна могла смениться вместе с сетью: свежий ответ
  // переиспользуется, старый перепроверяется. Пока запускать нельзя, страна
  // перепроверяется и сама.
  window.visible.addListener(() {
    if (window.visible.value && settings.locationCheck) location.check();
  });
  location.recheckWhile(window.visible);
  // Лаунчер запустили ещё раз (Finder, «Объекты входа»): второй экземпляр
  // macOS не запускает, а сообщает этому — показываем окно.
  _nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'reopen') await window.show();
  });

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
  tray = TrayController(
    launcher: launcher,
    location: location,
    onShowWindow: window.show,
    onQuit: () async {
      try {
        if (await claudeCode.releaseOnQuit()) {
          await _startWatcher([
            for (final instance in launcher.instances) instance.pid,
          ]);
        }
      } catch (error) {
        debugPrint('Не удалось вернуть уведомления Claude: $error');
      }
      await tray.dispose();
      exit(0);
    },
  );

  // Версия из самого приложения — её Flutter берёт из pubspec.yaml.
  final version = (await PackageInfo.fromPlatform()).version;
  runApp(
    ClaudeLauncherApp(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
      location: location,
      version: version,
    ),
  );
  // Экран лаунчера — сразу: на нём видно, как проверяется страна и
  // открывается профиль по умолчанию.
  await window.show();
  await tray.init();
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

  // Приём событий Claude Code, если пользователь его включил.
  await claudeCode.start();

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
    launcher.openOnStartup(settings.startupProfileId),
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

/// Наблюдатель: лаунчер закрыли при открытом Claude, у которого он выключил
/// уведомления. Claude держит настройки в памяти и перезаписал бы файл,
/// поэтому вернуть их можно только после его закрытия — ждём и возвращаем.
/// Если лаунчер тем временем запустили снова, он забирает всё себе, а
/// наблюдатель уходит.
///
/// На macOS повторный запуск система передаёт этому же процессу (второй
/// экземпляр не запускает) — тогда наблюдатель сам становится лаунчером:
/// возвращает `true`, и main() продолжает обычный запуск. Но если за это время
/// лаунчер обновили, в памяти у наблюдателя старый код: он запускает новую
/// версию и уходит.
Future<bool> _returnClaudeNotifications(Directory supportDir) async {
  final executable = File(Platform.resolvedExecutable);
  final startedAs = executable.statSync();
  final reopened = Completer<void>();
  _nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'reopen' && !reopened.isCompleted) reopened.complete();
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
  while (!reopened.isCompleted) {
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
    await Future.any([
      Future<void>.delayed(host.pollInterval),
      reopened.future,
    ]);
  }
  await handoff.resign();
  if (!reopened.isCompleted) return false;
  final FileStat now;
  try {
    now = executable.statSync();
  } on FileSystemException {
    return false;
  }
  if (now.modified == startedAs.modified && now.size == startedAs.size) {
    return true;
  }
  // …/ClaudeLauncher.app/Contents/MacOS/ClaudeLauncher → …/ClaudeLauncher.app
  final bundle = p.dirname(p.dirname(p.dirname(executable.path)));
  await Process.start('open', ['-n', bundle], mode: ProcessStartMode.detached);
  return false;
}

/// Удаление лаунчера: убирает его хуки из `~/.claude/settings.json`, возвращает
/// значок и уведомления Claude. Профили Claude и их данные не трогает.
Future<void> _cleanup(Directory supportDir) async {
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  final host = ClaudeHost.forCurrentPlatform();
  try {
    await ClaudeCodeHooks.forCurrentUser().uninstall();
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
    required this.version,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;
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
          version: version,
        ),
      ),
    );
  }
}
