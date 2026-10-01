import 'dart:async';

import 'package:flutter/material.dart';

import '../integrations/profile_usage.dart';
import 'anchored_menu.dart';
import 'theme.dart';
import 'widgets.dart';

/// Кнопка лимитов на открытом профиле. Данные читаются при открытии меню.
class ProfileUsageButton extends StatelessWidget {
  const ProfileUsageButton({
    super.key,
    required this.load,
    required this.isRunning,
    required this.activity,
    this.enabled = true,
    this.interactive = true,
    this.menuAnchorContext,
    this.menuHighlight,
  });

  final Future<ProfileUsage?> Function() load;
  final bool Function() isRunning;
  final Listenable activity;
  final bool enabled;
  final bool interactive;
  final BuildContext? menuAnchorContext;
  final Widget? menuHighlight;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => CircleIconButton(
      icon: AppIcons.charts,
      tooltip: interactive ? 'Лимиты профиля' : null,
      onPressed: enabled
          ? () {
              if (!interactive) return;
              showAnchoredMenu<void>(
                maxWidth: ProfileUsageMenu.width,
                anchorContext: menuAnchorContext ?? anchor,
                highlight:
                    menuHighlight ??
                    CircleIconButton(icon: AppIcons.charts, onPressed: () {}),
                content: ProfileUsageMenu(
                  load: load,
                  isRunning: isRunning,
                  activity: activity,
                ),
              );
            }
          : null,
    ),
  );
}

/// Меню лимитов — как меню страны: крупный заголовок, под ним лимиты,
/// внизу «Проверить снова». Перечитывает данные при открытии, по кнопке и раз
/// в 30 секунд, пока открыто, — заодно обновляется «через 2 ч 10 мин».
class ProfileUsageMenu extends StatefulWidget {
  const ProfileUsageMenu({
    super.key,
    required this.load,
    required this.isRunning,
    required this.activity,
    this.now = DateTime.now,
  });

  static const width = 320.0;

  final Future<ProfileUsage?> Function() load;
  final bool Function() isRunning;
  final Listenable activity;
  final DateTime Function() now;

  @override
  State<ProfileUsageMenu> createState() => _ProfileUsageMenuState();
}

class _ProfileUsageMenuState extends State<ProfileUsageMenu> {
  ProfileUsage? _usage;
  bool _loaded = false;
  bool _loading = false;
  bool _failed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_loading || !widget.isRunning()) return;
    setState(() => _loading = true);
    try {
      final usage = await widget.load();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _failed = false;
      });
    } catch (_) {
      // Ошибка не превращается в вымышленные проценты.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loaded = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.activity,
    builder: (context, _) {
      final theme = Theme.of(context);
      final running = widget.isRunning();
      final usage = _usage;
      final String? message;
      if (!running) {
        message = 'Профиль закрыт. Откройте его, чтобы увидеть лимиты.';
      } else if (!_loaded) {
        message = 'Читаю лимиты профиля…';
      } else if (_failed) {
        message = 'Не удалось прочитать лимиты Claude.';
      } else if (usage == null) {
        message =
            'Claude ещё не сохранил лимиты этого профиля. Откройте в нём '
            '«Настройки → Использование».';
      } else {
        message = null;
      }
      return SizedBox(
        width: ProfileUsageMenu.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Лимиты',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (message != null)
                      Text(message, style: theme.textTheme.bodySmall)
                    else
                      for (final (index, limit) in usage!.limits.indexed) ...[
                        if (index > 0) const SizedBox(height: 14),
                        _LimitRow(limit: limit, now: widget.now()),
                      ],
                  ],
                ),
              ),
            ),
            const Divider(),
            AnchoredMenuAction(
              icon: AppIcons.sync,
              label: 'Проверить снова',
              loading: _loading,
              onPressed: running && !_loading ? _refresh : null,
            ),
          ],
        ),
      );
    },
  );
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({required this.limit, required this.now});

  final UsageLimit limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final used = limit.usedPercent;
    final color = used >= 90
        ? p.danger
        : used >= 70
        ? p.warning
        : p.success;
    final percent = '${used.round()}%';
    final reset = resetText(limit, now);
    return Semantics(
      label:
          '${limit.label}: использовано $percent${reset == null ? '' : ', $reset'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  limit.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                percent,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (used / 100).clamp(0, 1),
              minHeight: 4,
              backgroundColor: p.field,
              color: color,
            ),
          ),
          if (reset != null) ...[
            const SizedBox(height: 6),
            Text(reset, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// «Сброс через 2 ч 10 мин», «Сброс в вс, 21:00», «Сброшен в 15:10» или
/// «Начнётся с первого запроса»; null — время сброса неизвестно.
String? resetText(UsageLimit limit, DateTime now) {
  if (limit.idle) return 'Начнётся с первого запроса';
  if (limit.wasResetAt case final was?) {
    final at = _minute(was);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${limit.resetApproximate ? 'Сброшен примерно' : 'Сброшен'} '
        'в ${two(at.hour)}:${two(at.minute)}';
  }
  final resetsAt = limit.resetsAt;
  if (resetsAt == null) return null;
  final at = _minute(resetsAt);
  final left = at.difference(now);
  final prefix = limit.resetApproximate ? 'Сброс примерно' : 'Сброс';
  if (left.inMinutes < 1) return '$prefix сейчас';
  if (left < const Duration(hours: 24)) {
    final hours = left.inHours;
    final minutes = left.inMinutes % 60;
    final time = hours == 0
        ? '$minutes мин'
        : minutes == 0
        ? '$hours ч'
        : '$hours ч $minutes мин';
    return '$prefix через $time';
  }
  const days = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
  String two(int value) => value.toString().padLeft(2, '0');
  return '$prefix в ${days[at.weekday - 1]}, ${two(at.hour)}:${two(at.minute)}';
}

/// Сервер ставит сброс на хх:59:59.98 — округляем до минуты.
DateTime _minute(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
  (time.millisecondsSinceEpoch / 60000).round() * 60000,
);
