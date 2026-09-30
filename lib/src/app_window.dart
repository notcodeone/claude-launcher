import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

/// Окно настроек: прячется при закрытии, само приложение живёт в трее.
class AppWindow with WindowListener {
  AppWindow() {
    windowManager.addListener(this);
  }

  static const _native = MethodChannel('claude_launcher/native');

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

  /// Пока идёт [launch] и ещё [after] после него, окно остаётся впереди:
  /// Claude, открываясь, сам выходит на передний план — и не раз, пока
  /// загружается. [launch] — true, если Claude действительно запускался.
  /// Переключится пользователь сам — окно ему больше не мешает.
  Future<void> keepInFrontDuring(
    Future<bool> launch, {
    Duration after = const Duration(seconds: 20),
  }) async {
    var done = false;
    final keeping = _keepInFront(DateTime.now(), () => done);
    try {
      if (await launch) await Future<void>.delayed(after);
    } finally {
      done = true;
    }
    await keeping;
  }

  /// Если окно перестало быть активным, а пользователь ничего не нажимал, — его
  /// перекрыло другое приложение само: возвращаем окно вперёд.
  Future<void> _keepInFront(DateTime since, bool Function() done) async {
    while (!done()) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (done() || !visible.value || await windowManager.isFocused()) continue;
      // Клик или клавиша только что — это пользователь переключился сам.
      // Клик, которым запустили лаунчер, не в счёт.
      final input = await _sinceUserInput();
      if (input < const Duration(seconds: 1) &&
          input < DateTime.now().difference(since)) {
        return;
      }
      await _bringToFront();
    }
  }

  Future<void> _bringToFront() async {
    if (Platform.isMacOS) {
      await _native.invokeMethod<void>('bringToFront');
      return;
    }
    // Windows не отдаёт фокус фоновому приложению, но «поверх всех» и обратно
    // поднимает окно над остальными и без фокуса.
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.focus();
  }

  /// Сколько прошло с последнего действия пользователя. На macOS — клика или
  /// клавиши, на Windows — любого ввода, включая движение мыши.
  Future<Duration> _sinceUserInput() async {
    try {
      if (Platform.isMacOS) {
        final seconds = await _native.invokeMethod<double>('secondsSinceInput');
        return Duration(milliseconds: ((seconds ?? 0) * 1000).round());
      }
      if (Platform.isWindows) {
        final info = calloc<LASTINPUTINFO>()
          ..ref.cbSize = sizeOf<LASTINPUTINFO>();
        try {
          if (!GetLastInputInfo(info)) return Duration.zero;
          // Счётчики 32-битные и переполняются раз в 49 дней — разность по модулю.
          return Duration(
            milliseconds: (GetTickCount() - info.ref.dwTime) & 0xFFFFFFFF,
          );
        } finally {
          calloc.free(info);
        }
      }
    } catch (error) {
      debugPrint('Не удалось узнать время последнего ввода: $error');
    }
    // Не знаем — считаем, что пользователь только что действовал сам.
    return Duration.zero;
  }

  @override
  void onWindowClose() => hide();

  @override
  void onWindowMinimize() => visible.value = false;

  @override
  void onWindowRestore() => visible.value = true;
}
