import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'bundle_replacement.dart';
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
  /// приложение целиком. Прежнее уходит во временную папку лаунчера, а не
  /// остаётся рядом в «Программах»; если удалить его не вышло (например,
  /// процесс Claude ещё держал файл), обновление всё равно состоялось —
  /// остаток уберётся в следующий раз.
  @override
  Future<void> installUpdate(File package, String version) async {
    final appPath = _appPath ?? await locate();
    if (appPath == null) throw StateError('Claude не найден');
    final work = Directory(p.join(ClaudeHost.workDir.path, 'claude-install'));
    final recovery = Directory(p.join(work.path, 'Claude-old.app'));
    // Копия от удачной установки, которую не удалось убрать, — не помеха:
    // Claude на месте. Отказываем, только если самого Claude нет.
    if (await recovery.exists() && await _bundleVersion(appPath) != null) {
      await ClaudeHost.removeQuietly(recovery.path);
    }
    if (await recovery.exists()) {
      throw StateError(
        'Сохранена резервная копия Claude после сбоя. Восстановите её перед повторной установкой: ${recovery.path}',
      );
    }
    await ClaudeHost.removeQuietly(work.path);
    // Остаток прежних версий лаунчера, которые оставляли копию рядом.
    await ClaudeHost.removeQuietly('$appPath.old');
    await work.create(recursive: true);
    BundleReplacement? replacement;
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
      replacement = BundleReplacement(
        current: appPath,
        fresh: fresh,
        backup: recovery.path,
        move: (from, to) => _run('mv', [from, to]),
      );
      await replacement.replace();
      _icon = null;
    } finally {
      if (!(replacement?.backupPending ?? false)) {
        await ClaudeHost.removeQuietly(work.path);
      }
    }
  }

  @override
  Future<bool> canLaunchAfterUpdateFailure() async {
    final appPath = _appPath ?? await locate();
    if (appPath == null || await _bundleVersion(appPath) == null) return false;
    try {
      await _run('codesign', ['--verify', '--deep', '--strict', appPath]);
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _icon;

  /// Значок из бандла Claude (icns) — один раз переводим в PNG.
  @override
  Future<String?> iconPath() async {
    if (_icon case final icon? when File(icon).existsSync()) return icon;
    final appPath = _appPath ?? await locate();
    if (appPath == null) return null;
    final name = await _plistValue(appPath, 'CFBundleIconFile');
    if (name == null) return null;
    final icns = p.join(
      appPath,
      'Contents',
      'Resources',
      name.endsWith('.icns') ? name : '$name.icns',
    );
    if (!File(icns).existsSync()) return null;
    final out = p.join(
      ClaudeHost.workDir.path,
      'claude-icon-${await _bundleVersion(appPath)}.png',
    );
    await ClaudeHost.workDir.create(recursive: true);
    final result = await Process.run('sips', [
      '-s',
      'format',
      'png',
      icns,
      '--resampleHeightWidthMax',
      '128',
      '--out',
      out,
    ]);
    return result.exitCode == 0 ? _icon = out : null;
  }

  static Future<String?> _plistValue(String appPath, String key) async {
    final result = await Process.run('plutil', [
      '-extract',
      key,
      'raw',
      p.join(appPath, 'Contents', 'Info.plist'),
    ]);
    final value = (result.stdout as String).trim();
    return result.exitCode == 0 && value.isNotEmpty ? value : null;
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
  Future<void> launch(
    String? dataDir, {
    Map<String, String> environment = const {},
  }) async {
    final appPath = _appPath ?? await locate();
    if (appPath == null) throw StateError('Claude не найден');
    final result = await Process.run('open', [
      '-n',
      // `open` не передаёт своё окружение приложению — только через --env.
      for (final MapEntry(:key, :value) in environment.entries) ...[
        '--env',
        '$key=$value',
      ],
      '-a',
      appPath,
      if (dataDir != null) ...['--args', '--user-data-dir=$dataDir'],
    ]);
    if (result.exitCode != 0 && environment.isNotEmpty) {
      // Старый macOS без `open --env`: запускаем приложение напрямую.
      await Process.start(
        p.join(appPath, 'Contents', 'MacOS', 'Claude'),
        [if (dataDir != null) '--user-data-dir=$dataDir'],
        environment: environment,
        mode: ProcessStartMode.detached,
      );
      return;
    }
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

  /// Активировать мало: закрытое окно Claude только прячет, а показывает его
  /// снова на «открыть ещё раз» — как при нажатии на значок в Dock. В обычном
  /// режиме это `open -a` (открыт один Claude — он и получит); в эксперименте —
  /// то же событие конкретному процессу.
  @override
  Future<void> activate(ClaudeInstance instance) async {
    await _channel.invokeMethod<bool>('activate', {'pid': instance.pid});
    if (parallel) {
      await _channel.invokeMethod<bool>('reopen', {'pid': instance.pid});
      return;
    }
    final appPath = _appPath ?? await locate();
    if (appPath != null) await Process.run('open', ['-a', appPath]);
  }

  @override
  Future<bool> isFrontmost(ClaudeInstance instance) async =>
      await _channel.invokeMethod<bool>('isFrontmost', {'pid': instance.pid}) ??
      false;

  @override
  bool get supportsTargetedLinks => true;

  /// В обычном режиме — `open -a`: открыт один профиль, ссылку получает он, а
  /// разрешение macOS «Автоматизация» не нужно. В эксперименте — Apple Event
  /// конкретному процессу.
  @override
  Future<void> openLink(ClaudeInstance instance, Uri link) async {
    if (!parallel) {
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
      return;
    }
    final bool? delivered;
    try {
      delivered = await _channel.invokeMethod<bool>('openLink', {
        'pid': instance.pid,
        'link': '$link',
      });
    } on PlatformException catch (error) {
      // Текст уже для пользователя (например, как разрешить «Автоматизацию»).
      throw StateError(error.message ?? 'macOS не передала ссылку Claude.');
    }
    if (delivered != true) {
      throw StateError('Выбранный процесс Claude уже закрыт.');
    }
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
