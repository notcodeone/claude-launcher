import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_settings.dart';
import 'src/app_window.dart';
import 'src/claude/claude_host.dart';
import 'src/integrations/claude_code_hooks.dart';
import 'src/integrations/claude_code_integration.dart';
import 'src/launcher_controller.dart';
import 'src/profile_store.dart';
import 'src/tray.dart';
import 'src/ui/home_page.dart';
import 'src/ui/settings_dialog.dart';
import 'src/ui/theme.dart';

/// Нужен, чтобы показать окно приветствия из main(), вне дерева виджетов.
final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  await _moveRenamedSupportDir(supportDir);

  // Запускает деинсталлятор Windows: убираем за собой и выходим, окно не показываем.
  if (args.contains('--cleanup')) {
    await _cleanup(supportDir);
    exit(0);
  }

  await windowManager.ensureInitialized();
  final launcher = LauncherController(
    host: ClaudeHost.forCurrentPlatform(),
    store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
  );
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  final window = AppWindow();
  final claudeCode = ClaudeCodeIntegration(
    settings: settings,
    launcher: launcher,
    windowVisible: window.visible,
  );
  launcher.onNeedsAttention = window.show;

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
    onShowWindow: window.show,
    onQuit: () async {
      await tray.dispose();
      exit(0);
    },
  );

  runApp(
    ClaudeLauncherApp(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
    ),
  );
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

  // Первый запуск: окно приветствия с настройками. Заодно видно, что
  // приложение запустилось, хотя живёт в трее.
  if (!settings.onboardingDone) {
    await window.show();
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

  await launcher.openOnStartup(settings.startupProfileId);
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

/// Удаление лаунчера: убирает его хуки из `~/.claude/settings.json` и
/// возвращает значок Claude. Профили Claude и их данные не трогает.
Future<void> _cleanup(Directory supportDir) async {
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  try {
    await ClaudeCodeHooks.forCurrentUser().uninstall();
  } catch (error) {
    debugPrint('Не удалось убрать хуки Claude Code: $error');
  }
  if (settings.hideClaudeIcon) {
    try {
      await ClaudeHost.forCurrentPlatform().setClaudeIconHidden(false);
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
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;

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
        ),
      ),
    );
  }
}
