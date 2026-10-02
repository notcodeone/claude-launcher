import 'package:flutter/material.dart';

import '../location/kill_switch.dart';
import 'theme.dart';
import 'widgets.dart';

/// Что Kill Switch делает сейчас: строка состояния и цвет — для настроек и
/// точки на кнопке сети в шапке; [short] — строка в окне сети, в одну
/// строку: «Kill Switch активен».
({String label, String short, Color color})? killSwitchState(
  BuildContext context,
  KillSwitch killSwitch,
) {
  final p = context.palette;
  if (killSwitch.passthrough) {
    return (
      label: 'Защита снимется, когда закроете Claude',
      short: 'Kill Switch снимется после закрытия Claude',
      color: p.warning,
    );
  }
  if (!killSwitch.enabled) return null;
  if (killSwitch.unprotected) {
    return (
      label: 'Не подключён: настройки Claude заняты',
      short: 'Kill Switch не подключён',
      color: p.danger,
    );
  }
  if (killSwitch.lastFired != null && !killSwitch.open) {
    return (
      label: 'Сработал — Claude закрыт',
      short: 'Kill Switch сработал',
      color: p.danger,
    );
  }
  if (killSwitch.needsRestart) {
    return (
      label: 'Перезапустите Claude для защиты',
      short: 'Kill Switch ждёт перезапуска Claude',
      color: p.warning,
    );
  }
  return killSwitch.open
      ? (
          label: 'Сеть проверена — трафик идёт',
          short: 'Kill Switch активен',
          color: p.success,
        )
      : (
          label: 'Проверяю сеть — трафик ждёт',
          short: 'Kill Switch проверяет сеть',
          color: p.warning,
        );
}

/// Строка состояния Kill Switch; null — выключен.
Widget? killSwitchStatusDot(BuildContext context, KillSwitch killSwitch) {
  final state = killSwitchState(context, killSwitch);
  return state == null
      ? null
      : StatusDot(label: state.label, color: state.color);
}
