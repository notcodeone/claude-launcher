import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../integrations/claude_code_integration.dart';
import '../launcher_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// Настройки лаунчера: профиль при запуске, значок Claude, события Claude Code.
/// Меняются сразу.
Future<void> showSettingsDialog(
  BuildContext context, {
  required LauncherController launcher,
  required AppSettings settings,
  required ClaudeCodeIntegration claudeCode,
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
            _StartupProfileChoice(
              launcher: launcher,
              value: settings.startupProfileId,
              onChanged: settings.setStartupProfile,
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

  /// По умолчанию — профиль со стандартной папкой: это обычный запуск Claude.
  late String? _startupProfileId = widget.launcher.profiles
      .where((profile) => profile.usesDefaultFolder)
      .map((profile) => profile.id)
      .firstOrNull;

  Future<void> _start() async {
    final settings = widget.settings;
    await settings.setStartupProfile(_startupProfileId);
    if (_hideIcon != settings.hideClaudeIcon) {
      await settings.setHideClaudeIcon(_hideIcon);
      await widget.launcher.setClaudeIconHidden(_hideIcon);
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
        _StartupProfileChoice(
          launcher: widget.launcher,
          value: _startupProfileId,
          onChanged: (id) => setState(() => _startupProfileId = id),
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

class _StartupProfileChoice extends StatelessWidget {
  const _StartupProfileChoice({
    required this.launcher,
    required this.value,
    required this.onChanged,
  });

  final LauncherController launcher;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Профиль при запуске', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Если Claude не открыт, лаунчер откроет этот профиль, когда запустится сам.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        PillChoice<String?>(
          value: value,
          options: [
            (null, 'Не открывать'),
            for (final profile in launcher.profiles) (profile.id, profile.name),
          ],
          onChanged: onChanged,
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
