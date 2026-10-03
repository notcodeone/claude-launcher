import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Своя папка Claude Code профиля — `CLAUDE_CONFIG_DIR` вкладки Code. Claude
/// передаёт эту переменную из своего окружения Claude Code, который запускает
/// (см. docs/dev/research/claude-desktop-data.md), поэтому память проектов,
/// переписка, история и разрешения профиля живут в его папке, а не в общей
/// `~/.claude`.
///
/// Общее с «Основным» — `CLAUDE.md` (импортом) и агенты, команды, навыки
/// (копией). Ссылками их не сделать: Claude отказывается писать в папку
/// Claude Code, если в пути внутри неё есть символическая ссылка на папку.
class ProfileClaudeCode {
  ProfileClaudeCode({required this.dir, required this.shared});

  /// Папка внутри папки данных профиля. Не `claude-code`: там Claude хранит
  /// свои версии Claude Code.
  static const folder = 'claude-config';

  static String dirOf(String dataDir) => p.join(dataDir, folder);

  /// Общая папка Claude Code — та, что у «Основного».
  static String sharedDir(Map<String, String> environment) {
    final custom = environment['CLAUDE_CONFIG_DIR']?.trim();
    if (custom != null && custom.isNotEmpty) return p.normalize(custom);
    final home = Platform.isWindows
        ? environment['USERPROFILE']!
        : environment['HOME']!;
    return p.join(home, '.claude');
  }

  /// Что берётся из общей папки копией.
  static const sharedFolders = ['agents', 'commands', 'skills'];

  /// Что лаунчер скопировал и с каким содержимым: копию, которую потом
  /// поменяли в профиле, он больше не трогает.
  static const manifestName = '.claude-launcher-shared.json';

  final String dir;
  final String shared;

  File get _manifest => File(p.join(dir, manifestName));

  /// Перед запуском профиля: создаёт папку, подключает общий `CLAUDE.md` и
  /// досинхронизирует общие агенты, команды и навыки. Повторный вызов ничего
  /// не ломает. Ошибка не мешает запуску — профиль откроется с тем, что есть.
  Future<void> prepare() async {
    try {
      await Directory(dir).create(recursive: true);
      await _linkClaudeMd();
      await _syncShared();
    } catch (error) {
      debugPrint('Не удалось подготовить папку Claude Code: $error');
    }
  }

  /// `CLAUDE.md` профиля из одной строки — импорта общего. Создаётся один
  /// раз: свой текст, который потом допишут в профиле, не трогаем.
  Future<void> _linkClaudeMd() async {
    final own = File(p.join(dir, 'CLAUDE.md'));
    final common = File(p.join(shared, 'CLAUDE.md'));
    if (await own.exists() || !await common.exists()) return;
    await own.writeAsString('@${common.absolute.path}\n');
  }

  Future<void> _syncShared() async {
    final written = await _readManifest();
    final next = <String, String>{};
    for (final folder in sharedFolders) {
      final source = Directory(p.join(shared, folder));
      if (!await source.exists()) continue;
      await for (final entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: shared);
        final hash = await _hash(entity);
        final target = File(p.join(dir, relative));
        final copied = written[relative];
        if (!await target.exists()) {
          // Удалили в профиле то, что лаунчер копировал, — не возвращаем.
          if (copied != null && copied == hash) {
            next[relative] = copied;
            continue;
          }
          await target.parent.create(recursive: true);
          await entity.copy(target.path);
          next[relative] = hash;
          continue;
        }
        final current = await _hash(target);
        if (copied == null || current != copied) {
          // Свой файл профиля или копия, изменённая в профиле, — не трогаем.
          if (copied != null) next[relative] = copied;
          continue;
        }
        if (hash != copied) await entity.copy(target.path);
        next[relative] = hash;
      }
    }
    // Удалённое из общей папки убираем и в профиле — если это наша
    // неизменённая копия.
    for (final MapEntry(:key, :value) in written.entries) {
      if (next.containsKey(key)) continue;
      final target = File(p.join(dir, key));
      if (await target.exists() && await _hash(target) == value) {
        await target.delete();
      }
    }
    await _writeManifest(next);
  }

  Future<Map<String, String>> _readManifest() async {
    try {
      final json = jsonDecode(await _manifest.readAsString());
      if (json is Map) {
        return {
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is String) key: value,
        };
      }
    } on FileSystemException {
      // Ещё не копировали.
    } on FormatException {
      // Испорчен — начнём заново: чужие файлы при этом не перезаписываются.
    }
    return {};
  }

  Future<void> _writeManifest(Map<String, String> files) async {
    final tmp = File('${_manifest.path}.tmp');
    await tmp.writeAsString(jsonEncode(files), flush: true);
    await tmp.rename(_manifest.path);
  }

  static Future<String> _hash(File file) async =>
      '${await sha256.bind(file.openRead()).first}';
}

/// Проект, в котором профиль работал: где лежит его папка в `projects/` и
/// есть ли у неё память.
class ClaudeCodeProject {
  const ClaudeCodeProject({
    required this.cwd,
    required this.folder,
    required this.hasMemory,
  });

  /// Папка проекта на диске — из карточки сессии.
  final String cwd;

  /// Папка проекта внутри `projects/` (закодированный путь).
  final String folder;
  final bool hasMemory;
}

/// Что перенести в свою папку Claude Code профиля, который до сих пор жил в
/// общей `~/.claude`: переписку его сессий и, по выбору, память проектов.
class ClaudeCodeMigrationPlan {
  const ClaudeCodeMigrationPlan({
    required this.transcripts,
    required this.projects,
  });

  /// Пути относительно папки Claude Code: `projects/<проект>/<id>.jsonl`.
  final List<String> transcripts;
  final List<ClaudeCodeProject> projects;

  bool get isEmpty => transcripts.isEmpty && projects.isEmpty;
}

/// Перенос профиля в свою папку Claude Code. Только копирование: общая
/// `~/.claude` не меняется, поэтому вернуть всё как было — просто снова
/// выбрать общую папку.
class ClaudeCodeMigration {
  ClaudeCodeMigration({
    required this.shared,
    required this.dir,
    required this.dataDirs,
  });

  final String shared;
  final String dir;

  /// Где искать карточки сессий профиля (у пакета MSIX — две папки).
  final List<String> dataDirs;

  /// Карточка сессии больше этого — не карточка (самые большие ~1,4 МБ).
  static const _maxCard = 4 * 1024 * 1024;

  Future<ClaudeCodeMigrationPlan> plan() async {
    final sessions = <String, String>{}; // cliSessionId → cwd
    for (final dataDir in dataDirs) {
      final root = Directory(p.join(dataDir, 'claude-code-sessions'));
      if (!await root.exists()) continue;
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File ||
            !p.basename(entity.path).startsWith('local_') ||
            p.extension(entity.path) != '.json') {
          continue;
        }
        try {
          if (await entity.length() > _maxCard) continue;
          final json = jsonDecode(await entity.readAsString());
          if (json case {
            'cliSessionId': final String id,
            'cwd': final String cwd,
          } when id.isNotEmpty) {
            sessions[id] = cwd;
          }
        } catch (_) {
          // Повреждённая или недописанная карточка — пропускаем.
        }
      }
    }

    final transcripts = <String>[];
    final projects = <String, ClaudeCodeProject>{};
    final root = Directory(p.join(shared, 'projects'));
    if (await root.exists()) {
      await for (final project in root.list()) {
        if (project is! Directory) continue;
        final folder = p.basename(project.path);
        await for (final entity in project.list()) {
          final name = p.basename(entity.path);
          if (entity is! File || p.extension(name) != '.jsonl') continue;
          final cwd = sessions[p.basenameWithoutExtension(name)];
          if (cwd == null) continue;
          transcripts.add(p.join('projects', folder, name));
          projects[folder] ??= ClaudeCodeProject(
            cwd: cwd,
            folder: folder,
            hasMemory: await Directory(p.join(project.path, 'memory')).exists(),
          );
        }
      }
    }
    transcripts.sort();
    return ClaudeCodeMigrationPlan(
      transcripts: transcripts,
      projects: projects.values.toList()
        ..sort((a, b) => a.cwd.compareTo(b.cwd)),
    );
  }

  /// Копирует переписку (с папкой подагентов рядом) и память выбранных
  /// проектов [memoryOf] — по папке в `projects/`. Уже существующее в папке
  /// профиля не перезаписывается. Возвращает, сколько файлов скопировано.
  Future<int> apply(
    ClaudeCodeMigrationPlan plan, {
    Set<String> memoryOf = const {},
  }) async {
    var copied = 0;
    for (final transcript in plan.transcripts) {
      copied += await _copy(transcript);
      final sidecar = p.withoutExtension(transcript);
      if (await Directory(p.join(shared, sidecar)).exists()) {
        copied += await _copy(sidecar);
      }
    }
    for (final project in plan.projects) {
      if (!project.hasMemory || !memoryOf.contains(project.folder)) continue;
      copied += await _copy(p.join('projects', project.folder, 'memory'));
    }
    return copied;
  }

  /// Файл или папка [relative] из общей папки в папку профиля.
  Future<int> _copy(String relative) async {
    final from = p.join(shared, relative);
    if (await FileSystemEntity.isDirectory(from)) {
      var count = 0;
      await for (final entity in Directory(
        from,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          count += await _copy(p.relative(entity.path, from: shared));
        }
      }
      return count;
    }
    final target = File(p.join(dir, relative));
    if (await target.exists() || !await File(from).exists()) return 0;
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.claude-launcher-tmp');
    await File(from).copy(tmp.path);
    await tmp.rename(target.path);
    return 1;
  }
}
