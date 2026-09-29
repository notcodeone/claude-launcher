import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.launcher});

  final LauncherController launcher;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: AppFab(
        icon: Icons.add_rounded,
        tooltip: 'Добавить профиль',
        onPressed: () => _addProfile(context),
      ),
      body: Column(
        children: [
          // На macOS заголовок окна скрыт: эта полоса — место под кнопки окна и для перетаскивания.
          if (Platform.isMacOS)
            const DragToMoveArea(
              child: SizedBox(height: 32, width: double.infinity),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: launcher,
              builder: (context, _) => ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  Platform.isMacOS ? 8 : 28,
                  24,
                  96,
                ),
                children: [
                  Text(
                    'Профили',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  _StatusLine(launcher: launcher),
                  const SizedBox(height: 24),
                  ..._banners(context),
                  if (launcher.located && launcher.claudePath == null)
                    const _EmptyState(
                      mood: FaceMood.worried,
                      title: 'Claude не найден',
                      text:
                          'Установите приложение Claude с claude.com/download '
                          'и перезапустите лаунчер.',
                    )
                  else if (launcher.profiles.isEmpty)
                    _EmptyState(
                      mood: FaceMood.sleepy,
                      title: 'Ничего нет..',
                      text: 'Создайте профиль для каждого аккаунта Claude.',
                      action: AppButton(
                        label: 'Создать',
                        onPressed: () => _addProfile(context),
                      ),
                    ),
                  for (final profile in launcher.profiles) ...[
                    _ProfileCard(launcher: launcher, profile: profile),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  // Отступ справа — чтобы подсказку не перекрывала кнопка «+».
                  Padding(
                    padding: const EdgeInsets.only(right: 64),
                    child: Text(
                      'Переключение закрывает открытый Claude так же, как обычный выход '
                      'из приложения, и открывает выбранный профиль. Одновременно открыт '
                      'только один профиль — так вход через браузер всегда попадает в нужное окно.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _banners(BuildContext context) {
    final status = launcher.switchStatus;
    return [
      if (!launcher.located)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: LinearProgressIndicator(),
        ),
      if (launcher.firstRun && status == null)
        InfoBanner(
          icon: Icons.info_outline_rounded,
          text: Platform.isMacOS
              ? 'Claude Launcher живёт в строке меню — ищите иконку с двумя кружками '
                    'вверху экрана. Это окно можно закрыть.'
              : 'Claude Launcher живёт в трее у часов (возможно, под стрелкой ▲). '
                    'Это окно можно закрыть.',
        ),
      if (status != null) _SwitchBanner(launcher: launcher, status: status),
      if (launcher.lastError case final error?)
        InfoBanner(icon: Icons.error_outline_rounded, error: true, text: error),
      for (final instance in launcher.unknownInstances)
        InfoBanner(
          icon: Icons.help_outline_rounded,
          text:
              'Открыт Claude с папкой, которой нет в профилях:\n'
              '${launcher.host.dataDirOf(instance)}',
        ),
    ];
  }

  Future<void> _addProfile(BuildContext context) async {
    final draft = await showProfileDialog(
      context,
      folderLabel: (name) {
        final folder = folderNameFor(name.isEmpty ? 'profile' : name, [
          for (final profile in launcher.profiles) ?profile.folderName,
        ]);
        return 'Данные профиля будут в ${p.join(launcher.host.profilesBaseDir, folder)}. '
            'При первом запуске войдите в аккаунт — дальше вход сохранится.';
      },
    );
    if (draft == null) return;
    await launcher.addProfile(
      name: draft.name,
      email: draft.email,
      note: draft.note,
      marker: draft.marker,
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.launcher});

  final LauncherController launcher;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final muted = TextStyle(color: p.muted, fontSize: 14);
    final running = launcher.runningProfiles;
    if (running.isEmpty) {
      return Text(
        launcher.unknownInstances.isEmpty
            ? 'Claude сейчас не запущен'
            : 'Открыт Claude с неизвестным профилем',
        style: muted,
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          running.length == 1 ? 'Сейчас открыт' : 'Сейчас открыты',
          style: muted,
        ),
        for (final profile in running)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MarkerDot(marker: profile.marker, size: 10),
              const SizedBox(width: 6),
              Text(
                profile.name,
                style: TextStyle(
                  color: p.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _SwitchBanner extends StatelessWidget {
  const _SwitchBanner({required this.launcher, required this.status});

  final LauncherController launcher;
  final SwitchStatus status;

  @override
  Widget build(BuildContext context) {
    final closing = status.closing.map((name) => '«$name»').join(', ');
    final target = '«${status.target.name}»';
    final text = switch (status.phase) {
      SwitchPhase.closing => 'Закрываю $closing, чтобы открыть $target…',
      SwitchPhase.waitingForUser => launcher.host.manualQuitHint,
      SwitchPhase.launching => 'Открываю $target…',
    };
    return InfoBanner(
      icon: status.phase == SwitchPhase.waitingForUser
          ? Icons.pan_tool_outlined
          : Icons.sync_rounded,
      text: text,
      progress: true,
      action: status.phase == SwitchPhase.launching
          ? null
          : AppButton(
              label: 'Отмена',
              kind: AppButtonKind.text,
              compact: true,
              onPressed: launcher.cancelSwitch,
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.mood,
    required this.title,
    required this.text,
    this.action,
  });

  final FaceMood mood;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
        child: Column(
          children: [
            FaceIllustration(mood: mood, size: 88),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.launcher, required this.profile});

  final LauncherController launcher;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = launcher.isRunning(profile);
    final switching = launcher.switchStatus != null;
    final details = [
      if (profile.usesDefaultFolder)
        'Стандартная папка Claude'
      else if (profile.lastLaunchedAt == null)
        'Ещё не открывался — при первом запуске войдите в аккаунт'
      else
        'Папка ${profile.folderName}',
      if (profile.note.isNotEmpty) profile.note,
    ];

    return SoftCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Row(
        children: [
          MarkerDot(marker: profile.marker, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: 10),
                      const StatusDot(label: 'Открыт'),
                    ],
                  ],
                ),
                if (profile.email.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(profile.email, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 4),
                for (final line in details)
                  Text(line, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton(
            label: running ? 'Показать' : 'Открыть',
            kind: running ? AppButtonKind.secondary : AppButtonKind.primary,
            compact: true,
            onPressed: switching || launcher.claudePath == null
                ? null
                : () => launcher.switchTo(profile),
          ),
          _MoreButton(launcher: launcher, profile: profile, running: running),
        ],
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.launcher,
    required this.profile,
    required this.running,
  });

  final LauncherController launcher;
  final Profile profile;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String label, {
      Color? color,
      bool enabled = true,
    }) {
      final foreground = enabled ? (color ?? p.text) : p.muted;
      return PopupMenuItem(
        value: value,
        enabled: enabled,
        height: 46,
        child: Row(
          children: [
            Icon(icon, size: 19, color: foreground),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: foreground, fontSize: 14)),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Ещё',
      icon: Icon(Icons.more_vert_rounded, color: p.muted),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      onSelected: (action) => switch (action) {
        'edit' => _edit(context),
        'folder' => launcher.host.revealFolder(launcher.dataDirOf(profile)),
        'remove' => _remove(context),
        _ => null,
      },
      itemBuilder: (_) => [
        item('edit', Icons.edit_outlined, 'Изменить'),
        const PopupMenuDivider(height: 1),
        item(
          'folder',
          Icons.folder_open_outlined,
          Platform.isMacOS ? 'Показать папку в Finder' : 'Открыть папку',
        ),
        const PopupMenuDivider(height: 1),
        item(
          'remove',
          Icons.delete_outline_rounded,
          'Убрать из списка',
          color: p.danger,
          enabled: !running,
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final draft = await showProfileDialog(
      context,
      profile: profile,
      folderLabel: (_) => 'Данные профиля: ${launcher.dataDirOf(profile)}',
    );
    if (draft == null) return;
    await launcher.updateProfile(
      profile.copyWith(
        name: draft.name,
        email: draft.email,
        note: draft.note,
        marker: draft.marker,
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Убрать «${profile.name}»?',
      text:
          'Профиль исчезнет из списка. Папка с данными останется на диске — '
          'её можно удалить вручную.',
      detail: launcher.dataDirOf(profile),
      confirmLabel: 'Убрать',
    );
    if (confirmed) await launcher.removeProfile(profile);
  }
}
