import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'claude_code_events.dart';

/// Read-only mapping from Desktop's persisted session metadata. Never infer
/// ownership from cwd, the foreground window, or the last remaining profile.
class CodeProfileResolver {
  const CodeProfileResolver();

  static final _hostId = RegExp(r'^local_[A-Za-z0-9_-]{1,160}$');
  static const _maxRecordBytes = 10 * 1024 * 1024;
  static const _maxDirectories = 1024;

  /// [profileDirs] includes closed profiles: a copied session in two profiles
  /// is ambiguous even when only one of those profiles is currently running.
  Future<String?> resolve(
    ClaudeCodeEvent event,
    Map<String, List<String>> profileDirs,
  ) async {
    if (!_hostId.hasMatch(event.hostSessionId) || event.sessionId.isEmpty) {
      return null;
    }
    final owners = <String>{};
    var directories = 0;
    var complete = true;

    Future<List<Directory>> children(String path) async {
      final result = <Directory>[];
      try {
        // Do not follow symlinks into another profile or arbitrary directories.
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return result;
        if (type != FileSystemEntityType.directory) {
          complete = false;
          return result;
        }
        await for (final child in Directory(path).list(followLinks: false)) {
          if (child is Link) {
            complete = false;
            continue;
          }
          if (child is! Directory) continue;
          if (++directories > _maxDirectories) {
            complete = false;
            break;
          }
          result.add(child);
        }
      } on FileSystemException {
        complete = false;
      }
      return result;
    }

    for (final entry in profileDirs.entries) {
      for (final root in entry.value.toSet()) {
        for (final account in await children(
          p.join(root, 'claude-code-sessions'),
        )) {
          for (final org in await children(account.path)) {
            final file = File(p.join(org.path, '${event.hostSessionId}.json'));
            try {
              final type = await FileSystemEntity.type(
                file.path,
                followLinks: false,
              );
              if (type == FileSystemEntityType.notFound) continue;
              if (type != FileSystemEntityType.file ||
                  await file.length() > _maxRecordBytes) {
                complete = false;
                continue;
              }
              final record = jsonDecode(await file.readAsString());
              if (record is! Map<String, dynamic>) {
                complete = false;
                continue;
              }
              // Both IDs must agree: an imported/stale host record must not
              // claim a different underlying CLI session.
              if (record['sessionId'] == event.hostSessionId &&
                  record['cliSessionId'] == event.sessionId) {
                owners.add(entry.key);
              }
            } on FileSystemException {
              complete = false;
            } on FormatException {
              complete = false;
            }
          }
        }
        if (directories > _maxDirectories) return null;
      }
    }
    return complete && owners.length == 1 ? owners.single : null;
  }
}
