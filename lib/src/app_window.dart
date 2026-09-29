import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Окно настроек: прячется при закрытии, само приложение живёт в трее.
class AppWindow with WindowListener {
  AppWindow() {
    windowManager.addListener(this);
  }

  Future<void> show() async {
    if (Platform.isWindows) await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() async {
    await windowManager.hide();
    if (Platform.isWindows) await windowManager.setSkipTaskbar(true);
  }

  @override
  void onWindowClose() => hide();
}
