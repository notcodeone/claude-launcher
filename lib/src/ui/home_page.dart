import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_dialog.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.launcher});

  final LauncherController launcher;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: launcher,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          children: [
            _Header(launcher: launcher),
            const SizedBox(height: 16),
            ..._banners(context),
            Row(
              children: [
                Text('Профили', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _addProfile(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final profile in launcher.profiles)
              _ProfileCard(launcher: launcher, profile: profile),
            const SizedBox(height: 16),
            Text(
              'Переключение закрывает открытый Claude так же, как обычный выход '
              'из приложения, и открывает выбранный профиль. Одновременно открыт '
              'только один профиль — так вход через браузер всегда попадает в нужное окно.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _banners(BuildContext context) {
    final status = launcher.switchStatus;
    return [
      if (!launcher.located) const LinearProgressIndicator(),
      if (launcher.firstRun)
        _Banner(
          icon: Icons.info_outline,
          text: Platform.isMacOS
              ? 'Claude Launcher живёт в строке меню — ищите иконку с двумя кружками '
                  'вверху экрана. Через неё переключаются профили; это окно можно закрыть.'
              : 'Claude Launcher живёт в трее у часов (возможно, под стрелкой ▲). '
                  'Через его иконку переключаются профили; это окно можно закрыть.',
        ),
      if (launcher.located && launcher.claudePath == null)
        const _Banner(
          icon: Icons.error_outline,
          error: true,
          text: 'Claude не найден. Установите приложение Claude с claude.com/download.',
        ),
      if (status != null) _SwitchBanner(launcher: launcher, status: status),
      if (launcher.lastError case final error?)
        _Banner(icon: Icons.error_outline, error: true, text: error),
      for (final instance in launcher.unknownInstances)
        _Banner(
          icon: Icons.help_outline,
          text: 'Открыт Claude с папкой, которой нет в профилях: '
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
        return 'Папка данных: ${p.join(launcher.host.profilesBaseDir, folder)}\n'
            'Создастся при первом запуске — тогда же нужно будет войти в аккаунт.';
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

class _Header extends StatelessWidget {
  const _Header({required this.launcher});

  final LauncherController launcher;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = launcher.runningProfiles;
    final status = switch (running) {
      [] when launcher.unknownInstances.isEmpty => 'Claude сейчас не запущен',
      [] => 'Открыт Claude с неизвестным профилем',
      [final single] => 'Сейчас открыт: ${single.title}',
      _ => 'Открыто несколько: ${running.map((profile) => profile.title).join(', ')}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Claude Launcher', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(status, style: theme.textTheme.bodyLarge),
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
    final closing = status.closing.join(', ');
    final text = switch (status.phase) {
      SwitchPhase.closing => 'Закрываю $closing, чтобы открыть ${status.target.title}…',
      SwitchPhase.waitingForUser => launcher.host.manualQuitHint,
      SwitchPhase.launching => 'Открываю ${status.target.title}…',
    };
    return _Banner(
      icon: status.phase == SwitchPhase.waitingForUser
          ? Icons.pan_tool_outlined
          : Icons.sync,
      text: text,
      progress: true,
      action: status.phase == SwitchPhase.launching
          ? null
          : TextButton(onPressed: launcher.cancelSwitch, child: const Text('Отмена')),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    this.error = false,
    this.progress = false,
    this.action,
  });

  final IconData icon;
  final String text;
  final bool error;
  final bool progress;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: error ? colors.errorContainer : colors.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: error ? colors.onErrorContainer : colors.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(child: SelectableText(text)),
                ?action,
              ],
            ),
            if (progress) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
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
      if (profile.email.isNotEmpty) profile.email,
      if (profile.usesDefaultFolder)
        'Стандартная папка Claude'
      else if (profile.lastLaunchedAt == null)
        'Ещё не открывался — при первом запуске войдите в аккаунт'
      else
        'Папка ${profile.folderName}',
      if (profile.note.isNotEmpty) profile.note,
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: Text(profile.marker, style: const TextStyle(fontSize: 26)),
        title: Row(
          children: [
            Flexible(child: Text(profile.name, overflow: TextOverflow.ellipsis)),
            if (running) ...[
              const SizedBox(width: 8),
              Text('открыт',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            ],
          ],
        ),
        subtitle: Text(details.join('\n')),
        isThreeLine: details.length > 1,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            running
                ? FilledButton.tonal(
                    onPressed: switching ? null : () => launcher.switchTo(profile),
                    child: const Text('Показать'),
                  )
                : FilledButton(
                    onPressed: switching || launcher.claudePath == null
                        ? null
                        : () => launcher.switchTo(profile),
                    child: const Text('Открыть'),
                  ),
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              onSelected: (action) => switch (action) {
                'edit' => _edit(context),
                'folder' => launcher.host.revealFolder(launcher.dataDirOf(profile)),
                'remove' => _remove(context),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Изменить')),
                PopupMenuItem(
                  value: 'folder',
                  child: Text(Platform.isMacOS ? 'Показать папку в Finder' : 'Открыть папку'),
                ),
                PopupMenuItem(
                  value: 'remove',
                  enabled: !running,
                  child: const Text('Убрать из списка'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final draft = await showProfileDialog(
      context,
      profile: profile,
      folderLabel: (_) => 'Папка данных: ${launcher.dataDirOf(profile)}',
    );
    if (draft == null) return;
    await launcher.updateProfile(profile.copyWith(
      name: draft.name,
      email: draft.email,
      note: draft.note,
      marker: draft.marker,
    ));
  }

  Future<void> _remove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Убрать «${profile.name}»?'),
        content: Text(
          'Профиль исчезнет из списка. Папка данных останется на диске, '
          'её можно удалить вручную:\n\n${launcher.dataDirOf(profile)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (confirmed == true) await launcher.removeProfile(profile);
  }
}
