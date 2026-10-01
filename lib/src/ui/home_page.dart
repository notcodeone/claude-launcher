import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app_settings.dart';
import '../claude/claude_updates.dart';
import '../integrations/claude_code_integration.dart';
import '../integrations/claude_code_sessions.dart';
import '../integrations/profile_usage.dart';
import '../launcher_controller.dart';
import '../location/countries.dart';
import '../location/kill_switch.dart';
import '../location/location_guard.dart';
import '../profile.dart';
import '../updates/app_updater.dart';
import 'anchored_menu.dart';
import 'code_sessions_view.dart';
import 'kill_switch_status.dart';
import 'profile_dialog.dart';
import 'profile_usage_menu.dart';
import 'settings_pages.dart';
import 'theme.dart';
import 'widgets.dart';

/// Страницы внутри окна: профили, настройки и их разделы. Шапка и подвал —
/// общие, меняется только тело под ними. Переход — «общая ось»: новая
/// страница въезжает справа и проявляется, прежняя уезжает влево и гаснет.
abstract final class AppPages {
  static const home = '/';
  static const settings = '/settings';

  static final navigator = GlobalKey<NavigatorState>();

  /// Адрес открытой страницы — для шапки и кнопки «Добавить».
  static final current = ValueNotifier<String>(home);
  static final observer = _PageObserver();

  static void open(String route) {
    if (current.value == route) return;
    navigator.currentState?.pushNamed(route);
  }

  /// Назад; на главной странице — ничего.
  static void back() => navigator.currentState?.maybePop();

  static Route<void> route(RouteSettings settings, WidgetBuilder builder) =>
      PageRouteBuilder<void>(
        settings: settings,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          final incoming = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final outgoing = CurvedAnimation(
            parent: secondary,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween(
              begin: const Offset(0.12, 0),
              end: Offset.zero,
            ).animate(incoming),
            child: FadeTransition(
              opacity: incoming,
              child: SlideTransition(
                position: Tween(
                  begin: Offset.zero,
                  end: const Offset(-0.12, 0),
                ).animate(outgoing),
                child: FadeTransition(
                  opacity: ReverseAnimation(outgoing),
                  child: child,
                ),
              ),
            ),
          );
        },
      );
}

class _PageObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) => _set(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previous) => _set(previous);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _set(newRoute);

  // Уведомляем после кадра: push/pop идут во время сборки навигатора.
  void _set(Route<dynamic>? route) {
    final name = route?.settings.name ?? AppPages.home;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => AppPages.current.value = name,
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.launcher,
    required this.settings,
    required this.claudeCode,
    required this.location,
    this.updater,
    this.killSwitch,
    this.claudeUpdates,
    this.version = '',
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;

  /// Обновления лаунчера — в подвале; null — без них (тесты).
  final AppUpdater? updater;

  /// Эксперимент Kill Switch — плашка о срабатывании; null — без него (тесты).
  final KillSwitch? killSwitch;

  /// Обновление Claude лаунчером, пока включён Kill Switch; null — без него.
  final ClaudeUpdates? claudeUpdates;

  /// Версия приложения — в подвале.
  final String version;

  /// Поля окна: по ним выровнены шапка, заголовок, карточки, кнопка и подвал.
  static const gutter = 24.0;
  static const _headerHeight = 52.0;
  static const _footerHeight = 40.0;

  /// Страница внутри окна по её адресу (см. [AppPages]).
  Widget _page(BuildContext context, String route, EdgeInsets padding) {
    final deps = SettingsContext(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
      location: location,
      updater: updater,
      killSwitch: killSwitch,
      version: version,
    );
    if (route == AppPages.settings) {
      return SettingsListPage(
        deps: deps,
        padding: padding,
        onOpen: (section) async {
          // Перед «Экспериментами» — предупреждение, пока с ним не согласились.
          final warn =
              section == SettingsSection.experiments &&
              !settings.experimentsAccepted;
          if (warn && !await confirmExperiments(context)) return;
          // Сначала переход, потом запись настроек — без задержки.
          AppPages.open(section.route);
          if (warn) await settings.acceptExperiments();
        },
      );
    }
    for (final section in SettingsSection.values) {
      if (route == section.route) {
        return SettingsSectionPage(
          section: section,
          deps: deps,
          padding: padding,
        );
      }
    }
    return _profiles(context, padding);
  }

  Widget _profiles(BuildContext context, EdgeInsets padding) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        launcher,
        claudeCode,
        location,
        settings,
        killSwitch,
        claudeUpdates,
      ]),
      builder: (context, _) => ListView(
        padding: padding,
        children: [
          Text('Профили', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            // По предложению на строку — без одинокого слова на второй.
            'Каждый профиль — отдельный вход в Claude.\n'
            'Одновременно запущен только один.',
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
              location: location,
              profile: profile,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // На macOS заголовок окна скрыт: сверху место под кнопки окна.
    final headerTop = Platform.isMacOS ? 46.0 : 16.0;
    final scrimHeight = headerTop + _headerHeight + 16;
    final bodyPadding = EdgeInsets.fromLTRB(
      gutter,
      headerTop + _headerHeight + 28,
      gutter,
      // Запас под подвал и кнопку «Добавить профиль», чтобы докрутить до конца.
      _footerHeight + 8 + 52 + 24,
    );

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

    // Esc — назад, ⌘, (Ctrl+, на Windows) — настройки.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): AppPages.back,
        SingleActivator(
          LogicalKeyboardKey.comma,
          meta: Platform.isMacOS,
          control: !Platform.isMacOS,
        ): () =>
            AppPages.open(AppPages.settings),
      },
      child: Focus(
        autofocus: true,
        child: _scaffold(context, bodyPadding, headerTop, scrimHeight, scrim),
      ),
    );
  }

  Widget _scaffold(
    BuildContext context,
    EdgeInsets bodyPadding,
    double headerTop,
    double scrimHeight,
    Widget Function({
      required bool top,
      required double height,
      required double solid,
    })
    scrim,
  ) {
    return Scaffold(
      body: Stack(
        children: [
          // Тело окна — страницы: профили, настройки и их разделы. Шапка,
          // подвал и затемнения над ними — общие и не двигаются.
          Positioned.fill(
            child: Navigator(
              key: AppPages.navigator,
              observers: [HeroController(), AppPages.observer],
              onGenerateRoute: (route) => AppPages.route(
                route,
                (context) => _page(context, route.name ?? '/', bodyPadding),
              ),
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
            child: ListenableBuilder(
              listenable: Listenable.merge([
                launcher,
                location,
                updater,
                settings,
                killSwitch,
                AppPages.current,
              ]),
              builder: (context, _) => _HeaderBar(
                launcher: launcher,
                settings: settings,
                claudeCode: claudeCode,
                location: location,
                updater: updater,
                killSwitch: killSwitch,
                page: AppPages.current.value,
              ),
            ),
          ),
          // Подвал в стиле sensomni.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _footerHeight,
            child: _Footer(version: version, updater: updater),
          ),
          // Кнопка по полю окна, над подвалом.
          // Только на странице профилей; в настройках уезжает вниз и гаснет.
          Positioned(
            right: gutter,
            bottom: _footerHeight + 8,
            child: ValueListenableBuilder(
              valueListenable: AppPages.current,
              builder: (context, page, _) => IgnorePointer(
                ignoring: page != AppPages.home,
                child: AnimatedSlide(
                  offset: Offset(0, page == AppPages.home ? 0 : 0.5),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: page == AppPages.home ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: AppFab(
                      icon: AppIcons.add,
                      label: 'Добавить',
                      onPressed: () => _addProfile(context),
                    ),
                  ),
                ),
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
      // Пока не закроют крестиком: иначе после перезапуска лаунчера подсказка
      // пропала бы непрочитанной.
      if (!settings.trayHintDismissed && status == null)
        InfoBanner(
          icon: AppIcons.info,
          onClose: settings.dismissTrayHint,
          text: Platform.isMacOS
              ? 'ClaudeLauncher живёт в строке меню — ищите вверху экрана его значок, '
                    'как в шапке этого окна. Это окно можно закрыть.'
              : 'ClaudeLauncher живёт в трее у часов (возможно, под стрелкой ▲). '
                    'Это окно можно закрыть.',
        ),
      // Ход проверки и переключения — в шапке (headerStatus); плашка — только
      // когда Claude не закрылся сам и нужен выбор пользователя.
      if (status != null && status.phase == SwitchPhase.waitingForUser)
        _SwitchBanner(launcher: launcher, status: status),
      if (location.blocksLaunch && !location.showsProgress)
        InfoBanner(
          icon: AppIcons.locationOff,
          error: true,
          text:
              'Claude недоступен в стране «${location.countryName}» — так её '
              'определяет IP-адрес. Пока это так, профили не запускаются.',
        ),
      if (killSwitch?.lastFired case final event?)
        InfoBanner(
          icon: AppIcons.shieldAlert,
          error: true,
          onClose: killSwitch!.dismiss,
          text: 'Kill Switch закрыл Claude. ${KillSwitch.describe(event)}',
        ),
      if (claudeUpdates case final updates? when updates.active)
        ?_claudeUpdateBanner(updates),
      if (launcher.lastError case final error?)
        InfoBanner(icon: AppIcons.error, error: true, text: error),
      for (final instance in launcher.unknownInstances)
        InfoBanner(
          icon: AppIcons.unknown,
          text:
              'Запущен Claude с папкой, которой нет в профилях:\n'
              '${launcher.host.dataDirOf(instance)}',
        ),
    ];
  }

  /// Пока включён Kill Switch, Claude обновляет лаунчер — плашка о новой
  /// версии и ходе обновления.
  Widget? _claudeUpdateBanner(ClaudeUpdates updates) {
    final release = updates.available;
    return switch (updates.phase) {
      ClaudeUpdatePhase.downloading => InfoBanner(
        icon: AppIcons.download,
        progress: true,
        text: switch (updates.progress) {
          final share? when share > 0 =>
            'Скачиваю Claude ${release?.version} — ${(share * 100).round()}%',
          _ => 'Скачиваю Claude ${release?.version}…',
        },
      ),
      ClaudeUpdatePhase.installing => InfoBanner(
        icon: AppIcons.download,
        progress: true,
        text: 'Обновляю Claude до ${release?.version}…',
      ),
      ClaudeUpdatePhase.failed => InfoBanner(
        icon: AppIcons.error,
        error: true,
        text: 'Не удалось обновить Claude: ${updates.error}',
        action: release == null
            ? null
            : AppButton(
                label: 'Повторить',
                kind: AppButtonKind.secondary,
                onPressed: updates.install,
              ),
      ),
      ClaudeUpdatePhase.idle when release != null => InfoBanner(
        icon: AppIcons.download,
        text:
            'Вышел Claude ${release.version}. Пока включён Kill Switch, его '
            'обновляет лаунчер — только через проверенную сеть. Claude '
            'закроется и откроется снова.',
        action: AppButton(label: 'Обновить', onPressed: updates.install),
      ),
      ClaudeUpdatePhase.idle => null,
    };
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
  const _Footer({required this.version, this.updater});

  final String version;
  final AppUpdater? updater;

  static final _notCodeUrl = Uri.parse('https://github.com/notcodeone');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall!.copyWith(color: p.muted, fontSize: 11.5);
    // Отступы кнопки «NotCode» — ровно в ширину пробела: «Designed by NotCode»
    // читается как обычная фраза, а подложка при наведении не липнет к буквам.
    final space = QuietTextButton.spaceWidth(context, style);
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
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    [
                      '© ${DateTime.now().year} ClaudeLauncher',
                      if (version.isNotEmpty) version,
                    ].join(' '),
                    style: style,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (updater case final updater?)
                  ListenableBuilder(
                    listenable: updater,
                    builder: (context, _) =>
                        _UpdateStatus(updater: updater, style: style),
                  ),
              ],
            ),
          ),
          Text('Designed by', style: style),
          QuietTextButton(
            label: 'NotCode',
            style: style,
            horizontalPadding: space,
            onTap: () => launchUrl(_notCodeUrl),
          ),
        ],
      ),
    );
  }
}

/// Новая версия в подвале: «· Обновить до 1.3.0» или ошибка обновления.
class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus({required this.updater, required this.style});

  final AppUpdater updater;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final version = updater.release?.version;
    final Widget child = switch (updater.phase) {
      UpdatePhase.idle => const SizedBox.shrink(),
      UpdatePhase.available => QuietTextButton(
        label: 'Обновить до $version',
        style: style.copyWith(
          color: context.palette.text,
          fontWeight: FontWeight.w600,
        ),
        horizontalPadding: QuietTextButton.spaceWidth(context, style),
        onTap: updater.install,
      ),
      // Ход скачивания и установки — в шапке.
      UpdatePhase.downloading ||
      UpdatePhase.installing => const SizedBox.shrink(),
      UpdatePhase.failed => Tooltip(
        message: updater.error ?? '',
        child: QuietTextButton(
          label: 'Не удалось обновить — ещё раз',
          style: style.copyWith(color: context.palette.danger),
          horizontalPadding: QuietTextButton.spaceWidth(context, style),
          onTap: updater.install,
        ),
      ),
    };
    if (updater.phase != UpdatePhase.available &&
        updater.phase != UpdatePhase.failed) {
      return child;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(' ·', style: style),
        child,
      ],
    );
  }
}

/// Что лаунчер сейчас делает — для шапки вместо названия.
class HeaderStatus {
  const HeaderStatus(
    this.id,
    this.text, {
    this.downloading = false,
    this.plain = false,
  });

  /// Без значка слева — заголовок страницы («Настройки»), а не занятие.
  final bool plain;

  /// Вид занятия: пока он тот же, надпись меняется на месте (проценты), без
  /// анимации смены.
  final String id;
  final String text;

  /// Скачивание обновления — значок скачивания вместо спиннера.
  final bool downloading;
}

/// Статус для шапки; null — ничего не происходит, в шапке название.
/// Обновление — важнее остального: после него лаунчер перезапустится.
HeaderStatus? headerStatus(
  LauncherController launcher,
  LocationGuard location, [
  AppUpdater? updater,
  KillSwitch? killSwitch,
]) {
  final version = updater?.release?.version;
  final progress = updater?.progress;
  switch (updater?.phase) {
    case UpdatePhase.downloading:
      return HeaderStatus(
        'update-download',
        'Скачиваю $version…'
            '${progress == null ? '' : ' ${(progress * 100).round()}%'}',
        downloading: true,
      );
    case UpdatePhase.installing:
      return HeaderStatus('update-install', 'Устанавливаю $version…');
    default:
  }
  final status = launcher.switchStatus;
  final target = status?.target == null ? null : '«${status!.target!.name}»';
  final closing = status?.closing.map((name) => '«$name»').join(', ');
  return switch (status?.phase) {
    SwitchPhase.closing => HeaderStatus('closing', 'Закрываю $closing…'),
    SwitchPhase.waitingForUser => const HeaderStatus(
      'waiting',
      'Жду, пока Claude закроется…',
    ),
    SwitchPhase.launching => HeaderStatus('launching', 'Открываю $target…'),
    null when killSwitch?.checking ?? false => const HeaderStatus(
      'kill-switch',
      'Проверяю сеть…',
    ),
    SwitchPhase.checking || null when location.showsProgress =>
      const HeaderStatus('country', 'Проверяю страну…'),
    SwitchPhase.checking => HeaderStatus(
      'checking',
      'Проверяю, можно ли открыть $target…',
    ),
    null when !launcher.located => const HeaderStatus(
      'loading',
      'Загружаю профили…',
    ),
    null => null,
  };
}

/// Название в шапке — знак и «ClaudeLauncher». Пока лаунчер что-то делает,
/// на его месте спиннер (при скачивании обновления — значок скачивания) и
/// [status]. Смена — как в Telegram при «Соединение…»: прежняя надпись уходит
/// вверх и гаснет, новая поднимается снизу.
class HeaderTitle extends StatelessWidget {
  const HeaderTitle({super.key, this.status});

  final HeaderStatus? status;

  static const _duration = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    );
    final status = this.status;
    final key = ValueKey(status?.id ?? '');
    final Widget child = Row(
      key: key,
      children: [
        if (status?.plain != true) ...[
          SizedBox.square(
            dimension: 20,
            child: switch (status) {
              // Знак — цветом названия: чёрный в светлой теме, белый в тёмной.
              null => Image.asset(
                'assets/icon/mark.png',
                width: 20,
                height: 20,
                color: p.text,
                colorBlendMode: BlendMode.srcIn,
                filterQuality: FilterQuality.medium,
              ),
              HeaderStatus(downloading: true) => DownloadingIcon(color: p.text),
              _ => Padding(
                padding: const EdgeInsets.all(2),
                child: CircularProgressIndicator(strokeWidth: 2, color: p.text),
              ),
            },
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            status?.text ?? 'ClaudeLauncher',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: status == null || status.plain
                ? style
                : style?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    return ClipRect(
      child: AnimatedSwitcher(
        duration: _duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerLeft,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) {
          // Новая надпись — снизу вверх; уходящая (анимация идёт назад) — вверх.
          final incoming = child.key == key;
          return SlideTransition(
            position: Tween(
              begin: Offset(0, incoming ? 0.8 : -0.8),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: child,
      ),
    );
  }
}

/// Значок скачивания: стрелка сверху опускается в лоток, замирает и падает
/// в него, затем появляется снова. Рисунок — как у значка download в Lucide.
class DownloadingIcon extends StatefulWidget {
  const DownloadingIcon({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  @override
  State<DownloadingIcon> createState() => _DownloadingIconState();
}

class _DownloadingIconState extends State<DownloadingIcon>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _DownloadPainter(_controller, widget.color),
    ),
  );
}

class _DownloadPainter extends CustomPainter {
  _DownloadPainter(this.animation, this.color) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Сетка Lucide — 24×24.
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Лоток: M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4.
    canvas.drawPath(
      Path()
        ..moveTo(21, 15)
        ..lineTo(21, 19)
        ..arcToPoint(const Offset(19, 21), radius: const Radius.circular(2))
        ..lineTo(5, 21)
        ..arcToPoint(const Offset(3, 19), radius: const Radius.circular(2))
        ..lineTo(3, 15),
      paint,
    );

    // Стрелка: M12 15V3, m7 10 5 5 5-5. Опускается сверху (0–50 %), замирает
    // (50–70 %) и падает в лоток, растворяясь (70–100 %).
    final t = animation.value;
    final double dy;
    var opacity = 1.0;
    if (t < 0.5) {
      dy = -14 * (1 - Curves.easeOutCubic.transform(t / 0.5));
    } else if (t < 0.7) {
      dy = 0;
    } else {
      final fall = Curves.easeInCubic.transform((t - 0.7) / 0.3);
      dy = 8 * fall;
      opacity = 1 - fall;
    }
    canvas.save();
    // Стрелка видна только над дном лотка.
    canvas.clipRect(const Rect.fromLTRB(0, 0, 24, 20));
    canvas.translate(0, dy);
    final arrow = Paint()
      ..color = color.withValues(alpha: color.a * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(12, 15)
        ..lineTo(12, 3)
        ..moveTo(7, 10)
        ..lineTo(12, 15)
        ..lineTo(17, 10),
      arrow,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DownloadPainter old) => old.color != color;
}

/// Плавающая шапка, как в sensomni: название слева, страна, тема и настройки справа.
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.launcher,
    required this.settings,
    required this.claudeCode,
    required this.location,
    this.updater,
    this.killSwitch,
    this.page = AppPages.home,
    this.interactive = true,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;
  final AppUpdater? updater;

  /// Кнопка Kill Switch — только когда он включён (или ещё держит затвор для
  /// открытого Claude).
  final KillSwitch? killSwitch;

  /// Открытая страница: на профилях — название и кнопки, в настройках —
  /// «← Настройки».
  final String page;

  /// Копия шапки поверх затемнения под меню не реагирует на клики.
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final home = page == AppPages.home;
    final busy = headerStatus(launcher, location, updater, killSwitch);
    // В настройках — «Настройки»; из статусов там виден только ход обновления.
    final status = home || (busy?.id.startsWith('update') ?? false)
        ? busy
        : const HeaderStatus('settings', 'Настройки', plain: true);
    const duration = Duration(milliseconds: 280);
    return Builder(
      builder: (cardContext) => SoftCard(
        radius: 16,
        padding: EdgeInsets.zero,
        child: AnimatedPadding(
          duration: duration,
          curve: Curves.easeOutCubic,
          // Со стрелкой «назад» левый край — как правый, у кнопок.
          padding: EdgeInsets.fromLTRB(home ? 16 : 8, 8, 8, 8),
          child: Row(
            children: [
              AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                child: AnimatedSwitcher(
                  duration: duration,
                  child: home
                      ? const SizedBox(key: ValueKey('none'), height: 36)
                      : Padding(
                          key: const ValueKey('back'),
                          padding: const EdgeInsets.only(right: 4),
                          child: CircleIconButton(
                            icon: AppIcons.back,
                            tooltip: interactive ? 'Назад' : null,
                            onPressed: interactive ? AppPages.back : null,
                          ),
                        ),
                ),
              ),
              // Кнопки — не в области перетаскивания: та ждёт двойного клика
              // (развернуть окно), и одиночные клики срабатывали бы с задержкой.
              Expanded(child: _dragArea(HeaderTitle(status: status))),
              AnimatedSwitcher(
                duration: duration,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: !home
                    ? const SizedBox(key: ValueKey('none'), height: 36)
                    : Row(
                        key: const ValueKey('buttons'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSize(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            child: switch (killSwitch) {
                              final killSwitch?
                                  when killSwitch.enabled ||
                                      killSwitch.passthrough =>
                                CircleIconButton(
                                  icon: killSwitch.lastFired != null
                                      ? AppIcons.shieldAlert
                                      : AppIcons.shield,
                                  badge: killSwitchState(
                                    context,
                                    killSwitch,
                                  )?.color,
                                  tooltip: interactive ? 'Kill Switch' : null,
                                  onPressed: () {
                                    if (interactive) {
                                      _openKillSwitchMenu(
                                        cardContext,
                                        killSwitch,
                                      );
                                    }
                                  },
                                ),
                              _ => const SizedBox.shrink(),
                            },
                          ),
                          CircleIconButton(
                            icon: location.enabled
                                ? AppIcons.location
                                : AppIcons.locationOff,
                            badge: _locationBadge(context.palette),
                            loading: location.showsProgress,
                            tooltip: interactive ? 'Страна' : null,
                            onPressed: () {
                              if (interactive) _openLocationMenu(cardContext);
                            },
                          ),
                          CircleIconButton(
                            icon: AppIcons.settings,
                            tooltip: interactive ? 'Настройки' : null,
                            onPressed: () {
                              if (interactive) {
                                AppPages.open(AppPages.settings);
                              }
                            },
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Точка на кнопке страны: зелёная — Claude доступен, красная — нет,
  /// жёлтая — узнать не удалось.
  Color? _locationBadge(Palette p) {
    if (!location.enabled || location.checking) return null;
    return switch (location.state) {
      LocationState.supported => p.success,
      LocationState.unsupported => p.danger,
      LocationState.unknown when location.checkedAt != null => p.warning,
      LocationState.unknown => null,
    };
  }

  _HeaderBar get _highlight => _HeaderBar(
    launcher: launcher,
    settings: settings,
    claudeCode: claudeCode,
    location: location,
    updater: updater,
    killSwitch: killSwitch,
    page: page,
    interactive: false,
  );

  Future<void> _openKillSwitchMenu(
    BuildContext cardContext,
    KillSwitch killSwitch,
  ) async {
    final action = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: _highlight,
      caption: ListenableBuilder(
        listenable: Listenable.merge([killSwitch, location]),
        builder: (context, _) =>
            _KillSwitchCaption(killSwitch: killSwitch, location: location),
      ),
      entries: [
        if (killSwitch.armed)
          const MenuEntry(
            value: 'check',
            icon: AppIcons.sync,
            label: 'Проверить сеть',
          ),
        const MenuEntry(
          value: 'settings',
          icon: AppIcons.settings,
          label: 'Настройки Kill Switch',
        ),
      ],
    );
    switch (action) {
      case 'check':
        await killSwitch.checkNow();
      case 'settings':
        AppPages.open(SettingsSection.experiments.route);
    }
  }

  Future<void> _openLocationMenu(BuildContext cardContext) async {
    final recheck = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: _highlight,
      caption: _LocationCaption(location: location),
      entries: [
        location.enabled
            ? const MenuEntry(
                value: true,
                icon: AppIcons.sync,
                label: 'Проверить снова',
              )
            : const MenuEntry(
                value: true,
                icon: AppIcons.location,
                label: 'Включить проверку',
              ),
      ],
    );
    if (recheck != true) return;
    if (!location.enabled) await settings.setLocationCheck(true);
    await location.check(force: true);
  }

  Widget _dragArea(Widget child) => Platform.isMacOS && interactive
      ? DragToMoveArea(child: SizedBox(height: 36, child: child))
      : SizedBox(height: 36, child: child);
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
      // Проверку страны показывает своя плашка (см. HomePage._banners).
      SwitchPhase.checking => 'Проверяю, можно ли открыть $target…',
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
      // Отменить можно только ожидание закрытия.
      action: status.phase == SwitchPhase.closing ? cancel : null,
    );
  }
}

/// Что Kill Switch делает сейчас — над пунктами меню его кнопки.
class _KillSwitchCaption extends StatelessWidget {
  const _KillSwitchCaption({required this.killSwitch, required this.location});

  final KillSwitch killSwitch;
  final LocationGuard location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final state = killSwitchState(context, killSwitch);
    final event = killSwitch.lastFired;
    final country = switch (killSwitch.baseline) {
      final code? when killSwitch.open => countryNames[code] ?? code,
      _ => null,
    };
    final details = [
      if (country != null) 'Трафик Claude выпускается в стране «$country»',
      if (location.checkedAt case final at? when killSwitch.armed)
        'Проверено в ${_LocationCaption._clock(at)}',
    ].join(' / ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              event != null ? AppIcons.shieldAlert : AppIcons.shield,
              size: 22,
              color: state?.color ?? p.muted,
            ),
            const SizedBox(width: 8),
            Text(
              'Kill Switch',
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        if (state != null) ...[
          const SizedBox(height: 8),
          StatusDot(label: state.label, color: state.color),
        ],
        if (event != null) ...[
          const SizedBox(height: 8),
          Text(KillSwitch.describe(event), style: theme.textTheme.bodySmall),
        ] else if (details.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(details, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// Что известно о стране — над пунктами меню кнопки страны.
class _LocationCaption extends StatelessWidget {
  const _LocationCaption({required this.location});

  final LocationGuard location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final checkedAt = location.checkedAt;
    final checked = [
      if (checkedAt != null) 'Проверено в ${_clock(checkedAt)}',
      ?location.source,
    ].join(' / ');

    // Страна известна: флаг и название крупно, под ними — доступен ли Claude.
    if (location case LocationGuard(
      enabled: true,
      checking: false,
      :final country?,
      :final countryName?,
      state: LocationState.supported || LocationState.unsupported,
    )) {
      final supported = location.state == LocationState.supported;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // Флаги в эмодзи Windows нет — там вместо него были бы две буквы.
            Platform.isMacOS
                ? '${countryFlag(country)} $countryName'
                : countryName,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          StatusDot(
            label: supported ? 'Claude доступен' : 'Claude недоступен',
            color: supported ? p.success : p.danger,
          ),
          const SizedBox(height: 8),
          Text(checked, style: theme.textTheme.bodySmall),
        ],
      );
    }

    final (title, text) = switch (location) {
      LocationGuard(enabled: false) => (
        'Проверка страны выключена',
        'Профили запускаются без неё.',
      ),
      LocationGuard(checking: true) => (
        'Проверяю страну…',
        'По IP-адресу, у публичных сервисов.',
      ),
      LocationGuard(checkedAt: null) => (
        'Страна ещё не проверена',
        'Лаунчер проверит её перед запуском профиля.',
      ),
      _ => (
        'Страну определить не удалось',
        'Сервисы не ответили — возможно, нет сети. Запуск вручную '
            'не запрещён.',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(text, style: theme.textTheme.bodySmall),
        if (location.enabled && !location.checking && checkedAt != null) ...[
          const SizedBox(height: 4),
          Text(checked, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  static String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
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
    required this.location,
    required this.profile,
    this.interactive = true,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;
  final Profile profile;

  /// Копия карточки поверх затемнения под меню не реагирует на клики.
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
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
    final sessions = claudeCode.sessions.of(profile.id);
    final collapsed = profile.sessionsCollapsed;
    final canShow = !switching && launcher.claudePath != null;
    // Открытый профиль можно показать всегда, запустить — только где Claude доступен.
    final blocked = !running && location.blocksLaunch;
    final opening = launcher.switchStatus?.target?.id == profile.id;
    void show() {
      if (interactive) launcher.switchTo(profile);
    }

    final header = Row(
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
                    const StatusDot(label: 'Запущен'),
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
      ],
    );

    return Builder(
      builder: (cardContext) => SoftCard(
        padding: EdgeInsets.zero,
        // Сессии сворачиваются нажатием на карточку.
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: sessions.isEmpty
                ? null
                : () {
                    if (interactive) _toggleSessions();
                  },
            hoverColor: palette.text.withValues(alpha: HoverSurface.hoverAlpha),
            highlightColor: palette.text.withValues(
              alpha: HoverSurface.pressedAlpha,
            ),
            splashColor: palette.text.withValues(alpha: 0.04),
            child: Padding(
              // Справа 8: у кнопок-иконок свои 8 px вокруг значка — визуально те же 16.
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: sessions.isEmpty || !interactive
                            ? header
                            : Tooltip(
                                message: collapsed
                                    ? 'Показать сессии (${sessions.length})'
                                    : 'Скрыть сессии',
                                waitDuration: const Duration(milliseconds: 700),
                                child: header,
                              ),
                      ),
                      const SizedBox(width: 12),
                      // Лимиты — эксперимент, включается в настройках.
                      if (running && settings.usageLimits)
                        ProfileUsageButton(
                          menuAnchorContext: cardContext,
                          menuHighlight: _menuHighlight,
                          enabled: !switching,
                          interactive: interactive,
                          activity: launcher,
                          isRunning: () => launcher.isRunning(profile),
                          load: () async {
                            final instance = launcher.instances
                                .where(
                                  (i) =>
                                      launcher.profileOf(i)?.id == profile.id,
                                )
                                .firstOrNull;
                            if (instance == null) return null;
                            return const ProfileUsageReader().read(
                              launcher.host.readableDataDirs(instance),
                            );
                          },
                        ),
                      CircleIconButton(
                        icon: running ? AppIcons.show : AppIcons.launch,
                        loading: opening,
                        tooltip: !interactive
                            ? null
                            : running
                            ? 'Показать окно Claude'
                            : blocked
                            ? 'Claude недоступен в этой стране'
                            : 'Открыть профиль',
                        // Свёрнуто — последнее состояние видно точкой на глазе.
                        badge: collapsed && sessions.isNotEmpty
                            ? sessionColor(palette, sessions.first.state)
                            : null,
                        // У копии карточки кнопка выглядит активной, но клики до неё не доходят.
                        onPressed: canShow && !blocked ? show : null,
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
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: collapsed || sessions.isEmpty
                        ? const SizedBox(width: double.infinity)
                        : CodeSessionsSection(
                            sessions: sessions,
                            onOpen: canShow ? _openSession : null,
                            now: DateTime.now(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openSession(CodeSession session) {
    if (!interactive) return;
    switch (session.link) {
      case final link?:
        launcher.openLink(profile, link);
      case null:
        launcher.switchTo(profile);
    }
  }

  Future<void> _toggleSessions() => launcher.updateProfile(
    profile.copyWith(sessionsCollapsed: !profile.sessionsCollapsed),
  );

  Widget get _menuHighlight => ListenableBuilder(
    listenable: Listenable.merge([launcher, claudeCode, location]),
    builder: (_, _) => _ProfileCard(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
      location: location,
      profile: profile,
      interactive: false,
    ),
  );

  Future<void> _openMenu(BuildContext cardContext) async {
    final running = launcher.isRunning(profile);
    final action = await showAnchoredMenu(
      anchorContext: cardContext,
      highlight: _menuHighlight,
      entries: [
        const MenuEntry(value: 'edit', icon: AppIcons.edit, label: 'Изменить'),
        MenuEntry(
          value: 'folder',
          icon: AppIcons.folder,
          label: Platform.isMacOS ? 'Открыть в Finder' : 'Открыть в Проводнике',
        ),
        // Тег «По умолчанию»: этот профиль лаунчер открывает при своём запуске.
        if (settings.startupProfileId == profile.id)
          const MenuEntry(
            value: 'startup',
            icon: AppIcons.startupOff,
            label: 'Не открывать при запуске',
          )
        else
          const MenuEntry(
            value: 'startup',
            icon: AppIcons.startup,
            label: 'Открывать при запуске',
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
      case 'startup':
        await settings.setStartupProfile(
          settings.startupProfileId == profile.id ? null : profile.id,
        );
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
