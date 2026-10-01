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
      'Ответьте в окне Claude или закройте его принудительно. '
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
  Future<String?> commandLineOf(int pid) async {
    final result = await Process.run('ps', [
      '-ww',
      '-o',
      'command=',
      '-p',
      '$pid',
    ]);
    final line = '${result.stdout}'.trim();
    return result.exitCode == 0 && line.isNotEmpty ? line : null;
  }

  @override
  String get updateFeed => 'darwin/universal/squirrel';

  @override
  Future<String?> installedVersion() async {
    final appPath = _appPath ?? await locate();
    return appPath == null ? null : _bundleVersion(appPath);
  }

  /// Распаковывает архив обновления, проверяет подпись — та же команда
  /// разработчика (Team ID), что у установленного Claude, — и меняет
  /// приложение целиком. Старое удаляется, только когда новое на месте.
  @override
  Future<void> installUpdate(File package, String version) async {
    final appPath = _appPath ?? await locate();
    if (appPath == null) throw StateError('Claude не найден');
    final work = await Directory.systemTemp.createTemp('claude-update');
    try {
      await _run('ditto', ['-x', '-k', package.path, work.path]);
      final fresh = p.join(work.path, 'Claude.app');
      if (!await Directory(fresh).exists()) {
        throw StateError('В архиве обновления нет Claude.app');
      }
      if (await _bundleVersion(fresh) != version) {
        throw StateError('В архиве обновления другая версия Claude');
      }
      await _run('codesign', ['--verify', '--deep', '--strict', fresh]);
      final team = await _teamId(fresh);
      if (team == null || team != await _teamId(appPath)) {
        throw StateError('Обновление подписано не тем же разработчиком');
      }
      final old = '$appPath.old';
      if (await Directory(old).exists()) {
        await Directory(old).delete(recursive: true);
      }
      await _run('mv', [appPath, old]);
      try {
        await _run('mv', [fresh, appPath]);
      } catch (_) {
        await _run('mv', [old, appPath]);
        rethrow;
      }
      await Directory(old).delete(recursive: true);
    } finally {
      await work.delete(recursive: true);
    }
  }

  static Future<String?> _bundleVersion(String appPath) async {
    final result = await Process.run('plutil', [
      '-extract',
      'CFBundleShortVersionString',
      'raw',
      p.join(appPath, 'Contents', 'Info.plist'),
    ]);
    final version = (result.stdout as String).trim();
    return result.exitCode == 0 && version.isNotEmpty ? version : null;
  }

  static Future<String?> _teamId(String appPath) async {
    final result = await Process.run('codesign', ['-dv', appPath]);
    return RegExp(
      r'^TeamIdentifier=(\w+)$',
      multiLine: true,
    ).firstMatch('${result.stderr}')?.group(1);
  }

  static Future<void> _run(String command, List<String> args) async {
    final result = await Process.run(command, args);
    if (result.exitCode != 0) {
      throw ProcessException(
        command,
        args,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  @override
  Future<List<ClaudeInstance>> running() async {
    final result = await Process.run('ps', ['-axww', '-o', 'pid=,command=']);
    if (result.exitCode != 0) {
      throw ProcessException(
        'ps',
        const [],
        '${result.stderr}',
        result.exitCode,
      );
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
      throw ProcessException(
        'open',
        const [],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  /// Все процессы Claude.app (и вспомогательные) и Claude Code, который он
  /// ставит в свою папку данных (`…/Claude*/claude-code/…`). Свой Claude Code
  /// пользователя, установленный отдельно, не трогаем.
  @override
  Future<void> killEverything() async {
    await Process.run('pkill', ['-9', '-f', r'/Claude\.app/Contents/']);
    await Process.run('pkill', [
      '-9',
      '-f',
      r'/Application Support/Claude[^/]*/claude-code/',
    ]);
  }

  @override
  Future<void> activate(ClaudeInstance instance) async {
    await _channel.invokeMethod<bool>('activate', {'pid': instance.pid});
  }

  @override
  Future<bool> isFrontmost(ClaudeInstance instance) async =>
      await _channel.invokeMethod<bool>('isFrontmost', {'pid': instance.pid}) ??
      false;

  /// Без `-n` ссылку получает уже запущенный Claude — лаунчер держит открытым
  /// один профиль, так что это [instance].
  @override
  Future<void> openLink(ClaudeInstance instance, Uri link) async {
    final appPath = _appPath ?? await locate();
    if (appPath == null) throw StateError('Claude не найден');
    final result = await Process.run('open', ['-a', appPath, '$link']);
    if (result.exitCode != 0) {
      throw ProcessException(
        'open',
        const [],
        '${result.stderr}',
        result.exitCode,
      );
    }
    await activate(instance);
  }

  /// Настройка AppKit «значок строки меню скрыт». Публичного способа скрыть
  /// значок чужого приложения нет; эту настройку уважают не все приложения,
  /// поэтому в интерфейсе рядом есть кнопка системных настроек.
  static const _statusItemKey = 'NSStatusItem Visible Item-0';

  Future<String> _bundleId() async {
    final appPath = _appPath ?? await locate();
    if (appPath != null) {
      final result = await Process.run('mdls', [
        '-name',
        'kMDItemCFBundleIdentifier',
        '-raw',
        appPath,
      ]);
      final id = (result.stdout as String).trim();
      if (result.exitCode == 0 && id.isNotEmpty && id != '(null)') return id;
    }
    return 'com.anthropic.claudefordesktop';
  }

  @override
  bool get iconChangeNeedsRestart => true;

  @override
  Future<void> setClaudeIconHidden(bool hidden) async {
    final bundleId = await _bundleId();
    if (hidden) {
      await Process.run('defaults', [
        'write',
        bundleId,
        _statusItemKey,
        '-bool',
        'false',
      ]);
    } else {
      // Ключа может не быть — это нормально.
      await Process.run('defaults', ['delete', bundleId, _statusItemKey]);
    }
  }

  @override
  Future<void> openIconSettings() async {
    // «Системные настройки → Строка меню → Разрешить в строке меню».
    await Process.run('open', [
      'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension',
    ]);
  }

  @override
  Future<void> requestQuit(ClaudeInstance instance) async {
    final sent = await _channel.invokeMethod<bool>('terminate', {
      'pid': instance.pid,
    });
    // Если Apple Event не ушёл, SIGTERM: Electron обрабатывает его как обычный выход.
    if (sent != true) Process.killPid(instance.pid, ProcessSignal.sigterm);
  }
}
