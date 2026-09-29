import 'dart:io';

import 'package:path/path.dart' as p;

import 'macos_claude_host.dart';
import 'windows_claude_host.dart';

/// Запущенный экземпляр Claude.
class ClaudeInstance {
  const ClaudeInstance({required this.pid, this.dataDir});

  final int pid;

  /// Папка из `--user-data-dir`; `null` — стандартная папка Claude.
  final String? dataDir;
}

/// Всё, что зависит от ОС: где Claude, какие экземпляры запущены, как их открыть и закрыть.
abstract class ClaudeHost {
  ClaudeHost();

  factory ClaudeHost.forCurrentPlatform() {
    if (Platform.isMacOS) return MacClaudeHost();
    if (Platform.isWindows) return WindowsClaudeHost();
    throw UnsupportedError('Поддерживаются только macOS и Windows');
  }

  /// Ищет установленный Claude; возвращает путь к нему или `null`.
  Future<String?> locate();

  /// Стандартная папка данных Claude.
  String get defaultDataDir;

  /// Где создаются папки новых профилей.
  String get profilesBaseDir;

  /// Как часто обновлять список запущенных экземпляров.
  Duration get pollInterval;

  /// Сколько ждать закрытия, прежде чем попросить пользователя закрыть Claude самому.
  Duration get manualQuitHintAfter;

  /// Подсказка, как закрыть Claude вручную, если он не закрылся сам.
  String get manualQuitHint;

  Future<List<ClaudeInstance>> running();

  /// Запускает Claude с папкой [dataDir] (`null` — стандартная папка).
  Future<void> launch(String? dataDir);

  /// Выводит уже запущенный экземпляр на передний план.
  Future<void> activate(ClaudeInstance instance);

  /// Просит экземпляр закрыться так же, как при обычном выходе из приложения.
  /// Принудительно процесс не завершается никогда.
  Future<void> requestQuit(ClaudeInstance instance);

  /// Открывает папку в Finder / Проводнике (или ближайшую существующую родительскую).
  Future<void> revealFolder(String path) async {
    var dir = Directory(path);
    while (!await dir.exists() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [dir.path], mode: ProcessStartMode.detached);
    } else {
      await Process.run('open', [dir.path]);
    }
  }

  /// Папка данных экземпляра с учётом стандартной.
  String dataDirOf(ClaudeInstance instance) => instance.dataDir ?? defaultDataDir;

  /// Сравнение путей без учёта регистра: и APFS, и NTFS по умолчанию к нему нечувствительны.
  bool samePath(String a, String b) => _normalize(a) == _normalize(b);

  static String _normalize(String path) {
    var normalized = p.normalize(path).toLowerCase();
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith(r'\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
