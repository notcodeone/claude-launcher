import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:win32/win32.dart' show WindowsException;
import 'package:win32_registry/win32_registry.dart';

import 'launcher_controller.dart';
import 'location/location_guard.dart';
import 'updates/app_updater.dart';

/// Иконка в строке меню macOS / трее Windows и её меню.
class TrayController with TrayListener {
  TrayController({
    required this.launcher,
    required this.location,
    required this.updater,
    required this.onShowWindow,
    required this.onQuit,
  }) {
    _clicks = ClickDisambiguator(
      onSingle: trayManager.popUpContextMenu,
      onDouble: onShowWindow,
    );
  }

  final LauncherController launcher;
  final LocationGuard location;
  final AppUpdater updater;

  /// Окно лаунчера: пункт меню и двойной клик по иконке.
  final void Function() onShowWindow;
  final void Function() onQuit;

  late final ClickDisambiguator _clicks;
  String _lastState = '';

  Future<void> init() async {
    await _setIcon();
    // Тему панели задач Windows могут сменить в любой момент — значок следом.
    if (Platform.isWindows) {
      _themeTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _setIcon(),
      );
    }
    trayManager.addListener(this);
    launcher.addListener(_update);
    location.addListener(_update);
    updater.addListener(_update);
    await _update();
  }

  Future<void> dispose() async {
    _themeTimer?.cancel();
    _clicks.cancel();
    launcher.removeListener(_update);
    location.removeListener(_update);
    updater.removeListener(_update);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  Timer? _themeTimer;
  String? _icon;

  /// Знак без фона. macOS красит шаблон сама; на Windows — чёрный знак для
  /// светлой панели задач и белый для тёмной.
  Future<void> _setIcon() async {
    final icon = !Platform.isWindows
        ? 'assets/tray/tray_icon_template.tiff'
        : _lightTaskbar()
        ? 'assets/tray/tray_icon_light.ico'
        : 'assets/tray/tray_icon_dark.ico';
    if (icon == _icon) return;
    _icon = icon;
    // 22 pt — наибольший значок, который строка меню вмещает без обрезки
    // (шаблон нарисован под этот размер, см. tool/generate_icons.py).
    await trayManager.setIcon(icon, isTemplate: true, iconSize: 22);
  }

  /// Панель задач Windows светлая. Параметра нет — значит, тёмная (так по умолчанию).
  static bool _lightTaskbar() {
    try {
      final key = CURRENT_USER.open(
        r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
      );
      try {
        return key.getInt('SystemUsesLightTheme') == 1;
      } finally {
        key.close();
      }
    } on WindowsException {
      return false;
    }
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
    if (launcher.maintaining) return '${launcher.maintenanceLabel}…';
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
        : 'запущен ${running.join(', ')}';
  }

  Menu _buildMenu() {
    final switching = launcher.busy;
    final status = _statusText();
    return Menu(
      items: [
        if (location.blocksLaunch)
          MenuItem(
            label: '⚠️ Claude недоступен: ${location.countryName}',
            disabled: true,
          ),
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
            // Где Claude недоступен, запустить нельзя — только показать открытый.
            disabled:
                switching ||
                (location.blocksLaunch && !launcher.isRunning(profile)),
          ),
        MenuItem.separator(),
        if (_updateLabel() case final label?)
          MenuItem(
            key: 'update',
            label: label,
            disabled:
                updater.phase != UpdatePhase.available &&
                updater.phase != UpdatePhase.failed,
          )
        else
          MenuItem(
            key: 'check-updates',
            label: updater.checking
                ? 'Проверяю обновления…'
                : _justChecked
                ? 'Обновлений нет — у вас последняя версия'
                : 'Проверить обновления',
            disabled: updater.checking,
          ),
        MenuItem(key: 'settings', label: 'Профили и настройки…'),
        MenuItem(key: 'quit', label: 'Выйти из ClaudeLauncher'),
      ],
    );
  }

  bool get _justChecked {
    final at = updater.upToDateAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 1);
  }

  String? _updateLabel() {
    final version = updater.release?.version;
    return switch (updater.phase) {
      UpdatePhase.idle => null,
      UpdatePhase.available => 'Обновить до $version',
      UpdatePhase.downloading => 'Скачиваю $version…',
      UpdatePhase.installing => 'Устанавливаю $version…',
      UpdatePhase.failed => 'Не удалось обновить — попробовать снова',
    };
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
    if (key == 'update') {
      updater.install();
      return;
    }
    if (key == 'check-updates') {
      updater.check(manual: true);
      return;
    }
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
