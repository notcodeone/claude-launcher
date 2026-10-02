import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_settings.dart';
import '../claude/claude_updates.dart';
import '../integrations/claude_code_integration.dart';
import '../launcher_controller.dart';
import '../location/cowork_firewall.dart';
import '../location/kill_switch.dart';
import '../location/location_guard.dart';
import '../updates/app_updater.dart';
import 'settings_dialog.dart';
import 'theme.dart';
import 'kill_switch_status.dart';
import 'widgets.dart';

/// Разделы настроек — страницы внутри окна (см. HomePage): список разделов,
/// за ним — сам раздел. Значок и название раздела перелетают из строки списка
/// в заголовок страницы (Hero), карточки раздела поднимаются по очереди.
enum SettingsSection {
  general('Основные', AppIcons.general),
  claudeCode('Claude Code', AppIcons.claudeCode),
  updates('Обновления', AppIcons.updates),
  experiments('Эксперименты', AppIcons.experiments);

  const SettingsSection(this.title, this.icon);

  final String title;
  final IconData icon;

  String get route => '/settings/$name';
}

/// Всё, что нужно страницам настроек.
class SettingsContext {
  const SettingsContext({
    required this.launcher,
    required this.settings,
    required this.claudeCode,
    required this.location,
    required this.version,
    this.updater,
    this.killSwitch,
    this.claudeUpdates,
    this.coworkFirewall,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;
  final LocationGuard location;
  final AppUpdater? updater;
  final KillSwitch? killSwitch;
  final ClaudeUpdates? claudeUpdates;

  /// Windows: правило брандмауэра для службы Cowork; null — не Windows.
  final CoworkFirewall? coworkFirewall;
  final String version;

  Listenable get changes => Listenable.merge([
    settings,
    claudeCode,
    location,
    updater,
    killSwitch,
    claudeUpdates,
    coworkFirewall,
  ]);
}

/// Предупреждение перед разделом «Эксперименты». Пропустить нельзя: ни кликом
/// мимо, ни Esc — только ответить. true — пользователь согласился.
Future<bool> confirmExperiments(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const PopScope(canPop: false, child: _ExperimentsWarning()),
    ) ??
    false;

class _ExperimentsWarning extends StatelessWidget {
  const _ExperimentsWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return AppDialogFrame(
      children: [
        Row(
          children: [
            Icon(AppIcons.experiments, size: 24, color: p.text),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Экспериментальные функции',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Здесь — функции, которые ещё проверяются. Они могут работать '
          'неточно или перестать работать после обновления Claude: часть из '
          'них опирается на его внутренние данные, которые Anthropic может '
          'изменить в любой момент. Некоторые могут быть небезопасны.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Включая их, вы пользуетесь ими на свой страх и риск. Продолжить?',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'ClaudeLauncher не собирает и не отправляет ваши личные данные.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        AppButton(
          label: 'Понимаю, продолжить',
          kind: AppButtonKind.danger,
          expand: true,
          large: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: 8),
        AppButton(
          label: 'Назад',
          kind: AppButtonKind.secondary,
          expand: true,
          large: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

/// Список разделов.
class SettingsListPage extends StatelessWidget {
  const SettingsListPage({
    super.key,
    required this.deps,
    required this.padding,
    required this.onOpen,
  });

  final SettingsContext deps;
  final EdgeInsets padding;
  final void Function(SettingsSection section) onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: deps.changes,
    builder: (context, _) => ListView(
      padding: padding,
      children: [
        AppearIn(
          index: 0,
          child: SoftCard(
            padding: EdgeInsets.zero,
            // Подсветка строк — по скруглённым углам карточки.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                children: [
                  for (final (index, section)
                      in SettingsSection.values.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    _SectionRow(
                      section: section,
                      summary: _summary(section),
                      onTap: () => onOpen(section),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// Подпись раздела в списке. У «Обновлений» — состояние версии.
  String _summary(SettingsSection section) {
    final c = deps;
    return switch (section) {
      SettingsSection.general => 'Главные настройки приложения',
      SettingsSection.claudeCode => 'Настройки интеграции с Claude',
      SettingsSection.updates
          when c.claudeUpdates?.available != null &&
              (c.claudeUpdates?.active ?? false) =>
        'Вышел Claude ${c.claudeUpdates!.available!.version}',
      SettingsSection.updates => switch (c.updater) {
        AppUpdater(phase: UpdatePhase.available, :final release?) =>
          'Вышла версия ${release.version} — обновление в один клик',
        AppUpdater(upToDateAt: _?) => 'У вас последняя версия — ${c.version}',
        _ when !c.settings.checkUpdates =>
          'Версия ${c.version}, автоматическая проверка выключена',
        _ => 'Версия ${c.version} и проверка новых',
      },
      SettingsSection.experiments => 'Опасная зона!',
    };
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.summary,
    required this.onTap,
  });

  final SettingsSection section;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return HoverSurface(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeading(section: section),
                  Padding(
                    // Под названием, по краю текста, а не значка.
                    padding: const EdgeInsets.only(left: 30, top: 2),
                    child: Text(
                      summary,
                      // «Опасная зона!» — красным.
                      style: section == SettingsSection.experiments
                          ? Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: p.danger)
                          : Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.chevron, size: 18, color: p.muted),
          ],
        ),
      ),
    );
  }
}

/// Значок и название раздела. [t] — 0 в строке списка, 1 в заголовке
/// страницы; в полёте Hero — между ними.
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.section, this.t = 0});

  final SettingsSection section;
  final double t;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hero(
      tag: 'settings-${section.name}',
      flightShuttleBuilder: (_, animation, direction, _, _) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeInOutCubic,
        );
        return AnimatedBuilder(
          animation: curved,
          // В полёте рамка Hero меняется не в такт шрифту — вписываем.
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: _HeadingContent(
                section: section,
                t: curved.value,
                color: p.text,
              ),
            ),
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        child: _HeadingContent(section: section, t: t, color: p.text),
      ),
    );
  }
}

class _HeadingContent extends StatelessWidget {
  const _HeadingContent({
    required this.section,
    required this.t,
    required this.color,
  });

  final SettingsSection section;
  final double t;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(section.icon, size: 20 + 4 * t, color: color),
      SizedBox(width: 10 + 2 * t),
      Flexible(
        child: Text(
          section.title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 15 + 7 * t,
            fontWeight: FontWeight.lerp(FontWeight.w600, FontWeight.w700, t),
            letterSpacing: -0.3 * t,
            color: color,
          ),
        ),
      ),
    ],
  );
}

/// Страница раздела: заголовок и карточки с настройками.
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({
    super.key,
    required this.section,
    required this.deps,
    required this.padding,
  });

  final SettingsSection section;
  final SettingsContext deps;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: deps.changes,
    builder: (context, _) {
      final cards = switch (section) {
        SettingsSection.general => _general(context),
        SettingsSection.claudeCode => _claudeCode(context),
        SettingsSection.updates => _updates(context),
        SettingsSection.experiments => _experiments(context),
      };
      return ListView(
        padding: padding,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SectionHeading(section: section, t: 1),
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

  // ----------------------------------------------------------- основные

  List<Widget> _general(BuildContext context) {
    final c = deps;
    final settings = c.settings;
    return [
      _Card(
        rows: [
          SettingSwitchRow(
            title: 'Проверять страну перед запуском',
            description:
                'Claude доступен не во всех странах. Перед запуском профиля '
                'лаунчер узнаёт страну по IP-адресу у публичных сервисов '
                '(country.is, Cloudflare, ipwho.is, ipapi.co) и не запускает '
                'профиль, если Claude там недоступен.',
            value: settings.locationCheck,
            onChanged: (enabled) async {
              await settings.setLocationCheck(enabled);
              if (enabled) await c.location.check(force: true);
            },
            link: _countryStatus(context),
          ),
          if (Platform.isMacOS)
            SettingSwitchRow(
              title: 'Значок в Dock',
              description:
                  'Лаунчер виден в Dock, как обычное приложение: нажатие '
                  'открывает его окно. Без значка он живёт только в строке '
                  'меню.',
              value: settings.dockIcon,
              onChanged: settings.setDockIcon,
            ),
        ],
      ),
      _Card(
        rows: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Тема окна', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              SegmentedChoice<ThemeMode>(
                value: settings.themeMode,
                onChanged: settings.setThemeMode,
                options: const [
                  (ThemeMode.system, AppIcons.themeSystem, 'Как в системе'),
                  (ThemeMode.light, AppIcons.themeLight, 'Светлая'),
                  (ThemeMode.dark, AppIcons.themeDark, 'Тёмная'),
                ],
              ),
            ],
          ),
        ],
      ),
    ];
  }

  Widget? _countryStatus(BuildContext context) {
    final location = deps.location;
    if (!location.enabled) return null;
    if (location.checking) return const StatusDot(label: 'Проверяю страну…');
    final p = context.palette;
    final name = location.countryName;
    return switch (location.state) {
      LocationState.supported => StatusDot(
        label: 'Сейчас: ${_country(location)} — Claude доступен',
      ),
      LocationState.unsupported => StatusDot(
        label: 'Сейчас: ${_country(location)} — Claude недоступен',
        color: p.danger,
      ),
      LocationState.unknown when location.checkedAt != null => StatusDot(
        label: name == null
            ? 'Страну узнать не удалось'
            : 'Сейчас: $name — не удалось проверить',
        color: p.warning,
      ),
      LocationState.unknown => null,
    };
  }

  static String _country(LocationGuard location) {
    final name = location.countryName ?? '';
    final code = location.country;
    // Флагов-эмодзи в Windows нет — там были бы две буквы.
    return Platform.isMacOS && code != null
        ? '${countryFlag(code)} $name'
        : name;
  }

  // -------------------------------------------------------- Claude Code

  List<Widget> _claudeCode(BuildContext context) {
    final c = deps;
    return [
      _Card(
        rows: [
          ClaudeCodeEventsSwitch(
            value: c.settings.claudeCodeEvents,
            claudeCode: c.claudeCode,
            onChanged: c.claudeCode.setEnabled,
          ),
          if (c.settings.claudeCodeEvents)
            LauncherNotificationsSwitch(
              value: c.settings.launcherNotifications,
              claudeCode: c.claudeCode,
              onChanged: c.claudeCode.setNotificationsEnabled,
            ),
        ],
      ),
      _Card(
        rows: [
          ClaudeIconSwitch(
            launcher: c.launcher,
            value: c.settings.hideClaudeIcon,
            onChanged: (hide) async {
              await c.settings.setHideClaudeIcon(hide);
              await c.launcher.setClaudeIconHidden(hide);
            },
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Хуки лаунчера — в ~/.claude/settings.json, рядом резервная копия. '
          'Выключите события — лаунчер уберёт хуки и вернёт Claude '
          'уведомления.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }

  // ---------------------------------------------------------- обновления

  List<Widget> _updates(BuildContext context) {
    final c = deps;
    final updater = c.updater;
    return [
      _VersionCard(version: c.version, updater: updater),
      if (c.claudeUpdates case final claude?)
        _ClaudeVersionCard(updates: claude),
      _Card(
        rows: [
          SettingSwitchRow(
            title: 'Проверять автоматически',
            description:
                'Через 15 секунд после запуска, при открытии окна и раз в 6 '
                'часов лаунчер спрашивает GitHub, вышла ли новая версия. '
                'Обновление — одной кнопкой: лаунчер скачает и установит его '
                'сам, без предупреждений системы.',
            value: c.settings.checkUpdates,
            onChanged: c.settings.setCheckUpdates,
          ),
        ],
      ),
    ];
  }

  // -------------------------------------------------------- эксперименты

  List<Widget> _experiments(BuildContext context) {
    final settings = deps.settings;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Функции, которые ещё проверяются и могут работать неточно. У каждой '
          '— свой переключатель.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      _Card(
        rows: [
          SettingSwitchRow(
            title: 'Лимиты профиля',
            description:
                'Кнопка с графиками на открытом профиле: сколько использовано '
                'за 5 часов и за неделю и когда лимит сбросится. Данные — те, '
                'что сохраняет сам Claude; отстают от сервера на 10–20 минут.',
            value: settings.usageLimits,
            onChanged: settings.setUsageLimits,
          ),
        ],
      ),
      _Card(
        rows: [
          SettingSwitchRow(
            title: 'Kill Switch',
            description:
                'Защищает аккаунт, когда Claude открыт через VPN. Весь трафик '
                'Claude — приложения, Claude Code и машины Cowork — идёт через '
                'лаунчер. Сменилась сеть — соединения рвутся мгновенно, а новые '
                'ждут, пока лаунчер проверит страну. Та же страна — работа '
                'продолжается, другая — Claude закрывается.',
            value: settings.killSwitch,
            onChanged: (enabled) async {
              await settings.setKillSwitch(enabled);
              // Без Kill Switch правило оставило бы Cowork без сети.
              final firewall = deps.coworkFirewall;
              if (!enabled && (firewall?.active ?? false)) {
                await firewall!.disable();
              }
            },
            link: _killSwitchStatus(context),
          ),
          if (settings.killSwitch)
            if (deps.coworkFirewall case final firewall?)
              SettingSwitchRow(
                title: 'Cowork — только через Kill Switch',
                description:
                    'Машина Cowork работает в службе Windows, которую Kill '
                    'Switch не закрывает. Правило брандмауэра не выпустит её в '
                    'интернет мимо затвора. Windows спросит разрешение '
                    'администратора — и чтобы поставить правило, и чтобы снять.',
                value: firewall.active ?? false,
                // Пока ждём Windows — второе нажатие ничего не делает.
                onChanged: (enabled) {
                  if (firewall.busy) return;
                  enabled ? firewall.enable() : firewall.disable();
                },
                link: _firewallStatus(context, firewall),
              ),
          if (settings.killSwitch)
            SettingSwitchRow(
              title: 'Закрывать Claude при любой смене сети',
              description:
                  'Вдобавок к затвору — закрывать Claude сразу, как сменилась '
                  'сеть, не дожидаясь проверки страны. Закроется и при '
                  'безобидной смене Wi-Fi.',
              value: settings.killSwitchStrict,
              onChanged: settings.setKillSwitchStrict,
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Защищён Claude, открытый после включения Kill Switch — лаунчером или '
          'из Dock. Пока функция включена, Claude обновляет лаунчер — только '
          'через проверенную сеть. Не защищены claude.ai в браузере и '
          'Claude Code, установленный отдельно, — их прикрывает Kill Switch '
          'самого VPN-клиента. Лучше включить оба.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }
}

extension on SettingsSectionPage {
  /// Что с правилом брандмауэра для Cowork.
  Widget? _firewallStatus(BuildContext context, CoworkFirewall firewall) {
    final p = context.palette;
    if (firewall.busy) {
      return StatusDot(label: 'Жду разрешения Windows…', color: p.warning);
    }
    if (firewall.error case final error?) {
      return StatusDot(label: 'Не вышло: $error', color: p.danger);
    }
    return switch (firewall.active) {
      true => const StatusDot(label: 'Правило брандмауэра стоит'),
      false => null,
      null => StatusDot(label: 'Проверяю правило…', color: p.muted),
    };
  }

  /// Под переключателем Kill Switch — что он делает прямо сейчас.
  Widget? _killSwitchStatus(BuildContext context) {
    final killSwitch = deps.killSwitch;
    return killSwitch == null ? null : killSwitchStatusDot(context, killSwitch);
  }
}

/// Версия и обновление: «ClaudeLauncher 1.4.0 · Последняя версия».
/// Размер значков приложений в «Обновлениях»: лаунчера и Claude.
const appIconSize = 48.0;

/// Claude — рядом с версией лаунчера. Пока включён Kill Switch, его
/// обновляет лаунчер ([ClaudeUpdates]); иначе Claude обновляется сам.
class _ClaudeVersionCard extends StatelessWidget {
  const _ClaudeVersionCard({required this.updates});

  final ClaudeUpdates updates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final release = updates.available;
    final installed = updates.installed;
    final canAct = updates.active && !updates.busy;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Значок самого Claude — из установленного приложения.
              switch (updates.iconPath) {
                final icon? => Image.file(
                  File(icon),
                  width: appIconSize,
                  height: appIconSize,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _placeholder(p),
                ),
                null => _placeholder(p),
              },
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      installed == null ? 'Claude' : 'Claude $installed',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    _status(context),
                    // Не встало — путь к журналу; по нажатию он откроется.
                    if (updates.phase == ClaudeUpdatePhase.failed)
                      if (updates.installLog case final log?) ...[
                        const SizedBox(height: 6),
                        InlineLink(
                          label: log,
                          onTap: () => launchUrl(Uri.file(log)),
                        ),
                      ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            updates.active
                ? 'Пока включён Kill Switch, Claude обновляет лаунчер: '
                      'встроенное обновление Claude ходит мимо прокси. Лаунчер '
                      'качает только через проверенную сеть, проверяет архив и '
                      'подпись, закрывает Claude, ставит новую версию и '
                      'открывает Claude снова.'
                : 'Claude обновляется сам. Лаунчер берёт это на себя, только '
                      'пока включён Kill Switch.',
            style: theme.textTheme.bodySmall,
          ),
          if (updates.active) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (release != null &&
                    (updates.phase == ClaudeUpdatePhase.idle ||
                        updates.phase == ClaudeUpdatePhase.failed))
                  AppButton(
                    label: 'Обновить до ${release.version}',
                    onPressed: canAct ? updates.install : null,
                  )
                else
                  _FieldButton(
                    label: 'Проверить сейчас',
                    onPressed: canAct && !updates.checking
                        ? updates.check
                        : null,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Пока значок Claude не найден — серая плитка того же размера, что
  /// рисунок значка приложения.
  static Widget _placeholder(Palette p) => SizedBox.square(
    dimension: appIconSize,
    child: Center(
      child: Container(
        width: appIconSize * 0.8,
        height: appIconSize * 0.8,
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(appIconSize * 0.18),
        ),
        child: Icon(AppIcons.download, size: 20, color: p.text),
      ),
    ),
  );

  Widget _status(BuildContext context) {
    final p = context.palette;
    final version = updates.available?.version;
    final checked = updates.checkedAt;
    if (!updates.active) {
      return StatusDot(label: 'Обновляется сам', color: p.muted);
    }
    return switch (updates.phase) {
      ClaudeUpdatePhase.downloading => StatusDot(
        label: switch (updates.progress) {
          final share? when share > 0 =>
            'Скачиваю $version — ${(share * 100).round()}%',
          _ => 'Скачиваю $version…',
        },
        color: p.info,
      ),
      ClaudeUpdatePhase.installing => StatusDot(
        label: 'Устанавливаю $version…',
        color: p.info,
      ),
      ClaudeUpdatePhase.failed => StatusDot(
        label: 'Не удалось обновить: ${updates.error}',
        color: p.danger,
      ),
      _ when version != null => StatusDot(
        label: 'Доступна версия $version',
        color: p.info,
      ),
      _ when updates.checking => StatusDot(
        label: 'Проверяю обновления…',
        color: p.muted,
      ),
      _ when checked != null => StatusDot(
        label: 'Последняя версия · проверено в ${_VersionCard._clock(checked)}',
      ),
      _ => StatusDot(
        label: 'Проверю, когда сеть будет проверена',
        color: p.muted,
      ),
    };
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.version, required this.updater});

  final String version;
  final AppUpdater? updater;

  static final _releases = Uri.parse(
    'https://github.com/${AppUpdater.repo}/releases',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updater = this.updater;
    final status = _status(context);
    final busy =
        updater != null &&
        (updater.checking ||
            updater.phase == UpdatePhase.downloading ||
            updater.phase == UpdatePhase.installing);
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Значок приложения — тот же, что в Dock и Finder. Сетка как у
              // значков macOS: рисунок занимает ~80% холста, поэтому рядом
              // со значком Claude они одного размера.
              Image.asset(
                'assets/icon/app_icon.png',
                width: appIconSize,
                height: appIconSize,
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ClaudeLauncher $version',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    ?status,
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (updater?.phase == UpdatePhase.available ||
                  updater?.phase == UpdatePhase.failed)
                AppButton(
                  label: updater!.actionLabel,
                  onPressed: updater.install,
                )
              else if (updater != null)
                _FieldButton(
                  label: 'Проверить сейчас',
                  onPressed: busy ? null : () => updater.check(manual: true),
                ),
              _FieldButton(
                label: 'Что нового',
                onPressed: () => launchUrl(_releases),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget? _status(BuildContext context) {
    final p = context.palette;
    final updater = this.updater;
    if (updater == null) return null;
    final checked = updater.checkedAt;
    final release = updater.release?.version;
    return switch (updater) {
      AppUpdater(phase: UpdatePhase.downloading, :final progress) => StatusDot(
        label:
            'Скачиваю $release…'
            '${progress == null ? '' : ' ${(progress * 100).round()}%'}',
        color: p.info,
      ),
      AppUpdater(phase: UpdatePhase.installing) => StatusDot(
        label: 'Устанавливаю $release…',
        color: p.info,
      ),
      AppUpdater(phase: UpdatePhase.failed, :final error) => StatusDot(
        label: 'Не удалось обновить${error == null ? '' : ': $error'}',
        color: p.danger,
      ),
      // Обновиться самим не вышло — почему; страница выпуска уже открыта.
      AppUpdater(phase: UpdatePhase.available, :final error?) => StatusDot(
        label: 'Скачайте $release вручную: $error',
        color: p.warning,
      ),
      AppUpdater(phase: UpdatePhase.available) => StatusDot(
        label: 'Доступна версия $release',
        color: p.info,
      ),
      AppUpdater(checking: true) => StatusDot(
        label: 'Проверяю обновления…',
        color: p.muted,
      ),
      AppUpdater(upToDateAt: _?) when checked != null => StatusDot(
        label: 'Последняя версия · проверено в ${_clock(checked)}',
      ),
      _ => StatusDot(label: 'Ещё не проверялось', color: p.muted),
    };
  }

  static String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}

/// Кнопка на светло-серой заливке — второстепенное действие в карточке.
class _FieldButton extends StatelessWidget {
  const _FieldButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.field,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              color: onPressed == null ? p.muted : p.text,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточка с настройками через разделители.
class _Card extends StatelessWidget {
  const _Card({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, row) in rows.indexed) ...[
          if (index > 0) const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: row,
          ),
        ],
      ],
    ),
  );
}

/// Выбор одного варианта на светло-серой плашке; выбранный — белая «таблетка».
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, IconData, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final (option, icon, label) in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(option),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: option == value ? p.card : p.field,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: option == value ? p.softShadow : const [],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: option == value ? p.text : p.muted,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: option == value ? p.text : p.muted,
                            fontWeight: option == value
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Появление снизу с задержкой по [index] — карточки поднимаются по очереди.
class AppearIn extends StatefulWidget {
  const AppearIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 60 + 40 * widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(_curve),
      child: widget.child,
    ),
  );
}
