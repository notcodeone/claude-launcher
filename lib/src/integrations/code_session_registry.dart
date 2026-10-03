import 'dart:convert';
import 'dart:io';

import 'claude_code_events.dart';
import 'claude_code_sessions.dart';

/// Recent session references only. Never stores task text, notification text,
/// transcript paths, account credentials or a claim that a task is still active.
class CodeSessionRegistry {
  CodeSessionRegistry(this.file);
  final File file;
  static const capacity = 256;
  static const maxBytes = 256 * 1024;
  static const lifetime = Duration(hours: 1);
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,200}$');
  static final _hostId = RegExp(r'^local_[A-Za-z0-9_-]{1,160}$');
  Future<void> _writing = Future.value();

  Future<List<StoredCodeSession>> load({DateTime? now}) async {
    final time = now ?? DateTime.now();
    if (!await file.exists()) return [];
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > maxBytes) {
      throw const FormatException('Некорректный реестр сессий');
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map || json['version'] != 1 || json['sessions'] is! List) {
      throw const FormatException('Неизвестный формат реестра сессий');
    }
    final items = json['sessions'] as List;
    if (items.length > capacity) {
      throw const FormatException('Слишком большой реестр сессий');
    }
    final found = <String, StoredCodeSession>{};
    final duplicated = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final id = item['sessionId'];
      final hostId = item['hostSessionId'];
      final profileId = item['profileId'];
      if (id is! String ||
          !_id.hasMatch(id) ||
          hostId is! String ||
          !_hostId.hasMatch(hostId) ||
          profileId is! String ||
          !_id.hasMatch(profileId)) {
        continue;
      }
      final started = DateTime.tryParse('${item['startedAt']}');
      final updated = DateTime.tryParse('${item['updatedAt']}');
      if (started == null ||
          updated == null ||
          started.isAfter(updated) ||
          updated.isAfter(time) ||
          time.difference(updated) >= lifetime) {
        continue;
      }
      if (found.containsKey(id)) duplicated.add(id);
      found[id] = StoredCodeSession(id, hostId, profileId, started, updated);
    }
    return [
      for (final entry in found.entries)
        if (!duplicated.contains(entry.key)) entry.value,
    ];
  }

  Future<void> save(Iterable<CodeSession> sessions, {DateTime? now}) {
    final time = now ?? DateTime.now();
    final ordered =
        sessions
            .where(
              (s) =>
                  _id.hasMatch(s.id) &&
                  _hostId.hasMatch(s.hostSessionId) &&
                  _id.hasMatch(s.profileId) &&
                  !s.startedAt.isAfter(s.updatedAt) &&
                  !s.updatedAt.isAfter(time) &&
                  time.difference(s.updatedAt) < lifetime,
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final content = jsonEncode({
      'version': 1,
      'sessions': [
        for (final session in ordered.take(capacity))
          {
            'sessionId': session.id,
            'hostSessionId': session.hostSessionId,
            'profileId': session.profileId,
            'startedAt': session.startedAt.toUtc().toIso8601String(),
            'updatedAt': session.updatedAt.toUtc().toIso8601String(),
          },
      ],
    });
    // Snapshot captured synchronously; serialize writes and allow retry after IO
    // errors. A queued clear must never be overwritten by an earlier snapshot.
    return _writing = _writing.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final tempDir = await file.parent.createTemp('.code-sessions-');
      final temp = File('${tempDir.path}/registry.json');
      try {
        await temp.writeAsString(content, flush: true);
        await temp.rename(file.path);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  }
}

class StoredCodeSession {
  const StoredCodeSession(
    this.id,
    this.hostId,
    this.profileId,
    this.startedAt,
    this.updatedAt,
  );
  final String id;
  final String hostId;
  final String profileId;
  final DateTime startedAt;
  final DateTime updatedAt;

  ClaudeCodeEvent get reference => ClaudeCodeEvent(
    kind: ClaudeCodeEventKind.toolUsed,
    time: updatedAt,
    sessionId: id,
    hostSessionId: hostId,
  );
}
