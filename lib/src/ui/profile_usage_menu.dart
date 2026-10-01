import 'dart:async';

import 'package:flutter/material.dart';

import '../integrations/profile_usage.dart';
import 'anchored_menu.dart';
import 'theme.dart';
import 'widgets.dart';

/// Видна только на открытом профиле; данные читаются при открытии меню.
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
              final navigator = Navigator.of(anchor);
              showAnchoredMenu<void>(
                maxWidth: 500,
                anchorContext: menuAnchorContext ?? anchor,
                highlight:
                    menuHighlight ??
                    CircleIconButton(icon: AppIcons.charts, onPressed: () {}),
                content: ProfileUsageMenu(
                  load: load,
                  isRunning: isRunning,
                  activity: activity,
                  onRechecked: () => navigator.pop(),
                ),
              );
            }
          : null,
    ),
  );
}

class ProfileUsageMenu extends StatefulWidget {
  const ProfileUsageMenu({
    super.key,
    required this.load,
    required this.isRunning,
    required this.activity,
    this.onRechecked,
  });

  final Future<ProfileUsage?> Function() load;
  final bool Function() isRunning;
  final Listenable activity;
  final VoidCallback? onRechecked;

  @override
  State<ProfileUsageMenu> createState() => _ProfileUsageMenuState();
}

class _ProfileUsageMenuState extends State<ProfileUsageMenu> {
  ProfileUsage? _usage;
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
      if (!mounted) return;
      // Ошибка не превращается в ложные 100% оставшегося лимита.
      setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _recheck() async {
    await _refresh();
    if (mounted && !_failed) widget.onRechecked?.call();
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
      final running = widget.isRunning();
      final usage = _usage;
      return SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                'Остаток лимитов',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!running)
                      const Text(
                        'Профиль закрыт. Откройте его, чтобы посмотреть лимиты.',
                      )
                    else if (_loading && usage == null)
                      const Text('Читаем лимиты профиля…')
                    else if (_failed)
                      const Text(
                        'Не удалось прочитать лимиты. Попробуйте ещё раз.',
                      )
                    else if (usage == null)
                      const Text(
                        'Claude ещё не сохранил лимиты этого профиля. '
                        'Откройте в Claude «Настройки → Использование» и проверьте позже.',
                      )
                    else ...[
                      if (usage.limits.isEmpty)
                        const Text(
                          'Для этого профиля сервер не вернул лимитов.',
                        ),
                      for (final (index, limit) in usage.limits.indexed) ...[
                        if (index > 0) const SizedBox(height: 16),
                        _LimitRow(limit: limit),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const Divider(),
            AnchoredMenuAction(
              icon: AppIcons.sync,
              label: 'Проверить снова',
              backgroundColor: context.palette.field,
              loading: _loading,
              onPressed: running && !_loading ? _recheck : null,
            ),
          ],
        ),
      );
    },
  );
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({required this.limit});

  final UsageLimit limit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final used = limit.usedPercent;
    final color = used >= 90
        ? p.danger
        : used >= 70
        ? p.warning
        : p.success;
    final number = used == used.roundToDouble()
        ? used.toStringAsFixed(0)
        : used.toStringAsFixed(1).replaceAll('.', ',');
    final reset = limit.resetDescription;
    return Semantics(
      label:
          '${limit.label}: использовано $number процентов'
          '${reset == null ? '' : ', ${_resetText(reset)}'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  limit.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Tooltip(
                  message: reset == null
                      ? 'В доступных данных нет времени сброса'
                      : _resetText(reset),
                  child: Text(
                    reset == null ? '—' : _resetText(reset),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Использовано $number%',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (used / 100).clamp(0, 1),
              minHeight: 4,
              backgroundColor: p.field,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  static String _resetText(String value) {
    final relative = RegExp(r'^Resets in (.+)$').firstMatch(value);
    if (relative != null) {
      final time = relative
          .group(1)!
          .replaceAll(RegExp(r'\bhrs?\b'), 'ч')
          .replaceAll(RegExp(r'\bmins?\b'), 'мин')
          .replaceAll(RegExp(r'\bdays?\b'), 'дн');
      return 'Сброс через $time';
    }
    final weekly = RegExp(
      r'^Resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d{1,2})(?::(\d{2}))? (AM|PM)$',
    ).firstMatch(value);
    if (weekly != null) {
      const days = {
        'Mon': 'пн',
        'Tue': 'вт',
        'Wed': 'ср',
        'Thu': 'чт',
        'Fri': 'пт',
        'Sat': 'сб',
        'Sun': 'вс',
      };
      final hour = int.parse(weekly.group(2)!);
      if (hour >= 1 && hour <= 12) {
        final h24 = hour % 12 + (weekly.group(4) == 'PM' ? 12 : 0);
        return 'Сброс ${days[weekly.group(1)]}, ${h24.toString().padLeft(2, '0')}:${weekly.group(3) ?? '00'}';
      }
    }
    return value;
  }
}
