import 'dart:convert';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

import 'launcher_controller.dart';

/// Иконка в строке меню macOS / трее Windows и её меню.
class TrayController with TrayListener {
  TrayController({
    required this.launcher,
    required this.onOpenSettings,
    required this.onQuit,
  });

  final LauncherController launcher;
  final void Function() onOpenSettings;
  final void Function() onQuit;

  String _lastState = '';

  Future<void> init() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon_template.png',
      isTemplate: true,
    );
    trayManager.addListener(this);
    launcher.addListener(_update);
    await _update();
  }

  Future<void> dispose() async {
    launcher.removeListener(_update);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  Future<void> _update() async {
    final menu = _buildMenu();
    final title = _title();
    final tooltip = 'Claude Launcher — ${_statusText()}';

    // Меню пересобирается при каждом опросе процессов; трогаем трей только при изменениях.
    // Сравниваем без id пунктов: они новые у каждого MenuItem, а клик по уже открытому
    // меню приходит с id, который Dart ищет в последнем отправленном меню.
    final state = jsonEncode([
      for (final item in menu.items ?? const <MenuItem>[])
        [item.type, item.key, item.label, item.checked, item.disabled],
      title,
      tooltip,
    ]);
    if (state == _lastState) return;
    _lastState = state;

    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip(tooltip);
    if (Platform.isMacOS) await trayManager.setTitle(title);
  }

  String _statusText() {
    final status = launcher.switchStatus;
    if (status != null) return 'переключаюсь на ${status.target.title}…';
    if (launcher.located && launcher.claudePath == null) return 'Claude не найден';
    final running = [
      for (final profile in launcher.runningProfiles) profile.title,
      if (launcher.unknownInstances.isNotEmpty) '❔ профиль не из списка',
    ];
    return running.isEmpty ? 'Claude не запущен' : 'открыт ${running.join(', ')}';
  }

  /// Текст рядом с иконкой в строке меню macOS: метка и имя открытого профиля.
  String _title() {
    if (launcher.switchStatus != null) return ' ⏳';
    final running = launcher.runningProfiles;
    if (running.length == 1 && launcher.unknownInstances.isEmpty) {
      return ' ${running.single.title}';
    }
    final markers = [
      for (final profile in running) profile.marker,
      if (launcher.unknownInstances.isNotEmpty) '❔',
    ];
    return markers.isEmpty ? '' : ' ${markers.join()}';
  }

  Menu _buildMenu() {
    final switching = launcher.switchStatus != null;
    final status = _statusText();
    return Menu(items: [
      MenuItem(label: '${status[0].toUpperCase()}${status.substring(1)}', disabled: true),
      MenuItem.separator(),
      for (final profile in launcher.profiles)
        MenuItem.checkbox(
          key: 'profile:${profile.id}',
          label: profile.email.isEmpty ? profile.title : '${profile.title} — ${profile.email}',
          checked: launcher.isRunning(profile),
          disabled: switching,
        ),
      MenuItem.separator(),
      MenuItem(key: 'settings', label: 'Профили и настройки…'),
      MenuItem(key: 'quit', label: 'Выйти из Claude Launcher'),
    ]);
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key == 'settings') return onOpenSettings();
    if (key == 'quit') return onQuit();
    if (key.startsWith('profile:')) {
      final id = key.substring('profile:'.length);
      for (final profile in launcher.profiles) {
        if (profile.id == id) launcher.switchTo(profile);
      }
    }
  }
}
