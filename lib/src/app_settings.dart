import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

/// Настройки самого лаунчера (не профилей).
class AppSettings extends ChangeNotifier {
  AppSettings(this.file);

  final File file;

  ThemeMode themeMode = ThemeMode.system;

  /// Пользователь прошёл окно приветствия.
  bool onboardingDone = false;

  /// Пользователь закрыл подсказку, что лаунчер живёт в строке меню / трее.
  bool trayHintDismissed = false;

  /// Прятать значок самого Claude в строке меню / трее.
  bool hideClaudeIcon = false;

  /// Получать события Claude Code через его хуки (задел для уведомлений в Telegram).
  bool claudeCodeEvents = false;

  /// Уведомления Claude Code показывает лаунчер, а сам Claude — нет
  /// (пока лаунчер запущен). Работает, только когда включены события.
  bool launcherNotifications = true;

  /// Проверять страну по IP-адресу перед запуском профиля: Claude доступен
  /// не во всех странах.
  bool locationCheck = true;

  /// Спрашивать у GitHub, вышла ли новая версия лаунчера.
  bool checkUpdates = true;

  /// Показывать функции, которые ещё проверяются (сейчас — лимиты профиля).
  bool experimentalFeatures = false;

  /// Профиль, который открывается при запуске лаунчера; `null` — ничего не открывать.
  String? startupProfileId;

  /// Локальный порт и ключ приёма событий Claude Code. Ключ не даёт чужим
  /// процессам подсовывать лаунчеру события.
  int eventsPort = 47813;
  String eventsToken = '';

  Future<void> load() async {
    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        themeMode =
            ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system;
        onboardingDone = json['onboardingDone'] as bool? ?? false;
        trayHintDismissed = json['trayHintDismissed'] as bool? ?? false;
        hideClaudeIcon = json['hideClaudeIcon'] as bool? ?? false;
        claudeCodeEvents = json['claudeCodeEvents'] as bool? ?? false;
        launcherNotifications = json['launcherNotifications'] as bool? ?? true;
        startupProfileId = json['startupProfileId'] as String?;
        locationCheck = json['locationCheck'] as bool? ?? true;
        experimentalFeatures = json['experimentalFeatures'] as bool? ?? false;
        checkUpdates = json['checkUpdates'] as bool? ?? true;
        eventsPort = json['eventsPort'] as int? ?? eventsPort;
        eventsToken = json['eventsToken'] as String? ?? '';
      } on FormatException {
        // Повреждённый файл — остаёмся на значениях по умолчанию.
      }
    }
    if (eventsToken.isEmpty) {
      final random = Random.secure();
      eventsToken = List.generate(
        32,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      // Ключ попадает в хуки Claude Code — он должен пережить перезапуск.
      await _save();
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) => _update(() => themeMode = mode);

  Future<void> setStartupProfile(String? id) =>
      _update(() => startupProfileId = id);

  Future<void> setLocationCheck(bool enabled) =>
      _update(() => locationCheck = enabled);

  Future<void> setCheckUpdates(bool enabled) =>
      _update(() => checkUpdates = enabled);

  Future<void> setExperimentalFeatures(bool enabled) =>
      _update(() => experimentalFeatures = enabled);

  Future<void> setHideClaudeIcon(bool hide) =>
      _update(() => hideClaudeIcon = hide);

  Future<void> setClaudeCodeEvents(bool enabled) =>
      _update(() => claudeCodeEvents = enabled);

  Future<void> setLauncherNotifications(bool enabled) =>
      _update(() => launcherNotifications = enabled);

  Future<void> setEventsPort(int port) => _update(() => eventsPort = port);

  Future<void> completeOnboarding() => _update(() => onboardingDone = true);

  Future<void> dismissTrayHint() => _update(() => trayHintDismissed = true);

  Future<void> _update(void Function() change) async {
    change();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'themeMode': themeMode.name,
        'onboardingDone': onboardingDone,
        'trayHintDismissed': trayHintDismissed,
        'hideClaudeIcon': hideClaudeIcon,
        'claudeCodeEvents': claudeCodeEvents,
        'launcherNotifications': launcherNotifications,
        'startupProfileId': startupProfileId,
        'locationCheck': locationCheck,
        'experimentalFeatures': experimentalFeatures,
        'checkUpdates': checkUpdates,
        'eventsPort': eventsPort,
        'eventsToken': eventsToken,
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
