import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_settings.dart';
import '../integrations/session_overview.dart';
import '../integrations/session_sync_service.dart';
import '../launcher_controller.dart';
import 'feature_menu.dart';
import 'settings_pages.dart' show AppearIn, SegmentedChoice;
import 'theme.dart';
import 'widgets.dart';

/// «Синхронизация сессий»: какие профили держать с общими сессиями Code и
/// какие проекты. Сама синхронизация — [SessionSyncService].
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.launcher,
    required this.settings,
    required this.sync,
    required this.padding,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final SessionSyncService sync;
  final EdgeInsets padding;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  /// Папки проектов, в которых есть сессии, — для выбора.
  List<String>? _projects;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final profiles = await SessionOverview.read(widget.launcher);
    if (!mounted) return;
    setState(
      () => _projects = [
        for (final project in SessionOverview.projects(profiles)) project.cwd,
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.settings,
      widget.sync,
      widget.launcher,
    ]),
    builder: (context, _) {
      final cards = [
        _main(context),
        if (widget.settings.sessionSync) ...[
          _profiles(context),
          _projectsCard(context),
        ],
      ];
      return ListView(
        padding: widget.padding,
        children: [
          // Как в разделах «Настроек»: значок и название перелетели из строки.
          Align(
            alignment: Alignment.centerLeft,
            child: FeatureHeading(tile: featureTile('sync')),
          ),
          for (final (index, card) in cards.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: AppearIn(index: index + 1, child: card),
            ),
        ],
      );
    },
  );

  Widget _main(BuildContext context) {
    final settings = widget.settings;
    final sync = widget.sync;
    final group = widget.launcher.profiles
        .where((profile) => settings.syncProfiles.contains(profile.id))
        .length;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingSwitchRow(
            title: 'Синхронизировать сессии',
            description:
                'Новые сессии Code появляются во всех выбранных профилях, '
                'удалённые — убираются из всех. Открытые профили догоняются, '
                'когда их закрывают.',
            value: settings.sessionSync,
            onChanged: (enabled) async {
              await settings.setSessionSync(enabled);
              if (enabled) await sync.syncNow();
            },
          ),
          if (settings.sessionSync) ...[
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _SyncStatus(sync: sync, ready: group >= 2),
            if (sync.lastResult?.deletionsStopped ?? false) ...[
              const SizedBox(height: 12),
              const NoticeRow(
                icon: AppIcons.hand,
                tone: NoticeTone.attention,
                title: 'Удаления не выполнены',
                detail:
                    'Сразу удалить пришлось бы слишком много сессий — похоже на '
                    'сбой. Проверьте профили; удалённое вручную не вернётся.',
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _profiles(BuildContext context) => _checkCard(
    context,
    label: 'Профили',
    rows: [
      for (final profile in widget.launcher.profiles)
        _CheckRow(
          leading: MarkerDot(marker: profile.marker, size: 12),
          label: profile.name,
          checked: widget.settings.syncProfiles.contains(profile.id),
          onTap: () => widget.settings.toggleSyncProfile(profile.id),
        ),
    ],
  );

  Widget _projectsCard(BuildContext context) {
    final selected = widget.settings.syncProjects;
    final projects = _projects;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Проекты'),
          SegmentedChoice<bool>(
            value: selected == null,
            options: const [
              (true, AppIcons.folder, 'Все'),
              (false, AppIcons.check, 'Выбранные'),
            ],
            onChanged: (all) =>
                widget.settings.setSyncProjects(all ? null : const []),
          ),
          if (selected != null) ...[
            const SizedBox(height: 8),
            if (projects == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (projects.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Сессий Code пока нет',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final cwd in projects)
                _CheckRow(
                  label: p.basename(cwd),
                  detail: cwd,
                  checked: selected.contains(cwd),
                  onTap: () => widget.settings.setSyncProjects(
                    selected.contains(cwd)
                        ? selected.where((value) => value != cwd).toList()
                        : [...selected, cwd],
                  ),
                ),
          ],
        ],
      ),
    );
  }

  Widget _checkCard(
    BuildContext context, {
    required String label,
    required List<Widget> rows,
  }) => SoftCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [FieldLabel(label), ...rows],
    ),
  );
}

/// Строка выбора: необязательная метка, название и галочка справа.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.checked,
    required this.onTap,
    this.leading,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool checked;
  final VoidCallback onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    return HoverSurface(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            if (leading case final leading?) ...[
              leading,
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  if (detail case final detail?)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(
                checked ? AppIcons.checked : AppIcons.unchecked,
                key: ValueKey(checked),
                size: 20,
                color: checked ? p.text : p.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка состояния: что было в последний раз и кнопка «Синхронизировать».
class _SyncStatus extends StatefulWidget {
  const _SyncStatus({required this.sync, required this.ready});

  final SessionSyncService sync;

  /// В группе хотя бы два профиля — есть что синхронизировать.
  final bool ready;

  @override
  State<_SyncStatus> createState() => _SyncStatusState();
}

class _SyncStatusState extends State<_SyncStatus>
    with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(_SyncStatus old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (widget.sync.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      // Докручиваем до целого оборота, чтобы стрелки не замирали криво.
      _spin.forward(from: _spin.value).then((_) => _spin.reset());
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final sync = widget.sync;
    final (icon, color, title, detail) = _describe(p);
    return Row(
      children: [
        RotationTransition(
          turns: icon == AppIcons.sync ? _spin : kAlwaysDismissedAnimation,
          child: Icon(icon, size: 20, color: color),
        ),
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
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        AppButton(
          label: 'Синхронизировать',
          onPressed: sync.syncing || !widget.ready ? null : sync.syncNow,
        ),
      ],
    );
  }

  (IconData, Color, String, String?) _describe(Palette p) {
    final sync = widget.sync;
    if (!widget.ready) {
      return (AppIcons.info, p.muted, 'Нужно два профиля', 'Отметьте их ниже');
    }
    if (sync.syncing) {
      return (AppIcons.sync, p.text, 'Синхронизирую…', null);
    }
    if (sync.error case final error?) {
      return (AppIcons.error, p.danger, 'Не получилось', error);
    }
    final at = sync.lastAt;
    final result = sync.lastResult;
    if (at == null || result == null) {
      return (
        AppIcons.waiting,
        p.muted,
        'Ещё не синхронизировали',
        'Начнётся при закрытии профиля',
      );
    }
    String two(int value) => value.toString().padLeft(2, '0');
    final changes = [
      if (result.copied > 0) 'скопировано ${result.copied}',
      if (result.updated > 0) 'обновлено ${result.updated}',
      if (result.removed > 0) 'убрано ${result.removed}',
    ];
    final details = [
      changes.isEmpty ? 'Всё уже совпадало' : _capitalize(changes.join(', ')),
      if (result.skipped.isNotEmpty)
        'ждут закрытия: ${result.skipped.map((name) => '«$name»').join(', ')}',
    ];
    return (
      AppIcons.checked,
      p.success,
      'Синхронизировано в ${two(at.hour)}:${two(at.minute)}',
      details.join(' · '),
    );
  }

  static String _capitalize(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}
