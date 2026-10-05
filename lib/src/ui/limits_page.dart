import 'dart:async';

import 'package:flutter/material.dart';

import '../integrations/live_usage.dart';
import '../integrations/usage_overview.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'feature_menu.dart';
import 'profile_usage_menu.dart' show UsageLimitRow;
import 'settings_pages.dart' show AppearIn;
import 'widgets.dart';

/// «Лимиты»: сколько осталось у каждого аккаунта профилей. Данные — те, что
/// сохраняет сам Claude (как в меню лимитов на карточке), поэтому у закрытых
/// профилей — на момент, когда их закрыли.
class LimitsPage extends StatefulWidget {
  const LimitsPage({
    super.key,
    required this.launcher,
    required this.padding,
    this.liveUsage,
    this.allowAccess,
    this.preloaded,
  });

  final LauncherController launcher;
  final EdgeInsets padding;

  /// Свежие лимиты от Anthropic — запросом при открытии страницы.
  final LiveUsage? liveUsage;

  /// macOS: доступ к Связке ключей нужен заново (после обновления лаунчера).
  final Future<bool> Function()? allowAccess;

  /// Уже прочитанные данные: в виджет-тестах файлы во время отрисовки не
  /// читаются.
  @visibleForTesting
  final List<AccountUsage>? preloaded;

  @override
  State<LimitsPage> createState() => _LimitsPageState();
}

class _LimitsPageState extends State<LimitsPage> {
  late List<AccountUsage>? _accounts = widget.preloaded;
  Timer? _refresh;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    if (widget.preloaded != null) return;
    // Anthropic — один раз, при открытии; дальше — без сети: последний ответ
    // или файлы Claude (решение автора: никаких запросов в фоне).
    _load(online: true);
    widget.launcher.addListener(_load);
    _refresh = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    widget.launcher.removeListener(_load);
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool online = false}) async {
    final accounts = await UsageOverview.read(
      widget.launcher,
      live: widget.liveUsage,
      online: online,
    );
    if (mounted) setState(() => _accounts = accounts);
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final hint = accounts == null
        ? null
        : UsageOverview.spareHint(accounts, widget.launcher.isRunning);
    return ListView(
      padding: widget.padding,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FeatureHeading(tile: featureTile('limits')),
        ),
        if (widget.allowAccess != null && !_granted) ...[
          const SizedBox(height: 16),
          NoticeRow(
            icon: AppIcons.hand,
            tone: NoticeTone.attention,
            title: 'Лимиты — из файлов Claude, с задержкой',
            detail: 'Разрешите доступ, чтобы лимиты были свежими',
            actions: [
              AppButton(
                label: 'Разрешить',
                kind: AppButtonKind.secondary,
                onPressed: () async {
                  final granted = await widget.allowAccess!();
                  if (!mounted || !granted) return;
                  setState(() => _granted = true);
                  await _load(online: true);
                },
              ),
            ],
          ),
        ],
        if (hint != null) ...[
          const SizedBox(height: 16),
          NoticeRow(
            icon: AppIcons.info,
            tone: NoticeTone.neutral,
            title: 'Лимит почти исчерпан',
            detail: hint,
          ),
        ],
        const SizedBox(height: 4),
        if (accounts == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else
          for (final (index, account) in accounts.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppearIn(
                index: (index + 1).clamp(1, 6),
                child: _AccountCard(
                  account: account,
                  isRunning: widget.launcher.isRunning,
                ),
              ),
            ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Лимиты запрашиваются у Anthropic при открытии страницы. Если '
            'доступа ко входу профиля нет — из файлов Claude: они отстают от '
            'сервера на 10–20 минут, у закрытых профилей — на момент закрытия.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.isRunning});

  final AccountUsage account;
  final bool Function(Profile) isRunning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = account.usage;
    final now = DateTime.now();
    final names = account.profiles.map((profile) => profile.name).join(', ');
    final open = account.profiles.any(isRunning);
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final profile in account.profiles) ...[
                MarkerDot(marker: profile.marker, size: 12),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  names,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (open) const StatusDot(label: 'Открыт'),
            ],
          ),
          if (account.email case final email?) ...[
            const SizedBox(height: 2),
            Text(email, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 14),
          if (usage == null || usage.limits.isEmpty)
            Text(
              'Нет данных: откройте профиль после входа — Claude сохранит лимиты.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final (index, limit) in usage.limits.indexed) ...[
              if (index > 0) const SizedBox(height: 14),
              UsageLimitRow(limit: limit, now: now),
            ],
        ],
      ),
    );
  }
}
