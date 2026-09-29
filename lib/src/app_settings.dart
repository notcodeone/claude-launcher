import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Настройки самого лаунчера (не профилей): пока только тема окна.
class AppSettings extends ChangeNotifier {
  AppSettings(this.file);

  final File file;

  ThemeMode themeMode = ThemeMode.system;

  Future<void> load() async {
    if (!await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      themeMode =
          ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system;
    } on FormatException {
      // Повреждённый файл — остаёмся на значениях по умолчанию.
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == themeMode) return;
    themeMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'themeMode': themeMode.name}),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
