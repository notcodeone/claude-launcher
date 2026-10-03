import 'dart:io';

import 'package:claude_launcher/src/claude/bundle_replacement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late String current;
  late String fresh;
  late String backup;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_bundle_swap');
    current = '${dir.path}/Claude.app';
    fresh = '${dir.path}/fresh.app';
    backup = '${dir.path}/old.app';
    for (final entry in {current: 'old', fresh: 'new'}.entries) {
      await Directory(entry.key).create();
      await File('${entry.key}/version').writeAsString(entry.value);
    }
  });
  tearDown(() => dir.delete(recursive: true));

  Future<void> move(String from, String to) async => Directory(from).rename(to);
  BundleReplacement replacement(Future<void> Function(String, String) mover) =>
      BundleReplacement(
        current: current,
        fresh: fresh,
        backup: backup,
        move: mover,
      );

  test('successful replacement permits deleting obsolete backup', () async {
    final swap = replacement(move);
    await swap.replace();
    expect(await File('$current/version').readAsString(), 'new');
    expect(await File('$backup/version').readAsString(), 'old');
    expect(swap.backupPending, isFalse);
  });
  test(
    'failed move restores original and reports installation failure',
    () async {
      final swap = replacement((from, to) async {
        if (from == fresh) {
          throw const FileSystemException('test install failure');
        }
        await move(from, to);
      });
      await expectLater(swap.replace(), throwsA(isA<FileSystemException>()));
      expect(await File('$current/version').readAsString(), 'old');
      expect(swap.backupPending, isFalse);
    },
  );
  test('failed rollback preserves backup and exposes recovery path', () async {
    final swap = replacement((from, to) async {
      if (from == fresh || from == backup) {
        throw const FileSystemException('test failure');
      }
      await move(from, to);
    });
    await expectLater(
      swap.replace(),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains(backup)),
      ),
    );
    expect(await File('$backup/version').readAsString(), 'old');
    expect(swap.backupPending, isTrue);
    expect(await Directory(current).exists(), isFalse);
  });
  test('failure to back up does not start replacement', () async {
    var attempts = 0;
    final swap = replacement((from, to) async {
      attempts++;
      throw const FileSystemException('test backup failure');
    });
    await expectLater(swap.replace(), throwsA(isA<FileSystemException>()));
    expect(attempts, 1);
    expect(await File('$current/version').readAsString(), 'old');
    expect(swap.backupPending, isFalse);
  });
}
