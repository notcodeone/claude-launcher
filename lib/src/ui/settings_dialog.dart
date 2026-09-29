import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../integrations/claude_code_integration.dart';
import '../launcher_controller.dart';
import '../location/location_guard.dart';
import 'theme.dart';
import 'widgets.dart';

/// Настройки лаунчера: проверка страны, значок Claude, события и уведомления
/// Claude Code. Меняются сразу.
/// Профиль, который открывается при запуске, выбирается в меню его карточки.
Future<void> showSettingsDialog(
  BuildContext context, {
  required LauncherController launcher,
  required AppSettings settings,
  required ClaudeCodeIntegration claudeCode,
  required LocationGuard location,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([settings, claudeCode]),
      builder: (context, _) {
        final theme = Theme.of(context);
        return AppDialogFrame(
          children: [
            Text('Настройки', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Как ClaudeLauncher работает вместе с Claude.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
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
                if (enabled) await location.check(force: true);
              },
            ),
            const SizedBox(height: 24),
            _ClaudeIconSwitch(
              launcher: launcher,
              value: settings.hideClaudeIcon,
              onChanged: (hide) async {
                await settings.setHideClaudeIcon(hide);
                await launcher.setClaudeIconHidden(hide);
              },
            ),
            const SizedBox(height: 24),
            _ClaudeCodeEventsSwitch(
              value: settings.claudeCodeEvents,
              claudeCode: claudeCode,
              onChanged: claudeCode.setEnabled,
            ),
            if (settings.claudeCodeEvents) ...[
              const SizedBox(height: 24),
              _LauncherNotificationsSwitch(
                value: settings.launcherNotifications,
                claudeCode: claudeCode,
                onChanged: claudeCode.setNotificationsEnabled,
              ),
            ],
            const SizedBox(height: 24),
            AppButton(
              label: 'Готово',
              expand: true,
              large: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    ),
  );
}

/// Окно приветствия при первом запуске: те же настройки, применяются по «Начать».
Future<void> showWelcomeDialog(
  BuildContext context, {
  required LauncherController launcher,
  required AppSettings settings,
  required ClaudeCodeIntegration claudeCode,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WelcomeDialog(
      launcher: launcher,
      settings: settings,
      claudeCode: claudeCode,
    ),
  );
}

class _WelcomeDialog extends StatefulWidget {
  const _WelcomeDialog({
    required this.launcher,
    required this.settings,
    required this.claudeCode,
  });

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration claudeCode;

  @override
  State<_WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends State<_WelcomeDialog> {
  bool _hideIcon = true;
  bool _claudeCodeEvents = true;
  bool _launcherNotifications = true;

  Future<void> _start() async {
    final settings = widget.settings;
    // При первом запуске в списке только профиль со стандартной папкой —
    // обычный Claude. Его и открываем при запуске; поменять — в меню профиля.
    await settings.setStartupProfile(
      widget.launcher.profiles
          .where((profile) => profile.usesDefaultFolder)
          .map((profile) => profile.id)
          .firstOrNull,
    );
    if (_hideIcon != settings.hideClaudeIcon) {
      await settings.setHideClaudeIcon(_hideIcon);
      await widget.launcher.setClaudeIconHidden(_hideIcon);
    }
    // До событий: иначе лаунчер успел бы забрать уведомления у Claude и вернуть.
    if (_launcherNotifications != settings.launcherNotifications) {
      await widget.claudeCode.setNotificationsEnabled(_launcherNotifications);
    }
    if (_claudeCodeEvents != settings.claudeCodeEvents) {
      await widget.claudeCode.setEnabled(_claudeCodeEvents);
    }
    await settings.completeOnboarding();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialogFrame(
      children: [
        Text(
          'Добро пожаловать в ClaudeLauncher',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Пара настроек перед началом. Их можно поменять позже — '
          'кнопка с шестерёнкой в шапке.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        _ClaudeIconSwitch(
          launcher: widget.launcher,
          value: _hideIcon,
          onChanged: (hide) => setState(() => _hideIcon = hide),
        ),
        const SizedBox(height: 24),
        _ClaudeCodeEventsSwitch(
          value: _claudeCodeEvents,
          onChanged: (enabled) => setState(() => _claudeCodeEvents = enabled),
        ),
        if (_claudeCodeEvents) ...[
          const SizedBox(height: 24),
          _LauncherNotificationsSwitch(
            value: _launcherNotifications,
            onChanged: (enabled) =>
                setState(() => _launcherNotifications = enabled),
          ),
        ],
        const SizedBox(height: 24),
        AppButton(
          label: 'Начать',
          expand: true,
          large: true,
          onPressed: _start,
        ),
      ],
    );
  }
}

class _ClaudeIconSwitch extends StatelessWidget {
  const _ClaudeIconSwitch({
    required this.launcher,
    required this.value,
    required this.onChanged,
  });

  final LauncherController launcher;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final host = launcher.host;
    return SettingSwitchRow(
      title: Platform.isMacOS
          ? 'Скрывать значок Claude в строке меню'
          : 'Скрывать значок Claude в трее',
      description: Platform.isMacOS
          ? 'Переключаться удобнее здесь, значок Claude не нужен. Сработает после '
                'перезапуска Claude. Если значок останется, выключите его в '
                'системных настройках: Строка меню → Разрешить в строке меню.'
          : 'Переключаться удобнее здесь, значок Claude уйдёт под стрелку ▲. '
                'Убрать его совсем Windows не позволяет.',
      value: value,
      onChanged: onChanged,
      link: InlineLink(
        label: Platform.isMacOS
            ? 'Открыть настройки строки меню'
            : 'Открыть настройки панели задач',
        onTap: host.openIconSettings,
      ),
    );
  }
}

class _ClaudeCodeEventsSwitch extends StatelessWidget {
  const _ClaudeCodeEventsSwitch({
    required this.value,
    required this.onChanged,
    this.claudeCode,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// В настройках — чтобы показать состояние подключения; в приветствии не нужен.
  final ClaudeCodeIntegration? claudeCode;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final error = claudeCode?.error;
    return SettingSwitchRow(
      title: 'События Claude Code',
      description:
          'Лаунчер узнаёт, когда Claude Code завершил задачу или ждёт вас, и '
          'показывает это на карточке профиля. Для этого он добавит свои хуки в '
          '~/.claude/settings.json и сохранит рядом резервную копию. Позже сюда '
          'подключим уведомления в Telegram.',
      value: value,
      onChanged: onChanged,
      link: switch ((error, value && (claudeCode?.connected ?? false))) {
        (final String message, _) => Text(
          message,
          style: TextStyle(color: p.danger, fontSize: 12.5),
        ),
        (null, true) => const StatusDot(label: 'Подключено'),
        _ => null,
      },
    );
  }
}

class _LauncherNotificationsSwitch extends StatelessWidget {
  const _LauncherNotificationsSwitch({
    required this.value,
    required this.onChanged,
    this.claudeCode,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// В настройках — чтобы показать, работает ли; в приветствии не нужен.
  final ClaudeCodeIntegration? claudeCode;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final claudeCode = this.claudeCode;
    return SettingSwitchRow(
      title: 'Уведомления через ClaudeLauncher',
      description:
          'Пока лаунчер запущен, о разрешениях, вопросах и готовых задачах '
          'Claude Code сообщает он, а сам Claude — нет. Открытый сейчас Claude '
          'перестанет уведомлять сам после перезапуска. Выйдете из лаунчера — '
          'Claude снова будет уведомлять сам, как только его закроют.',
      value: value,
      onChanged: onChanged,
      link: switch (claudeCode) {
        ClaudeCodeIntegration(notificationsError: final String message) => Text(
          message,
          style: TextStyle(color: p.danger, fontSize: 12.5),
        ),
        ClaudeCodeIntegration(notificationsDenied: true, :final notifier?)
            when value =>
          InlineLink(
            label:
                'Система не разрешает ClaudeLauncher уведомления, поэтому '
                'уведомляет сам Claude. Открыть настройки уведомлений',
            onTap: notifier.openSettings,
          ),
        ClaudeCodeIntegration(notifying: true) => const StatusDot(
          label: 'Работает',
        ),
        _ => null,
      },
    );
  }
}
