import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

import 'launcher_controller.dart';

/// Иконка в строке меню macOS / трее Windows и её меню.
class TrayController with TrayListener {
  TrayController({
    required this.launcher,
    required this.onShowWindow,
    required this.onQuit,
  }) {
    _clicks = ClickDisambiguator(
      onSingle: trayManager.popUpContextMenu,
      onDouble: onShowWindow,
    );
  }

  final LauncherController launcher;

  /// Окно лаунчера: пункт меню и двойной клик по иконке.
  final void Function() onShowWindow;
  final void Function() onQuit;

  late final ClickDisambiguator _clicks;
  String _lastState = '';

  Future<void> init() async {
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray_icon.ico'
          : 'assets/tray/tray_icon_template.png',
      isTemplate: true,
    );
    trayManager.addListener(this);
    launcher.addListener(_update);
    await _update();
  }

  Future<void> dispose() async {
    _clicks.cancel();
    launcher.removeListener(_update);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  Future<void> _update() async {
    final menu = _buildMenu();
    final tooltip = 'ClaudeLauncher — ${_statusText()}';

    // Меню пересобирается при каждом опросе процессов; трогаем трей только при изменениях.
    // Сравниваем без id пунктов: они новые у каждого MenuItem, а клик по уже открытому
    // меню приходит с id, который Dart ищет в последнем отправленном меню.
    final state = jsonEncode([
      for (final item in menu.items ?? const <MenuItem>[])
        [item.type, item.key, item.label, item.checked, item.disabled],
      tooltip,
    ]);
    if (state == _lastState) return;
    _lastState = state;

    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip(tooltip);
  }

  String _statusText() {
    final status = launcher.switchStatus;
    if (status != null) {
      return switch (status.target) {
        final target? => 'переключаюсь на ${target.title}…',
        null => 'закрываю Claude…',
      };
    }
    if (launcher.located && launcher.claudePath == null) {
      return 'Claude не найден';
    }
    final running = [
      for (final profile in launcher.runningProfiles) profile.title,
      if (launcher.unknownInstances.isNotEmpty) '❔ профиль не из списка',
    ];
    return running.isEmpty
        ? 'Claude не запущен'
        : 'открыт ${running.join(', ')}';
  }

  Menu _buildMenu() {
    final switching = launcher.switchStatus != null;
    final status = _statusText();
    return Menu(
      items: [
        MenuItem(
          label: '${status[0].toUpperCase()}${status.substring(1)}',
          disabled: true,
        ),
        MenuItem.separator(),
        for (final profile in launcher.profiles)
          MenuItem.checkbox(
            key: 'profile:${profile.id}',
            label: profile.email.isEmpty
                ? profile.title
                : '${profile.title} — ${profile.email}',
            checked: launcher.isRunning(profile),
            disabled: switching,
          ),
        MenuItem.separator(),
        MenuItem(key: 'settings', label: 'Профили и настройки…'),
        MenuItem(key: 'quit', label: 'Выйти из ClaudeLauncher'),
      ],
    );
  }

  /// Клик — меню, двойной клик — окно лаунчера.
  @override
  void onTrayIconMouseDown() => _clicks.click();

  @override
  void onTrayIconRightMouseDown() {
    _clicks.cancel();
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key == 'settings') return onShowWindow();
    if (key == 'quit') return onQuit();
    if (key.startsWith('profile:')) {
      final id = key.substring('profile:'.length);
      for (final profile in launcher.profiles) {
        if (profile.id == id) launcher.switchTo(profile);
      }
    }
  }
}

/// Отличает клик от двойного клика по иконке в трее.
///
/// Меню трея модальное: если открыть его на первом клике, второй клик только
/// закроет меню и до лаунчера не дойдёт. Поэтому одиночный клик срабатывает
/// с задержкой [window] — если за это время не было второго.
class ClickDisambiguator {
  ClickDisambiguator({
    required this.onSingle,
    required this.onDouble,
    this.window = const Duration(milliseconds: 300),
  });

  final void Function() onSingle;
  final void Function() onDouble;

  /// Короче системного интервала двойного клика (обычно 0,5 с), чтобы меню
  /// не запаздывало заметно; быстрый двойной клик укладывается и в него.
  final Duration window;

  Timer? _pending;

  void click() {
    if (_pending?.isActive ?? false) {
      cancel();
      onDouble();
      return;
    }
    _pending = Timer(window, () {
      _pending = null;
      onSingle();
    });
  }

  void cancel() {
    _pending?.cancel();
    _pending = null;
  }
}
