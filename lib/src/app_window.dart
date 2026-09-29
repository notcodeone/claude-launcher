import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Окно настроек: прячется при закрытии, само приложение живёт в трее.
class AppWindow with WindowListener {
  AppWindow() {
    windowManager.addListener(this);
  }

  /// Видно ли окно. Пока оно закрыто или свёрнуто, лаунчер не считает время
  /// и токены сессий Claude Code.
  final visible = ValueNotifier<bool>(false);

  Future<void> show() async {
    if (Platform.isWindows) await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    visible.value = true;
  }

  Future<void> hide() async {
    visible.value = false;
    await windowManager.hide();
    if (Platform.isWindows) await windowManager.setSkipTaskbar(true);
  }

  @override
  void onWindowClose() => hide();

  @override
  void onWindowMinimize() => visible.value = false;

  @override
  void onWindowRestore() => visible.value = true;
}
