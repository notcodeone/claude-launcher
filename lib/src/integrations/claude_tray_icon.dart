import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_settings.dart';
import '../claude/claude_host.dart';
import '../launcher_controller.dart';

/// «Скрывать значок Claude» — собственной настройкой Claude:
/// `preferences.menuBarEnabled` в `claude_desktop_config.json` профиля. При
/// `false` Claude вовсе не создаёт значок — ни в трее Windows, ни в строке
/// меню macOS, — а не прячет его под стрелку.
///
/// Этот файл Claude читает при запуске, а при выходе переписывает из памяти.
/// Поэтому правим его, только пока Claude этого профиля закрыт: перед
/// запуском ([beforeLaunch]), после закрытия и при смене настройки — у всех
/// закрытых профилей. Открытый Claude получит её при следующем запуске.
class ClaudeTrayIcon {
  ClaudeTrayIcon({required this.settings, required this.launcher});

  final AppSettings settings;
  final LauncherController launcher;

  static const configName = 'claude_desktop_config.json';
  static const key = 'menuBarEnabled';

  Future<void> _queue = Future.value();
  Timer? _debounce;

  void start() {
    settings.addListener(_schedule);
    launcher.addListener(_schedule);
    _schedule();
  }

  void dispose() {
    settings.removeListener(_schedule);
    launcher.removeListener(_schedule);
    _debounce?.cancel();
  }

  /// Перед запуском профиля — Claude ещё закрыт, файл можно править.
  Future<void> beforeLaunch(String dataDir) =>
      _serial(() => apply(dataDir, hidden: settings.hideClaudeIcon));

  // Правки — после паузы: при закрытии Claude сам дописывает файл.
  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      unawaited(_serial(_syncClosed));
    });
  }

  Future<void> _syncClosed() async {
    final hidden = settings.hideClaudeIcon;
    for (final profile in launcher.profiles) {
      if (launcher.isRunning(profile)) continue;
      final dir = launcher.dataDirOf(profile);
      // Профиль ещё ни разу не открывали — запишем перед первым запуском.
      if (!await Directory(dir).exists()) continue;
      await apply(dir, hidden: hidden);
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Ставит настройку в папке профиля [dataDir] — во всех её копиях (на
  /// Windows Claude из пакета MSIX может видеть копию в папке пакета).
  Future<void> apply(String dataDir, {required bool hidden}) async {
    final host = launcher.host;
    final dirs = host.readableDataDirs(
      ClaudeInstance(pid: 0, dataDir: dataDir),
    );
    var written = false;
    for (final dir in dirs) {
      final file = File(p.join(dir, configName));
      if (!await file.exists()) continue;
      await _applyTo(file, hidden: hidden);
      written = true;
    }
    // Файла нет нигде: Claude ещё не открывали — создаём, только чтобы спрятать.
    if (!written && hidden) {
      await _applyTo(File(p.join(dirs.first, configName)), hidden: true);
    }
  }

  static Future<void> _applyTo(File file, {required bool hidden}) async {
    try {
      Map<String, Object?> config = {};
      if (await file.exists()) {
        final text = await file.readAsString();
        // Пустой файл Claude считает испорченным — не трогаем.
        if (text.trim().isEmpty) return;
        final json = jsonDecode(text);
        if (json is! Map<String, Object?>) return;
        config = json;
      }
      final preferences = Map<String, Object?>.of(
        config['preferences'] as Map<String, Object?>? ?? const {},
      );
      if (hidden) {
        if (preferences[key] == false) return;
        preferences[key] = false;
      } else {
        // Возвращаем как по умолчанию — значок есть.
        if (preferences[key] != false) return;
        preferences.remove(key);
      }
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.claude-launcher-tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({...config, 'preferences': preferences}),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (error) {
      debugPrint('Не удалось изменить значок Claude в ${file.path}: $error');
    }
  }
}
