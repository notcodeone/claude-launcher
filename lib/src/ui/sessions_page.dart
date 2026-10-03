import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../integrations/claude_code_sessions.dart';
import '../integrations/session_overview.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'feature_menu.dart';
import 'settings_pages.dart' show AppearIn;
import 'theme.dart';
import 'widgets.dart';

/// «Сессии»: сессии вкладки Code всех профилей по проектам — где какая лежит.
/// Только чтение: данные — карточки сессий, которые хранит сам Claude.
class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.launcher,
    required this.padding,
    this.preloaded,
    this.preloadedDisk,
  });

  final LauncherController launcher;
  final EdgeInsets padding;

  /// Уже прочитанные данные: в виджет-тестах файлы во время отрисовки не
  /// читаются.
  @visibleForTesting
  final List<ProfileSessions>? preloaded;
  @visibleForTesting
  final Map<String, int>? preloadedDisk;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  late List<ProfileSessions>? _profiles = widget.preloaded;
  final _expanded = <String>{};
  Timer? _reload;
  bool _loading = false;

  /// Место на диске по профилям — считается один раз, при открытии страницы.
  late final _disk = <String, int>{...?widget.preloadedDisk};

  @override
  void initState() {
    super.initState();
    if (widget.preloaded == null) _load();
    if (widget.preloadedDisk == null) _measure();
    // Профиль открыли или закрыли — кнопки «Открыть» и сами сессии меняются.
    widget.launcher.addListener(_scheduleLoad);
  }

  @override
  void dispose() {
    widget.launcher.removeListener(_scheduleLoad);
    _reload?.cancel();
    super.dispose();
  }

  void _scheduleLoad() {
    _reload?.cancel();
    _reload = Timer(const Duration(milliseconds: 800), _load);
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final profiles = await SessionOverview.read(widget.launcher);
      if (mounted) setState(() => _profiles = profiles);
    } finally {
      _loading = false;
    }
  }

  Future<void> _measure() async {
    for (final profile in widget.launcher.profiles) {
      final bytes = await SessionOverview.diskUsage(
        widget.launcher.readableDataDirsOf(profile),
      );
      if (!mounted) return;
      setState(() => _disk[profile.id] = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profiles = _profiles;
    final projects = profiles == null
        ? const <SessionProject>[]
        : SessionOverview.projects(profiles);
    final notices = profiles == null ? const <Widget>[] : _notices(profiles);
    return ListView(
      padding: widget.padding,
      children: [
        // Как в разделах «Настроек»: значок и название перелетели из строки
        // на странице «Возможности».
        Align(
          alignment: Alignment.centerLeft,
          child: FeatureHeading(tile: featureTile('sessions')),
        ),
        for (final notice in notices) ...[const SizedBox(height: 12), notice],
        if (profiles != null) ...[
          const SizedBox(height: 24),
          AppearIn(index: 0, child: _stats(context, profiles)),
        ],
        const SizedBox(height: 12),
        if (profiles == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else if (projects.isEmpty)
          Text('Сессий Code пока нет.', style: theme.textTheme.bodySmall)
        else
          for (final (index, project) in projects.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppearIn(
                index: index.clamp(0, 6),
                child: _project(context, project),
              ),
            ),
      ],
    );
  }

  /// Токены за сегодня и место на диске — по профилям, где Claude открывали.
  Widget _stats(BuildContext context, List<ProfileSessions> profiles) {
    final theme = Theme.of(context);
    final rows = [
      for (final entry in profiles)
        if (entry.profile.usesDefaultFolder ||
            entry.profile.lastLaunchedAt != null)
          entry,
    ];
    return SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          for (final entry in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  MarkerDot(marker: entry.profile.marker, size: 12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.profile.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    [
                      '${tokens(entry.tokensToday ?? 0)} сегодня',
                      if (_disk[entry.profile.id] case final bytes?)
                        size(bytes),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _notices(List<ProfileSessions> profiles) => [
    for (final entry in profiles)
      if (!entry.identity.resolved && entry.profile.lastLaunchedAt != null)
        NoticeRow(
          icon: AppIcons.unknown,
          tone: NoticeTone.neutral,
          title: 'Сессии «${entry.profile.name}» не видны',
          detail:
              'Не удалось определить аккаунт профиля. Откройте профиль — '
              'Claude допишет данные о входе.',
        )
      else if (!entry.formatKnown)
        NoticeRow(
          icon: AppIcons.hand,
          tone: NoticeTone.attention,
          title: 'Claude изменил формат сессий',
          detail:
              'Часть сессий «${entry.profile.name}» (${entry.unreadable}) '
              'лаунчер не понял — они не показаны.',
        ),
  ];

  Widget _project(BuildContext context, SessionProject project) {
    final theme = Theme.of(context);
    final rows = [
      for (final profile in widget.launcher.profiles)
        if (project.byProfile[profile.id] case final sessions?)
          (profile, sessions),
    ];
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            p.basename(project.cwd),
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            project.cwd,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          for (final (profile, sessions) in rows)
            ..._profileRows(context, project, profile, sessions),
        ],
      ),
    );
  }

  List<Widget> _profileRows(
    BuildContext context,
    SessionProject project,
    Profile profile,
    List<SessionCard> sessions,
  ) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final key = '${project.cwd}\n${profile.id}';
    final open = _expanded.contains(key);
    final running = widget.launcher.isRunning(profile);
    return [
      HoverSurface(
        onTap: () =>
            setState(() => open ? _expanded.remove(key) : _expanded.add(key)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              MarkerDot(marker: profile.marker, size: 12),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: profile.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: ' · ${sessionCount(sessions.length)}',
                        style: TextStyle(color: palette.muted),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                when(sessions.first.lastActivity, DateTime.now()),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: open ? 0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(AppIcons.chevron, size: 16, color: palette.muted),
              ),
            ],
          ),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: !open
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(left: 22, bottom: 8),
                child: Column(
                  children: [
                    for (final session in sessions)
                      _session(context, profile, session, running),
                  ],
                ),
              ),
      ),
    ];
  }

  Widget _session(
    BuildContext context,
    Profile profile,
    SessionCard session,
    bool running,
  ) {
    final theme = Theme.of(context);
    final link = CodeSession.linkFor(session.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.title,
                  style: const TextStyle(fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    ?modelName(session.model),
                    when(session.lastActivity, DateTime.now()),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (running && link != null)
            AppButton(
              label: 'Открыть',
              kind: AppButtonKind.secondary,
              onPressed: () => widget.launcher.openLink(profile, link),
            ),
        ],
      ),
    );
  }
}

/// «1 сессия», «3 сессии», «12 сессий».
String sessionCount(int count) {
  final ten = count % 10, hundred = count % 100;
  final word = ten == 1 && hundred != 11
      ? 'сессия'
      : ten >= 2 && ten <= 4 && (hundred < 12 || hundred > 14)
      ? 'сессии'
      : 'сессий';
  return '$count $word';
}

/// «12 400 токенов».
String tokens(int count) {
  final digits = count.toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write('\u202F');
    grouped.write(digits[i]);
  }
  final ten = count % 10, hundred = count % 100;
  final word = ten == 1 && hundred != 11
      ? 'токен'
      : ten >= 2 && ten <= 4 && (hundred < 12 || hundred > 14)
      ? 'токена'
      : 'токенов';
  return '$grouped $word';
}

/// «271 МБ», «1,2 ГБ».
String size(int bytes) {
  const mb = 1024 * 1024, gb = 1024 * mb;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  }
  return '${(bytes / mb).round()} МБ';
}

/// Сегодня — время, вчера — «вчера», раньше — дата.
String when(DateTime time, DateTime now) {
  final local = time.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  String two(int value) => value.toString().padLeft(2, '0');
  if (day == today) return '${two(local.hour)}:${two(local.minute)}';
  if (today.difference(day).inDays == 1) return 'вчера';
  final date = '${two(local.day)}.${two(local.month)}';
  return local.year == now.year ? date : '$date.${local.year}';
}

/// `claude-opus-5-5[1m]` → «Opus 5.5»; незнакомое — как есть.
String? modelName(String? model) {
  if (model == null) return null;
  final match = RegExp(
    r'(opus|sonnet|haiku|fable)-(\d+)-(\d+)',
  ).firstMatch(model);
  if (match == null) return model;
  final family = match[1]!;
  return '${family[0].toUpperCase()}${family.substring(1)} ${match[2]}.${match[3]}';
}
