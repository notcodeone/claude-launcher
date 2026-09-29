import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Настройки самого лаунчера (не профилей).
class AppSettings extends ChangeNotifier {
  AppSettings(this.file);

  final File file;

  ThemeMode themeMode = ThemeMode.system;

  /// Пользователь прошёл окно приветствия.
  bool onboardingDone = false;

  /// Прятать значок самого Claude в строке меню / трее.
  bool hideClaudeIcon = false;

  /// Профиль, который открывается при запуске лаунчера; `null` — ничего не открывать.
  String? startupProfileId;

  Future<void> load() async {
    if (!await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      themeMode =
          ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system;
      onboardingDone = json['onboardingDone'] as bool? ?? false;
      hideClaudeIcon = json['hideClaudeIcon'] as bool? ?? false;
      startupProfileId = json['startupProfileId'] as String?;
    } on FormatException {
      // Повреждённый файл — остаёмся на значениях по умолчанию.
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) => _update(() => themeMode = mode);

  Future<void> setStartupProfile(String? id) =>
      _update(() => startupProfileId = id);

  Future<void> setHideClaudeIcon(bool hide) =>
      _update(() => hideClaudeIcon = hide);

  Future<void> completeOnboarding() => _update(() => onboardingDone = true);

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
        'hideClaudeIcon': hideClaudeIcon,
        'startupProfileId': startupProfileId,
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
