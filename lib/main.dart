import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_window.dart';
import 'src/claude/claude_host.dart';
import 'src/launcher_controller.dart';
import 'src/profile_store.dart';
import 'src/tray.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final launcher = LauncherController(
    host: ClaudeHost.forCurrentPlatform(),
    store: ProfileStore(File(p.join(supportDir.path, 'profiles.json'))),
  );
  final window = AppWindow();
  launcher.onNeedsAttention = window.show;

  // Окно создаётся скрытым: приложение живёт в трее, окно — только для настроек.
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Claude Launcher',
      size: Size(560, 640),
      minimumSize: Size(460, 420),
      center: true,
      skipTaskbar: true,
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

  runApp(ClaudeLauncherApp(launcher: launcher));
  await tray.init();
  try {
    await launcher.init();
    // Иначе после первого запуска непонятно, запустилось ли приложение без окна.
    if (launcher.firstRun) await window.show();
  } catch (error) {
    launcher.lastError = 'Не удалось загрузить профили: $error';
    await window.show();
  }
}

class ClaudeLauncherApp extends StatelessWidget {
  const ClaudeLauncherApp({super.key, required this.launcher});

  final LauncherController launcher;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4F46E5),
            brightness: brightness,
          ),
        );
    return MaterialApp(
      title: 'Claude Launcher',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomePage(launcher: launcher),
    );
  }
}
