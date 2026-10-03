import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'profile_identity.dart';

/// Скопировать — сессия остаётся и в исходном профиле; перенести — убирается
/// из него (карточка уходит в журнал переноса, откуда её вернёт «Отменить»).
enum TransferMode { copy, move }

/// Одна сторона переноса: профиль, его папки данных и папка Claude Code.
class TransferSide {
  const TransferSide({
    required this.name,
    required this.dataDirs,
    required this.claudeCodeDir,
    required this.identity,
  });

  /// Название профиля — для текстов.
  final String name;

  /// Папки данных; первая — та, куда пишем (у пакета MSIX вторая — копия в
  /// папке пакета, её только читаем).
  final List<String> dataDirs;

  /// Папка Claude Code: своя у профиля или общая `~/.claude`.
  final String claudeCodeDir;
  final ProfileIdentity identity;
}

/// Почему перенести нельзя — текст для человека.
class TransferRefused implements Exception {
  const TransferRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Что сделал перенос — для «Отменить».
class TransferRecord {
  const TransferRecord({required this.id, required this.dir});

  final String id;

  /// Папка журнала этой операции.
  final Directory dir;

  File get manifest => File(p.join(dir.path, 'manifest.json'));
}

/// Перенос сессии Code из профиля в профиль — копированием файлов, по правилам
/// из docs/dev/research/claude-desktop-data.md («Правила переноса сессии»):
///
/// - карточка ложится в папку аккаунта и организации целевого профиля;
/// - сессию, которая там уже есть или удалена (`deleted_…`), не трогаем;
/// - из копии убираются тяжёлые данные MCP и выданные разрешения;
/// - переписка (и папка подагентов) копируется в папку Claude Code цели, если
///   у профилей она разная;
/// - всё записанное — в журнале [journalRoot]: «Отменить» уберёт копии (в
///   журнал же, не насовсем) и вернёт перенесённую карточку.
///
/// Целевой профиль должен быть закрыт: открытый Claude не увидит новую
/// карточку до перезапуска, а свою папку сессий переписывает сам.
class SessionTransfer {
  SessionTransfer({required this.journalRoot, this.keep = 20});

  final Directory journalRoot;

  /// Сколько последних операций хранить в журнале.
  final int keep;

  /// Поля карточки, которые не переносим: тяжёлые данные MCP и привязки к
  /// задачам исходного профиля.
  static const droppedFields = [
    'remoteMcpServersConfig',
    'enabledMcpTools',
    'bridgeSessionIds',
    'scheduledTaskId',
  ];

  /// Разрешения, выданные в исходном профиле, — в цели заново.
  static const resetFields = {
    'alwaysAllowedReasons': <Object?>[],
    'sessionPermissionUpdates': <Object?>[],
  };

  /// Поля, без которых карточка — незнакомого вида: такую не переносим.
  static const requiredFields = [
    'sessionId',
    'cliSessionId',
    'cwd',
    'lastActivityAt',
  ];

  Future<TransferRecord> run({
    required String sessionId,
    required TransferSide source,
    required TransferSide target,
    TransferMode mode = TransferMode.copy,
  }) async {
    final from = source.identity.sessionsFolder;
    final to = target.identity.sessionsFolder;
    if (from == null) {
      throw TransferRefused('Не знаю аккаунт «${source.name}» — откройте его');
    }
    if (to == null) {
      throw TransferRefused(
        'Не знаю аккаунт «${target.name}» — войдите в него',
      );
    }

    // Карточка в исходном профиле.
    File? card;
    for (final dir in source.dataDirs) {
      final file = File(p.join(dir, from, '$sessionId.json'));
      if (await file.exists()) {
        card = file;
        break;
      }
    }
    if (card == null) {
      throw TransferRefused('Сессии нет в «${source.name}»');
    }
    final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(await card.readAsString());
      if (decoded is! Map<String, Object?> ||
          !requiredFields.every(decoded.containsKey)) {
        throw const FormatException();
      }
      json = decoded;
    } on FormatException {
      throw const TransferRefused('Claude поменял формат сессий');
    }
    final cliSessionId = json['cliSessionId'] as String;

    // Цель: уже есть или удалена — не трогаем.
    final targetDir = Directory(p.join(target.dataDirs.first, to));
    final targetCard = File(p.join(targetDir.path, '$sessionId.json'));
    for (final dir in target.dataDirs) {
      final folder = Directory(p.join(dir, to));
      if (await File(p.join(folder.path, '$sessionId.json')).exists() ||
          await _hasCli(folder, cliSessionId)) {
        throw TransferRefused('Сессия уже есть в «${target.name}»');
      }
      for (final marker in ['deleted_$cliSessionId', 'deleted_$sessionId']) {
        if (await File(p.join(folder.path, marker)).exists()) {
          throw TransferRefused('Сессию удалили в «${target.name}»');
        }
      }
    }

    final op = await _newOperation();
    final created = <String, String>{}; // путь → sha256
    final moved = <Map<String, String>>[];
    try {
      // Переписка — в папку Claude Code цели, если она не та же.
      if (!_samePath(source.claudeCodeDir, target.claudeCodeDir)) {
        final transcript = await _findTranscript(
          source.claudeCodeDir,
          cliSessionId,
        );
        if (transcript != null) {
          final relative = p.relative(
            transcript.path,
            from: source.claudeCodeDir,
          );
          await _copyTree(
            transcript.path,
            p.join(target.claudeCodeDir, relative),
            created,
          );
          final sidecar = Directory(p.withoutExtension(transcript.path));
          if (await sidecar.exists()) {
            await _copyTree(
              sidecar.path,
              p.join(target.claudeCodeDir, p.withoutExtension(relative)),
              created,
            );
          }
        }
      }

      // Карточка — последней: пока её нет, Claude цели о сессии не знает.
      final copy = {
        for (final MapEntry(:key, :value) in json.entries)
          if (!droppedFields.contains(key)) key: value,
        for (final MapEntry(:key, :value) in resetFields.entries)
          if (json.containsKey(key)) key: value,
      };
      await targetDir.create(recursive: true);
      await _writeAtomic(
        targetCard,
        utf8.encode(jsonEncode(copy)),
        modified: await card.lastModified(),
      );
      created[targetCard.path] = await _hash(targetCard);

      if (mode == TransferMode.move) {
        final kept = File(p.join(op.dir.path, 'source', '$sessionId.json'));
        await kept.parent.create(recursive: true);
        await _move(card, kept);
        moved.add({'from': card.path, 'to': kept.path});
      }
    } catch (_) {
      // Не вышло — убираем то, что успели записать.
      await _undoFiles(op, created, moved, force: true);
      rethrow;
    } finally {
      await op.manifest.writeAsString(
        jsonEncode({
          'sessionId': sessionId,
          'source': source.name,
          'target': target.name,
          'mode': mode.name,
          'created': created,
          'moved': moved,
        }),
      );
    }
    await _prune();
    return op;
  }

  /// Отменяет перенос [record]: копии уходят в журнал, перенесённая карточка
  /// возвращается. Если копию с тех пор меняли (профиль открывали и
  /// продолжили сессию) — отказ: иначе пропала бы новая переписка.
  Future<void> undo(TransferRecord record) async {
    final json =
        jsonDecode(await record.manifest.readAsString())
            as Map<String, Object?>;
    final created = {
      for (final MapEntry(:key, :value)
          in (json['created'] as Map<String, Object?>).entries)
        key: value as String,
    };
    final moved = [
      for (final entry in json['moved'] as List<Object?>)
        {
          for (final MapEntry(:key, :value)
              in (entry as Map<String, Object?>).entries)
            key: value as String,
        },
    ];
    await _undoFiles(record, created, moved);
  }

  Future<void> _undoFiles(
    TransferRecord op,
    Map<String, String> created,
    List<Map<String, String>> moved, {
    bool force = false,
  }) async {
    if (!force) {
      for (final MapEntry(:key, :value) in created.entries) {
        final file = File(key);
        if (await file.exists() && await _hash(file) != value) {
          throw const TransferRefused('Сессию уже продолжили — не отменить');
        }
      }
    }
    final undone = Directory(p.join(op.dir.path, 'undone'));
    for (final (index, path) in created.keys.indexed) {
      final file = File(path);
      if (!await file.exists()) continue;
      final kept = File(p.join(undone.path, '$index-${p.basename(path)}'));
      await kept.parent.create(recursive: true);
      await _move(file, kept);
    }
    for (final entry in moved.reversed) {
      final back = File(entry['from']!);
      final kept = File(entry['to']!);
      if (await kept.exists() && !await back.exists()) {
        await back.parent.create(recursive: true);
        await _move(kept, back);
      }
    }
  }

  Future<TransferRecord> _newOperation() async {
    final now = DateTime.now().toUtc();
    final base = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    // Две операции в одну миллисекунду — не в одну папку.
    for (var n = 0; ; n++) {
      final id = n == 0 ? base : '$base-$n';
      final dir = Directory(p.join(journalRoot.path, id));
      if (await dir.exists()) continue;
      await dir.create(recursive: true);
      return TransferRecord(id: id, dir: dir);
    }
  }

  Future<void> _prune() async {
    try {
      final ops = [
        await for (final entity in journalRoot.list())
          if (entity is Directory) entity,
      ]..sort((a, b) => a.path.compareTo(b.path));
      for (final old in ops.take((ops.length - keep).clamp(0, ops.length))) {
        await old.delete(recursive: true);
      }
    } on FileSystemException {
      // Журнал — подспорье; не убрали — уберём в следующий раз.
    }
  }

  static Future<bool> _hasCli(Directory folder, String cliSessionId) async {
    if (!await folder.exists()) return false;
    await for (final entity in folder.list()) {
      if (entity is! File || !p.basename(entity.path).startsWith('local_')) {
        continue;
      }
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is Map && json['cliSessionId'] == cliSessionId) return true;
      } catch (_) {
        // Недописанная карточка — не та.
      }
    }
    return false;
  }

  static Future<File?> _findTranscript(String configDir, String id) async {
    final projects = Directory(p.join(configDir, 'projects'));
    if (!await projects.exists()) return null;
    await for (final project in projects.list()) {
      if (project is! Directory) continue;
      final file = File(p.join(project.path, '$id.jsonl'));
      if (await file.exists()) return file;
    }
    return null;
  }

  /// Файл или папка [from] в [to]; уже существующее не перезаписывается.
  static Future<void> _copyTree(
    String from,
    String to,
    Map<String, String> created,
  ) async {
    if (await FileSystemEntity.isDirectory(from)) {
      await for (final entity in Directory(
        from,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          await _copyTree(
            entity.path,
            p.join(to, p.relative(entity.path, from: from)),
            created,
          );
        }
      }
      return;
    }
    final target = File(to);
    if (await target.exists()) return;
    await target.parent.create(recursive: true);
    final source = File(from);
    await _writeAtomic(
      target,
      await source.readAsBytes(),
      modified: await source.lastModified(),
    );
    created[target.path] = await _hash(target);
  }

  static Future<void> _writeAtomic(
    File file,
    List<int> bytes, {
    DateTime? modified,
  }) async {
    final tmp = File('${file.path}.claude-launcher-tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (modified != null) await tmp.setLastModified(modified);
    await tmp.rename(file.path);
  }

  static Future<void> _move(File from, File to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      // Другой диск — копией.
      await from.copy(to.path);
      await from.delete();
    }
  }

  static Future<String> _hash(File file) async =>
      '${await sha256.bind(file.openRead()).first}';

  static bool _samePath(String a, String b) =>
      p.equals(p.normalize(a), p.normalize(b));
}
