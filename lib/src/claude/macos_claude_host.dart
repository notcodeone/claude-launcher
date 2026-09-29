import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'claude_host.dart';
import 'command_line.dart';

/// macOS: Claude.app запускается через `open -n` с `--user-data-dir`,
/// закрывается через NSRunningApplication.terminate — это то же самое, что Cmd+Q.
class MacClaudeHost extends ClaudeHost {
  static const _channel = MethodChannel('claude_launcher/native');

  String? _appPath;

  String get _home => Platform.environment['HOME']!;

  @override
  String get profilesBaseDir => p.join(_home, 'Library', 'Application Support');

  @override
  String get defaultDataDir => p.join(profilesBaseDir, 'Claude');

  @override
  Duration get pollInterval => const Duration(seconds: 3);

  @override
  Duration get manualQuitHintAfter => const Duration(seconds: 8);

  @override
  String get manualQuitHint =>
      'Claude не закрывается сам — возможно, он ждёт ответа в своём окне. '
      'Проверьте окно Claude или закройте его через Cmd+Q. '
      'Лаунчер продолжит, как только Claude закроется.';

  @override
  Future<String?> locate() async {
    for (final candidate in [
      '/Applications/Claude.app',
      p.join(_home, 'Applications', 'Claude.app'),
    ]) {
      if (await Directory(candidate).exists()) return _appPath = candidate;
    }
    final found = await Process.run('mdfind', [
      'kMDItemFSName == "Claude.app" && '
          'kMDItemContentType == "com.apple.application-bundle"',
    ]);
    final paths = (found.stdout as String)
        .split('\n')
        .where((line) => line.trim().isNotEmpty);
    return _appPath = paths.isEmpty ? null : paths.first.trim();
  }

  @override
  Future<List<ClaudeInstance>> running() async {
    final result = await Process.run('ps', ['-axww', '-o', 'pid=,command=']);
    if (result.exitCode != 0) {
      throw ProcessException('ps', const [], '${result.stderr}', result.exitCode);
    }
    return [
      for (final line in (result.stdout as String).split('\n'))
        if (parsePsLine(line) case final process?
            when isMacClaudeMainProcess(process.command))
          ClaudeInstance(
            pid: process.pid,
            dataDir: macUserDataDir(process.command),
          ),
    ];
  }

  @override
  Future<void> launch(String? dataDir) async {
    final appPath = _appPath ?? await locate();
    if (appPath == null) throw StateError('Claude не найден');
    final result = await Process.run('open', [
      '-n',
      '-a',
      appPath,
      if (dataDir != null) ...['--args', '--user-data-dir=$dataDir'],
    ]);
    if (result.exitCode != 0) {
      throw ProcessException('open', const [], '${result.stderr}', result.exitCode);
    }
  }

  @override
  Future<void> activate(ClaudeInstance instance) async {
    await _channel.invokeMethod<bool>('activate', {'pid': instance.pid});
  }

  @override
  Future<void> requestQuit(ClaudeInstance instance) async {
    final sent = await _channel.invokeMethod<bool>('terminate', {'pid': instance.pid});
    // Если Apple Event не ушёл, SIGTERM: Electron обрабатывает его как обычный выход.
    if (sent != true) Process.killPid(instance.pid, ProcessSignal.sigterm);
  }
}
