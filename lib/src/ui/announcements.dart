import 'dart:io';

import '../app_settings.dart';
import '../claude/claude_updates.dart';
import '../updates/app_updater.dart';
import 'home_page.dart' show AppPages;
import 'settings_pages.dart' show SettingsSection;
import 'snackbar.dart';
import 'widgets.dart';

/// Что лаунчер сообщает оповещением внизу окна ([AppSnackbar]): подсказку
/// при первом запуске, вышедшие обновления лаунчера и Claude и чем они
/// закончились. Каждое — один раз, а не при каждой перерисовке.
class Announcements {
  Announcements({required this.settings, this.updater, this.claudeUpdates});

  final AppSettings settings;
  final AppUpdater? updater;
  final ClaudeUpdates? claudeUpdates;

  String? _launcherVersion;
  UpdatePhase? _launcherPhase;
  String? _claudeVersion;
  ClaudeUpdatePhase? _claudePhase;

  void start() {
    if (!settings.trayHintDismissed) {
      // Пока не закроют: иначе после перезапуска подсказка пропала бы
      // непрочитанной.
      AppSnackbar.show(
        Snack(
          id: 'tray-hint',
          icon: AppIcons.info,
          text: Platform.isMacOS
              ? 'ClaudeLauncher живёт в строке меню — ищите его значок вверху '
                    'экрана. Это окно можно закрыть.'
              : 'ClaudeLauncher живёт в трее у часов (возможно, под стрелкой '
                    '▲). Это окно можно закрыть.',
          action: 'Понятно',
          onAction: settings.dismissTrayHint,
          onClose: settings.dismissTrayHint,
          duration: null,
        ),
      );
    }
    updater?.addListener(_launcher);
    claudeUpdates?.addListener(_claude);
  }

  void dispose() {
    updater?.removeListener(_launcher);
    claudeUpdates?.removeListener(_claude);
  }

  static void _openUpdates() => AppPages.open(SettingsSection.updates.route);

  void _launcher() {
    final updater = this.updater!;
    final phase = updater.phase;
    final version = updater.release?.version;
    final was = _launcherPhase;
    _launcherPhase = phase;
    if (phase == UpdatePhase.available &&
        version != null &&
        version != _launcherVersion) {
      _launcherVersion = version;
      AppSnackbar.show(
        Snack(
          id: 'launcher-update',
          icon: AppIcons.download,
          text: 'Вышел ClaudeLauncher $version',
          action: 'Обновить',
          onAction: updater.install,
          duration: const Duration(seconds: 10),
        ),
      );
    }
    if (phase == UpdatePhase.failed && was != UpdatePhase.failed) {
      AppSnackbar.show(
        const Snack(
          id: 'launcher-update',
          icon: AppIcons.error,
          error: true,
          text: 'Не удалось обновить ClaudeLauncher',
          action: 'Подробнее',
          onAction: _openUpdates,
        ),
      );
    }
  }

  void _claude() {
    final updates = claudeUpdates!;
    final phase = updates.phase;
    final version = updates.available?.version;
    final was = _claudePhase;
    _claudePhase = phase;
    if (version != null &&
        version != _claudeVersion &&
        phase == ClaudeUpdatePhase.idle) {
      _claudeVersion = version;
      AppSnackbar.show(
        Snack(
          id: 'claude-update',
          icon: AppIcons.download,
          text: 'Вышел Claude $version',
          action: 'Подробнее',
          onAction: _openUpdates,
          duration: const Duration(seconds: 10),
        ),
      );
    }
    if (was == ClaudeUpdatePhase.installing &&
        phase == ClaudeUpdatePhase.idle) {
      AppSnackbar.show(
        Snack(
          id: 'claude-update',
          icon: AppIcons.check,
          text: 'Claude обновлён до ${updates.installed}',
        ),
      );
    }
    if (phase == ClaudeUpdatePhase.failed && was != ClaudeUpdatePhase.failed) {
      AppSnackbar.show(
        const Snack(
          id: 'claude-update',
          icon: AppIcons.error,
          error: true,
          text: 'Не удалось обновить Claude',
          action: 'Подробнее',
          onAction: _openUpdates,
        ),
      );
    }
  }
}
