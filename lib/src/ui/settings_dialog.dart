import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import 'widgets.dart';

/// Настройки лаунчера: профиль при запуске и значок Claude. Меняются сразу.
Future<void> showSettingsDialog(
  BuildContext context, {
  required LauncherController launcher,
  required AppSettings settings,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: settings,
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
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WelcomeDialog(launcher: launcher, settings: settings),
  );
}

class _WelcomeDialog extends StatefulWidget {
  const _WelcomeDialog({required this.launcher, required this.settings});

  final LauncherController launcher;
  final AppSettings settings;

  @override
  State<_WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends State<_WelcomeDialog> {
  bool _hideIcon = true;

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
