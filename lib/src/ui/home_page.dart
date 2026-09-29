import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'anchored_menu.dart';
import 'profile_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.launcher, required this.settings});

  final LauncherController launcher;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(16, Platform.isMacOS ? 0 : 16, 16, 0),
      child: _HeaderBar(settings: settings),
    );
    return Scaffold(
      floatingActionButton: AppFab(
        icon: AppIcons.add,
        tooltip: 'Добавить профиль',
        onPressed: () => _addProfile(context),
      ),
      body: Column(
        children: [
          // На macOS заголовок окна скрыт: сверху место под кнопки окна.
          // Окно перетаскивается за эту полосу и за название в шапке.
          if (Platform.isMacOS)
            const DragToMoveArea(
              child: SizedBox(height: 30, width: double.infinity),
            ),
          header,
          Expanded(
            child: ListenableBuilder(
              listenable: launcher,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 96),
                children: [
                  Text('Профили', style: theme.textTheme.headlineMedium),
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
                      style: theme.textTheme.bodySmall,
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
          icon: AppIcons.info,
          text: Platform.isMacOS
              ? 'Claude Launcher живёт в строке меню — ищите иконку с двумя кружками '
                    'вверху экрана. Это окно можно закрыть.'
              : 'Claude Launcher живёт в трее у часов (возможно, под стрелкой ▲). '
                    'Это окно можно закрыть.',
        ),
      if (status != null) _SwitchBanner(launcher: launcher, status: status),
      if (launcher.lastError case final error?)
        InfoBanner(icon: AppIcons.error, error: true, text: error),
      for (final instance in launcher.unknownInstances)
        InfoBanner(
          icon: AppIcons.unknown,
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
      icon: draft.icon,
    );
  }
}

/// Плавающая шапка, как в sensomni: название слева, тема окна справа.
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.settings, this.interactive = true});

  final AppSettings settings;

  /// Копия шапки поверх затемнения под меню не реагирует на клики.
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final icon = switch (settings.themeMode) {
      ThemeMode.system => AppIcons.themeSystem,
      ThemeMode.light => AppIcons.themeLight,
      ThemeMode.dark => AppIcons.themeDark,
    };
    final title = Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'Claude Launcher',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
    );
    return Builder(
      builder: (cardContext) => SoftCard(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
        child: Row(
          children: [
            // Кнопку темы в область перетаскивания не кладём: та ждёт двойного
            // клика (развернуть окно), и одиночные клики срабатывали бы с задержкой.
            Expanded(child: _dragArea(title)),
            CircleIconButton(
              icon: icon,
              tooltip: interactive ? 'Тема окна' : null,
              onPressed: interactive ? () => _openThemeMenu(cardContext) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _dragArea(Widget child) => Platform.isMacOS && interactive
      ? DragToMoveArea(child: SizedBox(height: 36, child: child))
      : SizedBox(height: 36, child: child);

  Future<void> _openThemeMenu(BuildContext cardContext) async {
    MenuEntry<ThemeMode> entry(ThemeMode mode, IconData icon, String label) =>
        MenuEntry(
          value: mode,
          icon: icon,
          label: label,
          selected: settings.themeMode == mode,
        );
    final mode = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: _HeaderBar(settings: settings, interactive: false),
      entries: [
        entry(ThemeMode.system, AppIcons.themeSystem, 'Как в системе'),
        entry(ThemeMode.light, AppIcons.themeLight, 'Светлая'),
        entry(ThemeMode.dark, AppIcons.themeDark, 'Тёмная'),
      ],
    );
    if (mode != null) await settings.setThemeMode(mode);
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
          ? AppIcons.hand
          : AppIcons.sync,
      text: text,
      progress: true,
      action: status.phase == SwitchPhase.launching
          ? null
          : AppButton(
              label: 'Отмена',
              kind: AppButtonKind.secondary,
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
  const _ProfileCard({
    required this.launcher,
    required this.profile,
    this.interactive = true,
  });

  final LauncherController launcher;
  final Profile profile;

  /// Копия карточки поверх затемнения под меню не реагирует на клики.
  final bool interactive;

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

    return Builder(
      builder: (cardContext) => SoftCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 10, 16),
        child: Row(
          children: [
            ProfileAvatar(marker: profile.marker, icon: profile.icon),
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
              kind: running ? AppButtonKind.primary : AppButtonKind.secondary,
              // У копии карточки кнопка выглядит активной, но клики до неё не доходят.
              onPressed: switching || launcher.claudePath == null
                  ? null
                  : () {
                      if (interactive) launcher.switchTo(profile);
                    },
            ),
            const SizedBox(width: 2),
            CircleIconButton(
              icon: AppIcons.more,
              tooltip: interactive ? 'Ещё' : null,
              onPressed: interactive ? () => _openMenu(cardContext) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext cardContext) async {
    final running = launcher.isRunning(profile);
    final action = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: ListenableBuilder(
        listenable: launcher,
        builder: (_, _) => _ProfileCard(
          launcher: launcher,
          profile: profile,
          interactive: false,
        ),
      ),
      entries: [
        const MenuEntry(value: 'edit', icon: AppIcons.edit, label: 'Изменить'),
        MenuEntry(
          value: 'folder',
          icon: AppIcons.folder,
          label: Platform.isMacOS ? 'Показать папку в Finder' : 'Открыть папку',
        ),
        MenuEntry(
          value: 'remove',
          icon: AppIcons.remove,
          label: 'Убрать из списка',
          destructive: true,
          enabled: !running,
        ),
      ],
    );
    if (!cardContext.mounted) return;
    switch (action) {
      case 'edit':
        await _edit(cardContext);
      case 'folder':
        await launcher.host.revealFolder(launcher.dataDirOf(profile));
      case 'remove':
        await _remove(cardContext);
    }
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
        icon: draft.icon,
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
