import 'dart:async';

import '../app_settings.dart';
import '../launcher_controller.dart';

/// Windows: держит значок Claude в трее спрятанным (под стрелкой ▲).
///
/// Запись о значке Windows заводит, только когда Claude впервые его показал,
/// а после каждого обновления Claude — новую (путь к пакету с версией).
/// Спрятать один раз при запуске лаунчера мало: пока Claude открыт, лаунчер
/// повторяет это сразу после его запуска и затем раз в [every]. Хост пишет в
/// реестр, только если значение другое.
class ClaudeIconKeeper {
  ClaudeIconKeeper({
    required this.settings,
    required this.launcher,
    this.every = const Duration(seconds: 5),
  });

  final AppSettings settings;
  final LauncherController launcher;
  final Duration every;

  Timer? _timer;
  bool _wasRunning = false;

  void start() {
    launcher.addListener(_changed);
    settings.addListener(_changed);
    _timer = Timer.periodic(every, (_) => _apply());
    _changed();
  }

  void dispose() {
    launcher.removeListener(_changed);
    settings.removeListener(_changed);
    _timer?.cancel();
  }

  void _changed() {
    final running = launcher.instances.isNotEmpty;
    // Claude только что открылся — значок вот-вот появится.
    if (running && !_wasRunning) _apply();
    _wasRunning = running;
  }

  void _apply() {
    if (!settings.hideClaudeIcon || launcher.instances.isEmpty) return;
    unawaited(launcher.setClaudeIconHidden(true));
  }
}
