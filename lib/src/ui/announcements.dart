import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../claude/claude_updates.dart';
import '../updates/app_updater.dart';
import 'home_page.dart' show AppPages;
import 'settings_pages.dart' show SettingsSection;
import 'snackbar.dart';
import 'widgets.dart';

/// Все оповещения лаунчера — в одном месте и коротко: каждое влезает в
/// одну строку окна (проверяет тест).
abstract final class Snacks {
  static Snack trayHint({required VoidCallback onDismiss}) => Snack(
    id: 'tray-hint',
    icon: AppIcons.info,
    text: Platform.isMacOS
        ? 'ClaudeLauncher живёт в строке меню'
        : 'ClaudeLauncher живёт в трее',
    action: 'Понятно',
    onAction: onDismiss,
    onClose: onDismiss,
    // Пока не закроют: иначе после перезапуска подсказка пропала бы
    // непрочитанной.
    duration: null,
  );

  /// [selfUpdates] — лаунчер обновит себя сам; иначе кнопка ведёт скачать.
  static Snack launcherUpdate(
    String version,
    VoidCallback install, {
    bool selfUpdates = true,
  }) => Snack(
    id: 'launcher-update',
    icon: AppIcons.download,
    text: 'Вышел ClaudeLauncher $version',
    action: selfUpdates ? 'Обновить' : 'Скачать',
    onAction: install,
    duration: const Duration(seconds: 10),
  );

  static Snack launcherFailed(VoidCallback details) => Snack(
    id: 'launcher-update',
    icon: AppIcons.error,
    error: true,
    text: 'Не удалось обновить ClaudeLauncher',
    action: 'Подробнее',
    onAction: details,
  );

  static Snack claudeUpdate(String version, VoidCallback details) => Snack(
    id: 'claude-update',
    icon: AppIcons.download,
    text: 'Вышел Claude $version',
    action: 'Подробнее',
    onAction: details,
    duration: const Duration(seconds: 10),
  );

  static Snack claudeUpdated(String version) => Snack(
    id: 'claude-update',
    icon: AppIcons.check,
    text: 'Claude обновлён до $version',
  );

  static Snack claudeFailed(VoidCallback details) => Snack(
    id: 'claude-update',
    icon: AppIcons.error,
    error: true,
    text: 'Не удалось обновить Claude',
    action: 'Подробнее',
    onAction: details,
  );

  static Snack profileCreated(String name, VoidCallback open) => Snack(
    id: 'profile-created',
    icon: AppIcons.check,
    text: 'Профиль «$name» создан',
    action: 'Открыть',
    onAction: open,
  );

  static Snack profileSaved(String name) => Snack(
    id: 'profile-saved',
    icon: AppIcons.check,
    text: 'Профиль «$name» сохранён',
  );
}

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
      AppSnackbar.show(Snacks.trayHint(onDismiss: settings.dismissTrayHint));
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
        Snacks.launcherUpdate(
          version,
          updater.install,
          selfUpdates: updater.selfUpdates,
        ),
      );
    }
    if (phase == UpdatePhase.failed && was != UpdatePhase.failed) {
      AppSnackbar.show(Snacks.launcherFailed(_openUpdates));
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
      AppSnackbar.show(Snacks.claudeUpdate(version, _openUpdates));
    }
    if (was == ClaudeUpdatePhase.installing &&
        phase == ClaudeUpdatePhase.idle) {
      AppSnackbar.show(Snacks.claudeUpdated('${updates.installed}'));
    }
    if (phase == ClaudeUpdatePhase.failed && was != ClaudeUpdatePhase.failed) {
      AppSnackbar.show(Snacks.claudeFailed(_openUpdates));
    }
  }
}
