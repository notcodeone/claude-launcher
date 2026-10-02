import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Оповещение внизу окна: профиль создан, вышло обновление, Claude обновлён.
/// Важное и требующее решения (Kill Switch сработал, страна недоступна) —
/// не сюда, а строкой [NoticeRow] над профилями.
class Snack {
  const Snack({
    required this.id,
    required this.text,
    this.icon = AppIcons.info,
    this.action,
    this.onAction,
    this.onClose,
    this.duration = const Duration(seconds: 6),
    this.error = false,
  });

  /// Повторное оповещение с тем же id заменяет прежнее, а не встаёт в очередь.
  final String id;
  final String text;
  final IconData icon;

  /// Кнопка внутри: «Обновить», «Подробнее», «Открыть».
  final String? action;
  final VoidCallback? onAction;

  /// Закрыли крестиком.
  final VoidCallback? onClose;

  /// Через сколько уйти само; null — пока не закроют.
  final Duration? duration;

  /// Не получилось — значок красным.
  final bool error;
}

/// Очередь оповещений: на экране одно, следующее — после него. Пока курсор
/// над оповещением, оно не уходит.
abstract final class AppSnackbar {
  static final current = ValueNotifier<Snack?>(null);
  static final _queue = <Snack>[];
  static Timer? _timer;

  static void show(Snack snack) {
    _queue.removeWhere((queued) => queued.id == snack.id);
    final shown = current.value;
    if (shown == null) return _present(snack);
    if (shown.id == snack.id) {
      // То же оповещение с новым текстом — на месте, таймер заново.
      return _present(snack);
    }
    _queue.add(snack);
  }

  /// Убрать оповещение [id] (или текущее) — с экрана или из очереди.
  static void dismiss([String? id]) {
    final shown = current.value;
    if (id != null && shown?.id != id) {
      _queue.removeWhere((queued) => queued.id == id);
      return;
    }
    _timer?.cancel();
    current.value = null;
    if (_queue.isNotEmpty) {
      // Пауза — чтобы прежнее успело уйти, а новое заметно пришло.
      _timer = Timer(
        const Duration(milliseconds: 300),
        () => _present(_queue.removeAt(0)),
      );
    }
  }

  static void _present(Snack snack) {
    _timer?.cancel();
    current.value = snack;
    _arm(snack);
  }

  static void _arm(Snack snack) {
    final duration = snack.duration;
    if (duration != null) {
      _timer = Timer(duration, () {
        if (current.value == snack) dismiss();
      });
    }
  }

  static void _hold() => _timer?.cancel();

  static void _release() {
    final snack = current.value;
    if (snack?.duration case final _?) {
      _timer = Timer(const Duration(seconds: 3), () {
        if (current.value == snack) dismiss();
      });
    }
  }

  @visibleForTesting
  static void reset() {
    _timer?.cancel();
    _queue.clear();
    current.value = null;
  }
}

/// Место оповещений в окне: приходят снизу и гаснут, уходят так же.
class SnackbarHost extends StatelessWidget {
  const SnackbarHost({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: AppSnackbar.current,
    builder: (context, snack, _) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.35),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomCenter,
        children: [...previous, ?current],
      ),
      child: snack == null
          ? const SizedBox.shrink()
          : SnackView(key: ValueKey(snack), snack: snack),
    ),
  );
}

/// Оповещение — чёрная плашка, как кнопка «Добавить»: значок, текст, кнопка
/// действия и крестик.
class SnackView extends StatelessWidget {
  const SnackView({super.key, required this.snack});

  final Snack snack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(16);
    return MouseRegion(
      onEnter: (_) => AppSnackbar._hold(),
      onExit: (_) => AppSnackbar._release(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: p.softShadow,
        ),
        child: Material(
          color: p.primary,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  Icon(
                    snack.icon,
                    size: 18,
                    color: snack.error
                        ? const Color(0xFFFF8A80)
                        : p.onPrimary.withValues(alpha: 0.85),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        snack.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.onPrimary,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  if (snack.action case final label?) ...[
                    const SizedBox(width: 8),
                    _SnackButton(
                      label: label,
                      onPressed: () {
                        AppSnackbar.dismiss(snack.id);
                        snack.onAction?.call();
                      },
                    ),
                  ],
                  _SnackButton(
                    icon: AppIcons.close,
                    tooltip: 'Закрыть',
                    onPressed: () {
                      AppSnackbar.dismiss(snack.id);
                      snack.onClose?.call();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SnackButton extends StatelessWidget {
  const _SnackButton({
    required this.onPressed,
    this.label,
    this.icon,
    this.tooltip,
  });

  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final button = InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      hoverColor: p.onPrimary.withValues(alpha: 0.1),
      child: Padding(
        padding: label != null
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 9)
            : const EdgeInsets.all(9),
        child: label != null
            ? Text(
                label!,
                style: TextStyle(
                  color: p.onPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              )
            : Icon(icon, size: 16, color: p.onPrimary.withValues(alpha: 0.6)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
