import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/diagnostics.dart';
import 'snackbar.dart';
import 'theme.dart';
import 'widgets.dart';

/// Раздел «Диагностика»: проверки по очереди, у проблем — «Исправить»,
/// сверху — «Проверить снова» и «Скопировать отчёт».
class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({
    super.key,
    required this.diagnostics,
    required this.version,
  });

  final Diagnostics diagnostics;
  final String version;

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView> {
  List<DiagnosticCheck>? _checks;
  DateTime? _checkedAt;
  bool _running = false;
  String? _fixing;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final checks = await widget.diagnostics.run();
    if (!mounted) return;
    setState(() {
      _checks = checks;
      _checkedAt = DateTime.now();
      _running = false;
    });
  }

  Future<void> _fix(DiagnosticCheck check) async {
    setState(() => _fixing = check.title);
    try {
      await check.fix!();
    } finally {
      if (mounted) setState(() => _fixing = null);
    }
    await _run();
  }

  Future<void> _copy() async {
    final checks = _checks;
    if (checks == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: widget.diagnostics.report(checks, version: widget.version),
      ),
    );
    AppSnackbar.show(
      const Snack(
        id: 'diagnostics',
        icon: AppIcons.check,
        text: 'Отчёт скопирован',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checks = _checks;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summary(context, checks),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Проверить снова',
                  kind: AppButtonKind.secondary,
                  expand: true,
                  onPressed: _running ? null : _run,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  label: 'Скопировать отчёт',
                  expand: true,
                  onPressed: checks == null ? null : _copy,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          if (checks == null)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            for (final (index, check) in checks.indexed) ...[
              if (index > 0) const Divider(height: 1),
              _CheckRow(
                check: check,
                fixing: _fixing == check.title,
                onFix: check.fix == null || _fixing != null
                    ? null
                    : () => _fix(check),
              ),
            ],
        ],
      ),
    );
  }

  /// Итог проверки — как строка состояния на странице синхронизации: значок,
  /// что в целом, и под ним — подробности.
  Widget _summary(BuildContext context, List<DiagnosticCheck>? checks) {
    final p = context.palette;
    final theme = Theme.of(context);
    int count(CheckStatus status) =>
        checks?.where((check) => check.status == status).length ?? 0;
    final problems = count(CheckStatus.problem);
    final warnings = count(CheckStatus.warning);
    final at = _checkedAt;
    String two(int value) => value.toString().padLeft(2, '0');
    final when = at == null ? '' : ' · в ${two(at.hour)}:${two(at.minute)}';
    final (Widget icon, String title, String detail) = switch (checks) {
      null => (
        SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
        ),
        'Проверяю…',
        'Это займёт пару секунд',
      ),
      _ when problems > 0 => (
        Icon(AppIcons.error, size: 22, color: p.danger),
        problems == 1 ? 'Есть проблема' : 'Есть проблемы: $problems',
        '${warnings > 0 ? 'И предупреждений: $warnings' : 'Ниже — что не так'}$when',
      ),
      _ when warnings > 0 => (
        Icon(AppIcons.hand, size: 22, color: p.warning),
        warnings == 1 ? 'Есть предупреждение' : 'Предупреждений: $warnings',
        'Работать можно, но лучше поправить$when',
      ),
      _ => (
        Icon(AppIcons.checked, size: 22, color: p.success),
        'Всё в порядке',
        'Проверок: ${checks.length}$when',
      ),
    };
    return Row(
      children: [
        SizedBox(width: 22, child: Center(child: icon)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.check,
    required this.fixing,
    required this.onFix,
  });

  final DiagnosticCheck check;
  final bool fixing;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final (icon, color) = switch (check.status) {
      CheckStatus.ok => (AppIcons.checked, p.success),
      CheckStatus.info => (AppIcons.info, p.muted),
      CheckStatus.warning => (AppIcons.hand, p.warning),
      CheckStatus.problem => (AppIcons.error, p.danger),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(check.detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (check.fixLabel case final label? when check.fix != null) ...[
            const SizedBox(width: 12),
            AppButton(
              label: fixing ? 'Исправляю…' : label,
              kind: AppButtonKind.secondary,
              onPressed: onFix,
            ),
          ],
        ],
      ),
    );
  }
}
