import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude/claude_host.dart';
import '../claude/windows_powershell.dart';

/// Windows: «Cowork — только через Kill Switch» — правило брандмауэра,
/// которое не выпускает службу машины Cowork в интернет мимо затвора.
///
/// Машина Cowork работает в службе `CoworkVMService` от имени системы: Kill
/// Switch её не закроет. Её трафик по задумке Claude и так идёт через прокси
/// лаунчера, а правило — страховка: запрещает службе любой выход, кроме
/// соединений внутри компьютера (их брандмауэр Windows не фильтрует), то есть
/// кроме затвора. Правило — по имени службы, поэтому переживает обновления
/// Claude (путь к ней меняется с версией).
///
/// Ставить и снимать правило Windows разрешает только администратору — она
/// спросит разрешение. Узнать, стоит ли оно, можно без этого.
class CoworkFirewall extends ChangeNotifier {
  static const ruleName = 'ClaudeLauncher-Cowork';
  static const service = 'CoworkVMService';

  /// Стоит ли правило; null — ещё не знаем.
  bool? active;
  bool busy = false;
  String? error;

  static Directory get _work =>
      Directory(p.join(ClaudeHost.workDir.path, 'cowork-firewall'));

  /// Есть ли правило — без прав администратора.
  Future<void> refresh() async {
    if (!Platform.isWindows) return;
    final (ok, _) = await WindowsPowerShell.run(
      checkScript,
      work: _work,
      elevated: false,
      timeout: const Duration(seconds: 30),
    );
    active = ok;
    notifyListeners();
  }

  Future<void> enable() => _change(enableScript, wanted: true);

  Future<void> disable() => _change(disableScript, wanted: false);

  Future<void> _change(String script, {required bool wanted}) async {
    if (!Platform.isWindows || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final (ok, details) = await WindowsPowerShell.run(
        script,
        work: _work,
        elevated: true,
        timeout: const Duration(minutes: 2),
      );
      if (!ok) error = details;
      await refresh();
      if (active != wanted && error == null) {
        error = 'Windows не изменила правило брандмауэра';
      }
    } finally {
      busy = false;
      await ClaudeHost.removeQuietly(_work.path);
      notifyListeners();
    }
  }

  @visibleForTesting
  static const checkScript =
      "if (-not (Get-NetFirewallRule -Name '$ruleName' "
      "-ErrorAction SilentlyContinue)) { throw 'правила нет' }";

  @visibleForTesting
  static const enableScript =
      "Remove-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue\n"
      "New-NetFirewallRule -Name '$ruleName' "
      "-DisplayName 'ClaudeLauncher: Cowork только через Kill Switch' "
      "-Description 'Служба машины Cowork выходит в интернет только через "
      "затвор Kill Switch на 127.0.0.1. Поставил ClaudeLauncher.' "
      "-Direction Outbound -Action Block -Service '$service' -Profile Any "
      '| Out-Null';

  @visibleForTesting
  static const disableScript =
      "Remove-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue";
}
