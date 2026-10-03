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
      await _copyTranscript(cliSessionId, source, target, created);

      // Карточка — последней: пока её нет, Claude цели о сессии не знает.
      await targetDir.create(recursive: true);
      await _writeAtomic(
        targetCard,
        utf8.encode(jsonEncode(cardCopy(json))),
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

  /// Карточка для другого профиля: без тяжёлых данных MCP и без
  /// разрешений, выданных в исходном.
  static Map<String, Object?> cardCopy(Map<String, Object?> json) => {
    for (final MapEntry(:key, :value) in json.entries)
      if (!droppedFields.contains(key)) key: value,
    for (final MapEntry(:key, :value) in resetFields.entries)
      if (json.containsKey(key)) key: value,
  };

  /// Переписка [cliSessionId] и папка подагентов рядом — в папку Claude Code
  /// цели, если у профилей она разная. Уже существующее не перезаписывается.
  static Future<void> _copyTranscript(
    String cliSessionId,
    TransferSide source,
    TransferSide target,
    Map<String, String> created,
  ) async {
    if (_samePath(source.claudeCodeDir, target.claudeCodeDir)) return;
    final transcript = await _findTranscript(
      source.claudeCodeDir,
      cliSessionId,
    );
    if (transcript == null) return;
    final relative = p.relative(transcript.path, from: source.claudeCodeDir);
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

/// Профиль в группе синхронизации.
class SyncMember {
  const SyncMember({
    required this.id,
    required this.side,
    required this.running,
  });

  /// id профиля — ключ группы в состоянии синхронизации.
  final String id;
  final TransferSide side;

  /// Открыт — в него не пишем: Claude переписывает свою папку сессий сам и не
  /// увидит новых сессий до перезапуска. Догоним, когда его закроют.
  final bool running;
}

/// Итог синхронизации — для строки состояния на странице.
class SyncResult {
  SyncResult();

  int copied = 0;
  int updated = 0;
  int removed = 0;

  /// Удаления не выполнены: их слишком много сразу (см. [SessionSync]).
  bool deletionsStopped = false;

  /// Профили, которые не тронули: открыты или аккаунт не определён.
  final skipped = <String>[];

  bool get changed => copied + updated + removed > 0;
}

/// Синхронизация сессий Code внутри группы профилей — в обе стороны, по
/// правилам переноса ([SessionTransfer]):
///
/// - сессии нет в профиле группы — копируется из профиля, где она свежее всех
///   (`lastActivityAt`);
/// - есть, но старее — карточка заменяется свежей (прежняя — в журнал);
/// - сессию удалили в одном профиле (её нет, хотя после прошлой синхронизации
///   она была у всех, или лежит `deleted_…`) — убирается и из остальных, в
///   журнал, не насовсем;
/// - удалений сразу больше 5 и больше 20 % сессий — их не выполняем: похоже на
///   сбой, а не на решение человека;
/// - пишем только в закрытые профили; открытые догоним при их закрытии.
///
/// Что было у всех после прошлого раза — в [stateFile].
class SessionSync {
  SessionSync({required this.transfer, required this.stateFile});

  final SessionTransfer transfer;
  final File stateFile;

  static const _massDeletionCount = 5;
  static const _massDeletionShare = 0.2;

  /// [projects] — только сессии этих папок проектов; `null` — все.
  Future<SyncResult> run(
    List<SyncMember> members, {
    Set<String>? projects,
  }) async {
    final result = SyncResult();
    final key = ([for (final member in members) member.id]..sort()).join('+');
    final state = await _readState();
    final previous = {...?state[key]};

    // Карточки каждого профиля.
    final cards = <SyncMember, Map<String, _Card>>{};
    final deleted = <SyncMember, Set<String>>{};
    for (final member in members) {
      final folder = member.side.identity.sessionsFolder;
      if (folder == null) {
        result.skipped.add(member.side.name);
        continue;
      }
      final (found, markers) = await _read(member.side, folder, projects);
      cards[member] = found;
      deleted[member] = markers;
    }
    final known = cards.keys.toList();
    if (known.length < 2) return result;

    final all = {for (final found in cards.values) ...found.keys};
    // Удалено где-то — было у всех после прошлого раза, а теперь нет; или
    // лежит пометка Claude об удалении.
    final removals = {
      for (final id in all)
        if (known.any(
          (member) =>
              (previous.contains(id) && !cards[member]!.containsKey(id)) ||
              _markedDeleted(deleted[member]!, id, cards),
        ))
          id,
      for (final id in previous)
        if (!all.contains(id)) id,
    };
    final removeNow =
        removals.length > _massDeletionCount &&
            removals.length > all.length * _massDeletionShare
        ? <String>{}
        : removals;
    result.deletionsStopped = removeNow.length != removals.length;

    // Что у кого есть после этого запуска — чтобы знать, что стало общим.
    final present = {
      for (final member in known) member: {...cards[member]!.keys},
    };
    final op = await transfer._newOperation();
    final created = <String, String>{};
    final moved = <Map<String, String>>[];
    try {
      for (final member in known) {
        if (member.running) {
          result.skipped.add(member.side.name);
          continue;
        }
        final folder = Directory(
          p.join(
            member.side.dataDirs.first,
            member.side.identity.sessionsFolder!,
          ),
        );
        for (final id in all) {
          final own = cards[member]![id];
          if (removeNow.contains(id)) {
            if (own == null) continue;
            final kept = File(
              p.join(op.dir.path, 'removed', member.id, '$id.json'),
            );
            await kept.parent.create(recursive: true);
            await SessionTransfer._move(own.file, kept);
            moved.add({'from': own.file.path, 'to': kept.path});
            present[member]!.remove(id);
            result.removed++;
            continue;
          }
          if (removals.contains(id)) continue; // остановлено защитой
          if (deleted[member]!.contains(id)) continue;
          final newest = _newest(cards, id);
          if (newest == null || newest.$1 == member) continue;
          final (from, card) = newest;
          if (own != null && !own.lastActivity.isBefore(card.lastActivity)) {
            continue;
          }
          final target = File(p.join(folder.path, '$id.json'));
          if (own != null) {
            // Прежняя карточка — в журнал: «свежая» могла оказаться не той.
            final kept = File(
              p.join(op.dir.path, 'replaced', member.id, '$id.json'),
            );
            await kept.parent.create(recursive: true);
            await own.file.copy(kept.path);
            moved.add({'from': target.path, 'to': kept.path, 'copy': '1'});
          }
          await SessionTransfer._copyTranscript(
            card.cliSessionId,
            from.side,
            member.side,
            created,
          );
          await folder.create(recursive: true);
          await SessionTransfer._writeAtomic(
            target,
            utf8.encode(jsonEncode(SessionTransfer.cardCopy(card.json))),
            modified: card.lastActivity,
          );
          if (own == null) {
            created[target.path] = await SessionTransfer._hash(target);
            present[member]!.add(id);
            result.copied++;
          } else {
            result.updated++;
          }
        }
      }
    } finally {
      await op.manifest.writeAsString(
        jsonEncode({
          'sync': key,
          'created': created,
          'moved': moved,
          'copied': result.copied,
          'updated': result.updated,
          'removed': result.removed,
        }),
      );
    }

    // Общее теперь — то, что действительно есть у каждого: у открытого
    // профиля недостающего нет, и это не удаление, а «ещё не догнали».
    // Остановленные защитой удаления тоже остаются: иначе в следующий раз их
    // разложили бы обратно — и туда, где их удалили.
    final shared = {
      for (final id in all)
        if (known.every((member) => present[member]!.contains(id))) id,
      for (final id in removals)
        if (!removeNow.contains(id) && previous.contains(id)) id,
    };
    state[key] = shared;
    await _writeState(state);
    if (!result.changed) await op.dir.delete(recursive: true);
    return result;
  }

  static bool _markedDeleted(
    Set<String> markers,
    String id,
    Map<SyncMember, Map<String, _Card>> cards,
  ) {
    if (markers.contains(id)) return true;
    for (final found in cards.values) {
      final cli = found[id]?.cliSessionId;
      if (cli != null && markers.contains(cli)) return true;
    }
    return false;
  }

  static (SyncMember, _Card)? _newest(
    Map<SyncMember, Map<String, _Card>> cards,
    String id,
  ) {
    (SyncMember, _Card)? best;
    for (final MapEntry(key: member, value: found) in cards.entries) {
      final card = found[id];
      if (card == null) continue;
      if (best == null || card.lastActivity.isAfter(best.$2.lastActivity)) {
        best = (member, card);
      }
    }
    return best;
  }

  static Future<(Map<String, _Card>, Set<String>)> _read(
    TransferSide side,
    String folder,
    Set<String>? projects,
  ) async {
    final found = <String, _Card>{};
    final markers = <String>{};
    for (final dir in side.dataDirs) {
      final root = Directory(p.join(dir, folder));
      if (!await root.exists()) continue;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('deleted_')) {
          markers.add(name.substring('deleted_'.length));
          continue;
        }
        if (!name.startsWith('local_') || p.extension(name) != '.json') {
          continue;
        }
        try {
          final json = jsonDecode(await entity.readAsString());
          if (json is! Map<String, Object?> ||
              !SessionTransfer.requiredFields.every(json.containsKey)) {
            continue;
          }
          if (projects != null && !projects.contains(json['cwd'])) continue;
          final id = p.basenameWithoutExtension(name);
          found.putIfAbsent(
            id,
            () => _Card(
              file: entity,
              json: json,
              cliSessionId: json['cliSessionId'] as String,
              lastActivity: DateTime.fromMillisecondsSinceEpoch(
                json['lastActivityAt'] as int,
              ),
            ),
          );
        } catch (_) {
          // Claude как раз пишет карточку — в следующий раз.
        }
      }
    }
    return (found, markers);
  }

  Future<Map<String, Set<String>>> _readState() async {
    try {
      final json = jsonDecode(await stateFile.readAsString());
      if (json is Map) {
        return {
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is List)
              key: {...value.whereType<String>()},
        };
      }
    } on FileSystemException {
      // Ещё не синхронизировали.
    } on FormatException {
      // Испорчен — начнём заново: без него удаления не распространяются.
    }
    return {};
  }

  Future<void> _writeState(Map<String, Set<String>> state) async {
    await stateFile.parent.create(recursive: true);
    await SessionTransfer._writeAtomic(
      stateFile,
      utf8.encode(
        jsonEncode({
          for (final MapEntry(:key, :value) in state.entries)
            key: [...value]..sort(),
        }),
      ),
    );
  }
}

class _Card {
  const _Card({
    required this.file,
    required this.json,
    required this.cliSessionId,
    required this.lastActivity,
  });

  final File file;
  final Map<String, Object?> json;
  final String cliSessionId;
  final DateTime lastActivity;
}
