import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_settings.dart';
import 'src/app_window.dart';
import 'src/claude/claude_host.dart';
import 'src/launcher_controller.dart';
import 'src/profile_store.dart';
import 'src/tray.dart';
import 'src/ui/home_page.dart';
import 'src/ui/settings_dialog.dart';
import 'src/ui/theme.dart';

/// Нужен, чтобы показать окно приветствия из main(), вне дерева виджетов.
final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final launcher = LauncherController(
    host: ClaudeHost.forCurrentPlatform(),
    store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
  );
  final settings = AppSettings(File(p.join(supportDir.path, 'settings.json')));
  await settings.load();
  final window = AppWindow();
  launcher.onNeedsAttention = window.show;

  // Окно создаётся скрытым: приложение живёт в трее, окно — только для настроек.
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'Claude Launcher',
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
    onOpenSettings: window.show,
    onQuit: () async {
      await tray.dispose();
      exit(0);
    },
  );

  runApp(ClaudeLauncherApp(launcher: launcher, settings: settings));
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

  // Первый запуск: окно приветствия с настройками. Заодно видно, что
  // приложение запустилось, хотя живёт в трее.
  if (!settings.onboardingDone) {
    await window.show();
    final context = _navigatorKey.currentContext;
    if (context != null && context.mounted) {
      await showWelcomeDialog(context, launcher: launcher, settings: settings);
    }
  }

  await launcher.openOnStartup(settings.startupProfileId);
}

class ClaudeLauncherApp extends StatelessWidget {
  const ClaudeLauncherApp({
    super.key,
    required this.launcher,
    required this.settings,
  });

  final LauncherController launcher;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'Claude Launcher',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: settings.themeMode,
        home: HomePage(launcher: launcher, settings: settings),
      ),
    );
  }
}
