import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../app_settings.dart';
import '../integrations/claude_code_events.dart';
import '../integrations/claude_code_integration.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'anchored_menu.dart';
import 'profile_dialog.dart';
import 'settings_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.launcher,
    required this.settings,
    required this.claudeCode,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;

  /// Поля окна: по ним выровнены шапка, заголовок, карточки, кнопка и подвал.
  static const gutter = 24.0;
  static const _headerHeight = 52.0;
  static const _footerHeight = 40.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    // На macOS заголовок окна скрыт: сверху место под кнопки окна.
    final headerTop = Platform.isMacOS ? 46.0 : 16.0;
    final scrimHeight = headerTop + _headerHeight + 16;

    // Шапка и подвал парят над списком, как в sensomni: при прокрутке карточки
    // плавно уходят под них, а не обрезаются по линии.
    Widget scrim({
      required bool top,
      required double height,
      required double solid,
    }) {
      final fade = p.background.withValues(alpha: 0);
      return IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [p.background, p.background, fade],
              stops: [0, solid / height, 1],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([launcher, claudeCode]),
            builder: (context, _) => ListView(
              padding: EdgeInsets.fromLTRB(
                gutter,
                headerTop + _headerHeight + 28,
                gutter,
                // Запас под подвал и кнопку «Добавить профиль», чтобы докрутить до конца.
                _footerHeight + 8 + 52 + 24,
              ),
              children: [
                Text('Профили', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  // По предложению на строку — без одинокого слова на второй.
                  'Каждый профиль — отдельный вход в Claude.\n'
                  'Одновременно открыт только один.',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 13.5),
                ),
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
                // Пока профили грузятся, список пуст — это не «ничего нет».
                else if (launcher.located && launcher.profiles.isEmpty)
                  _EmptyState(
                    mood: FaceMood.sleepy,
                    title: 'Ничего нет..',
                    text: 'Создайте профиль для каждого аккаунта Claude.',
                    action: AppButton(
                      label: 'Создать',
                      onPressed: () => _addProfile(context),
                    ),
                  ),
                for (final (index, profile) in launcher.profiles.indexed) ...[
                  if (index > 0) const SizedBox(height: 12),
                  _ProfileCard(
                    launcher: launcher,
                    settings: settings,
                    claudeCode: claudeCode,
                    profile: profile,
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: scrimHeight,
            child: scrim(
              top: true,
              height: scrimHeight,
              solid: headerTop + _headerHeight / 2,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _footerHeight + 24,
            child: scrim(
              top: false,
              height: _footerHeight + 24,
              solid: _footerHeight,
            ),
          ),
          // Окно перетаскивается за эту полосу и за название в шапке.
          if (Platform.isMacOS)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: headerTop,
              child: const DragToMoveArea(child: SizedBox.expand()),
            ),
          Positioned(
            top: headerTop,
            left: gutter,
            right: gutter,
            child: _HeaderBar(
              launcher: launcher,
              settings: settings,
              claudeCode: claudeCode,
            ),
          ),
          // Подвал в стиле sensomni.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _footerHeight,
            child: _Footer(),
          ),
          // Кнопка по полю окна, над подвалом.
          Positioned(
            right: gutter,
            bottom: _footerHeight + 8,
            child: AppFab(
              icon: AppIcons.add,
              label: 'Добавить',
              onPressed: () => _addProfile(context),
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

/// Нижняя строка, как подвал сайта sensomni: копирайт слева, автор справа.
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall!.copyWith(color: p.muted, fontSize: 11.5);
    // Отступы кнопки «NotCode» — ровно в ширину пробела: «Designed by NotCode»
    // читается как обычная фраза, а подложка при наведении не липнет к буквам.
    final space = (TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    return Padding(
      // Справа меньше на ширину пробела, чтобы текст стоял на отступе 24, как слева.
      padding: EdgeInsets.fromLTRB(
        HomePage.gutter,
        0,
        HomePage.gutter - space,
        4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '© ${DateTime.now().year} ClaudeLauncher',
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('Designed by', style: style),
          // Пока без действия, но нажимается и подсвечивается.
          _FooterButton(
            label: 'NotCode',
            style: style,
            horizontalPadding: space,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

/// Текстовая кнопка подвала: без фона, при наведении — серая скруглённая подложка.
class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.label,
    required this.style,
    required this.horizontalPadding,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final double horizontalPadding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: p.field,
        highlightColor: p.text.withValues(alpha: 0.08),
        splashColor: p.text.withValues(alpha: 0.10),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 3,
          ),
          child: Text(label, style: style),
        ),
      ),
    );
  }
}

/// Плавающая шапка, как в sensomni: название слева, тема и настройки справа.
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.launcher,
    required this.settings,
    required this.claudeCode,
    this.interactive = true,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;

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
        'ClaudeLauncher',
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
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            // Кнопку темы в область перетаскивания не кладём: та ждёт двойного
            // клика (развернуть окно), и одиночные клики срабатывали бы с задержкой.
            Expanded(child: _dragArea(title)),
            CircleIconButton(
              icon: icon,
              tooltip: interactive ? 'Тема окна' : null,
              onPressed: () {
                if (interactive) _openThemeMenu(cardContext);
              },
            ),
            CircleIconButton(
              icon: AppIcons.settings,
              tooltip: interactive ? 'Настройки' : null,
              onPressed: () {
                if (interactive) {
                  showSettingsDialog(
                    context,
                    launcher: launcher,
                    settings: settings,
                    claudeCode: claudeCode,
                  );
                }
              },
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
      highlight: _HeaderBar(
        launcher: launcher,
        settings: settings,
        claudeCode: claudeCode,
        interactive: false,
      ),
      entries: [
        entry(ThemeMode.system, AppIcons.themeSystem, 'Как в системе'),
        entry(ThemeMode.light, AppIcons.themeLight, 'Светлая'),
        entry(ThemeMode.dark, AppIcons.themeDark, 'Тёмная'),
      ],
    );
    if (mode != null) await settings.setThemeMode(mode);
  }
}

class _SwitchBanner extends StatelessWidget {
  const _SwitchBanner({required this.launcher, required this.status});

  final LauncherController launcher;
  final SwitchStatus status;

  @override
  Widget build(BuildContext context) {
    final closing = status.closing.map((name) => '«$name»').join(', ');
    final target = status.target == null ? null : '«${status.target!.name}»';
    final text = switch (status.phase) {
      SwitchPhase.closing when target == null => 'Закрываю $closing…',
      SwitchPhase.closing => 'Закрываю $closing, чтобы открыть $target…',
      SwitchPhase.waitingForUser => launcher.host.manualQuitHint,
      SwitchPhase.launching => 'Открываю $target…',
    };
    final cancel = AppButton(
      label: 'Отмена',
      kind: AppButtonKind.secondary,
      onPressed: launcher.cancelSwitch,
    );
    if (status.phase == SwitchPhase.waitingForUser) {
      // Claude не закрылся сам (на Windows ушёл в трей) — даём закрыть его
      // принудительно одной кнопкой, но только по явному выбору.
      return InfoBanner(
        icon: AppIcons.hand,
        text:
            '$text При принудительном закрытии несохранённое в Claude может '
            'потеряться.',
        progress: true,
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            cancel,
            const SizedBox(width: 8),
            AppButton(
              label: 'Закрыть принудительно',
              onPressed: launcher.forceClose,
            ),
          ],
        ),
      );
    }
    return InfoBanner(
      icon: AppIcons.sync,
      text: text,
      progress: true,
      action: status.phase == SwitchPhase.launching ? null : cancel,
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
    required this.settings,
    required this.claudeCode,
    required this.profile,
    this.interactive = true,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
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
      ?_eventLine(claudeCode.lastEvents[profile.id]),
    ];

    return Builder(
      builder: (cardContext) => SoftCard(
        // Справа 8: у кнопок-иконок свои 8 px вокруг значка — визуально те же 16.
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        child: Row(
          children: [
            ProfileAvatar(marker: profile.marker, icon: profile.icon),
            const SizedBox(width: 12),
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
                        const SizedBox(width: 8),
                        const StatusDot(label: 'Открыт'),
                      ],
                      // Профиль, который лаунчер открывает при своём запуске.
                      if (settings.startupProfileId == profile.id) ...[
                        const SizedBox(width: 8),
                        const Tooltip(
                          message: 'Открывается при запуске лаунчера',
                          child: Tag(label: 'По умолчанию'),
                        ),
                      ],
                    ],
                  ),
                  if (profile.email.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      profile.email,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  for (final line in details)
                    Text(line, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            CircleIconButton(
              icon: running ? AppIcons.show : AppIcons.launch,
              tooltip: !interactive
                  ? null
                  : running
                  ? 'Показать окно Claude'
                  : 'Открыть профиль',
              // У копии карточки кнопка выглядит активной, но клики до неё не доходят.
              onPressed: switching || launcher.claudePath == null
                  ? null
                  : () {
                      if (interactive) launcher.switchTo(profile);
                    },
            ),
            CircleIconButton(
              icon: AppIcons.more,
              tooltip: interactive ? 'Ещё' : null,
              onPressed: () {
                if (interactive) _openMenu(cardContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// «Claude Code завершил задачу · claude-launcher · 14:32».
  static String? _eventLine(ClaudeCodeEvent? event) {
    if (event == null) return null;
    final what = switch (event.kind) {
      ClaudeCodeEventKind.finished => 'Claude Code завершил задачу',
      ClaudeCodeEventKind.needsPermission => 'Claude Code ждёт разрешения',
      ClaudeCodeEventKind.waiting => 'Claude Code ждёт ответа',
    };
    final project = event.cwd.isEmpty ? '' : ' · ${p.basename(event.cwd)}';
    String two(int value) => value.toString().padLeft(2, '0');
    return '$what$project · ${two(event.time.hour)}:${two(event.time.minute)}';
  }

  Future<void> _openMenu(BuildContext cardContext) async {
    final running = launcher.isRunning(profile);
    final action = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: ListenableBuilder(
        listenable: launcher,
        builder: (_, _) => _ProfileCard(
          launcher: launcher,
          settings: settings,
          claudeCode: claudeCode,
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
          value: 'quit',
          icon: AppIcons.quit,
          label: 'Завершить работу',
          enabled: running && launcher.switchStatus == null,
        ),
        MenuEntry(
          value: 'remove',
          icon: AppIcons.remove,
          label: 'Убрать из списка',
          destructive: true,
          // Стандартную папку Claude из списка не убираем никогда.
          enabled: !running && !profile.usesDefaultFolder,
        ),
      ],
    );
    if (!cardContext.mounted) return;
    switch (action) {
      case 'edit':
        await _edit(cardContext);
      case 'folder':
        await launcher.host.revealFolder(launcher.dataDirOf(profile));
      case 'quit':
        await _quit(cardContext);
      case 'remove':
        await _remove(cardContext);
    }
  }

  Future<void> _quit(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Завершить «${profile.name}»?',
      text: Platform.isMacOS
          ? 'Claude закроется так же, как по Cmd+Q. Если Claude Code сейчас '
                'выполняет задачу, она прервётся.'
          : 'Claude будет закрыт принудительно: на Windows он не выходит сам, '
                'а сворачивается в трей. Если Claude Code сейчас выполняет '
                'задачу, она прервётся.',
      confirmLabel: 'Завершить',
    );
    if (confirmed) await launcher.close(profile);
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
    if (!confirmed) return;
    await launcher.removeProfile(profile);
    if (settings.startupProfileId == profile.id) {
      await settings.setStartupProfile(null);
    }
  }
}
