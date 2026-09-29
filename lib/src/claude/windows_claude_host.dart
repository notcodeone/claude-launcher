import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'claude_host.dart';
import 'command_line.dart';

/// Windows: Claude ставится пакетом MSIX, путь к `Claude.exe` меняется с каждым
/// обновлением, поэтому ищем его заново перед запуском.
///
/// Стандартный профиль запускаем через пакет (как из меню «Пуск»), чтобы Claude
/// видел свою обычную папку данных. Остальные — прямым запуском `Claude.exe`
/// с `--user-data-dir` в `%APPDATA%`: там её ищет виртуальная машина Cowork.
class WindowsClaudeHost extends ClaudeHost {
  _Installation? _installation;

  String get _appData => Platform.environment['APPDATA']!;
  String get _localAppData => Platform.environment['LOCALAPPDATA']!;

  @override
  String get profilesBaseDir => _appData;

  @override
  String get defaultDataDir => switch (_installation?.familyName) {
    final family? => p.join(
      _localAppData,
      'Packages',
      family,
      'LocalCache',
      'Roaming',
      'Claude',
    ),
    null => p.join(_appData, 'Claude'),
  };

  @override
  Duration get pollInterval => const Duration(seconds: 5);

  @override
  Duration get manualQuitHintAfter => const Duration(seconds: 4);

  @override
  String get manualQuitHint =>
      'Похоже, Claude свернулся в трей и продолжает работать. '
      'Закройте его сами: значок Claude в трее (стрелка ▲ у часов) → '
      'правая кнопка мыши → Quit. Лаунчер продолжит, как только Claude закроется.';

  @override
  String dataDirOf(ClaudeInstance instance) {
    final dir = instance.dataDir;
    // Изнутри пакета стандартная папка выглядит как %APPDATA%\Claude.
    if (dir == null || samePath(dir, p.join(_appData, 'Claude'))) {
      return defaultDataDir;
    }
    return dir;
  }

  @override
  Future<String?> locate() async {
    _installation = await _locatePackaged() ?? await _locateLegacy();
    return _installation?.exe;
  }

  Future<_Installation?> _locatePackaged() async {
    final json = await _powershell(r'''
$result = $null
$pkg = Get-AppxPackage -Name 'Claude*' |
  Where-Object { Test-Path (Join-Path $_.InstallLocation 'app\Claude.exe') } |
  Sort-Object Version -Descending | Select-Object -First 1
if ($pkg) {
  $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application |
    Select-Object -First 1 -ExpandProperty Id
  $result = @{
    exe = (Join-Path $pkg.InstallLocation 'app\Claude.exe')
    familyName = $pkg.PackageFamilyName
    appId = $appId
  }
}
$result
''');
    if (json is! Map<String, Object?>) return null;
    return _Installation(
      exe: json['exe'] as String,
      familyName: json['familyName'] as String?,
      appId: json['appId'] as String?,
    );
  }

  /// Старая установка (до MSIX): %LOCALAPPDATA%\AnthropicClaude\app-<версия>\claude.exe.
  Future<_Installation?> _locateLegacy() async {
    final root = Directory(p.join(_localAppData, 'AnthropicClaude'));
    if (!await root.exists()) return null;
    final versions = [
      await for (final entry in root.list())
        if (entry is Directory && p.basename(entry.path).startsWith('app-'))
          entry.path,
    ]..sort(_compareVersionDirs);
    for (final dir in versions.reversed) {
      final exe = File(p.join(dir, 'claude.exe'));
      if (await exe.exists()) return _Installation(exe: exe.path);
    }
    return null;
  }

  @override
  Future<List<ClaudeInstance>> running() async {
    final json = await _powershell(r'''
@(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" |
  Select-Object ProcessId, ExecutablePath, CommandLine)
''');
    final processes = switch (json) {
      final List<Object?> list => list,
      final Map<String, Object?> single => [single],
      _ => const <Object?>[],
    };
    return [
      for (final process in processes.cast<Map<String, Object?>>())
        if (_isClaudeDesktopMain(process))
          ClaudeInstance(
            pid: process['ProcessId'] as int,
            dataDir: windowsUserDataDir(
              process['CommandLine'] as String? ?? '',
            ),
          ),
    ];
  }

  /// Отсекаем вспомогательные процессы Electron и одноимённый `claude.exe` от Claude Code CLI.
  bool _isClaudeDesktopMain(Map<String, Object?> process) {
    final exe = (process['ExecutablePath'] as String? ?? '').toLowerCase();
    final commandLine = process['CommandLine'] as String? ?? '';
    final isDesktop =
        exe.contains(r'\windowsapps\claude_') ||
        exe.contains(r'\anthropicclaude\');
    return isDesktop && !isWindowsChildProcess(commandLine);
  }

  @override
  Future<void> launch(String? dataDir) async {
    final installation = await locate().then((_) => _installation);
    if (installation == null) throw StateError('Claude не найден');

    final aumid = installation.aumid;
    if (dataDir == null && aumid != null) {
      await Process.start('explorer.exe', [
        'shell:AppsFolder\\$aumid',
      ], mode: ProcessStartMode.detached);
      return;
    }
    await Process.start(installation.exe, [
      if (dataDir != null) '--user-data-dir=$dataDir',
    ], mode: ProcessStartMode.detached);
  }

  @override
  bool get iconChangeNeedsRestart => false;

  /// Windows 11 хранит видимость значков трея в реестре пользователя:
  /// `IsPromoted = 0` — значок под стрелкой ▲, `1` — на панели задач.
  /// Путь к Claude.exe меняется с версиями, поэтому правим все его записи.
  @override
  Future<void> setClaudeIconHidden(bool hidden) async {
    await _powershell('''
\$root = 'HKCU:\\Control Panel\\NotifyIconSettings'
if (Test-Path \$root) {
  Get-ChildItem \$root | ForEach-Object {
    \$exe = (Get-ItemProperty \$_.PSPath).ExecutablePath
    if (\$exe -like '*\\WindowsApps\\Claude_*' -or \$exe -like '*\\AnthropicClaude\\*') {
      Set-ItemProperty -Path \$_.PSPath -Name IsPromoted -Value ${hidden ? 0 : 1} -Type DWord
    }
  }
}
\$null
''');
  }

  @override
  Future<void> openIconSettings() async {
    await Process.start('explorer.exe', [
      'ms-settings:taskbar',
    ], mode: ProcessStartMode.detached);
  }

  /// Повторный запуск с той же папкой: Claude держит блокировку «один экземпляр
  /// на папку», поэтому новый процесс сразу завершится, а открытый покажет окно.
  @override
  Future<void> activate(ClaudeInstance instance) async {
    AllowSetForegroundWindow(0xFFFFFFFF); // ASFW_ANY
    final dir = dataDirOf(instance);
    await launch(samePath(dir, defaultDataDir) ? null : dir);
  }

  /// Как нажатие на крестик: WM_CLOSE видимым окнам. Если Claude при этом
  /// сворачивается в трей, контроллер попросит закрыть его вручную.
  @override
  Future<void> requestQuit(ClaudeInstance instance) async {
    for (final window in _visibleWindowsOf(instance.pid)) {
      PostMessage(window, WM_CLOSE, const WPARAM(0), const LPARAM(0));
    }
  }

  List<HWND> _visibleWindowsOf(int pid) {
    final windows = <HWND>[];
    final ownerPid = calloc<Uint32>();
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      Pointer handle,
      int _,
    ) {
      final window = HWND(handle);
      GetWindowThreadProcessId(window, ownerPid);
      if (ownerPid.value == pid && IsWindowVisible(window)) windows.add(window);
      return TRUE;
    }, exceptionalReturn: FALSE);
    try {
      EnumWindows(callback.nativeFunction, const LPARAM(0));
    } finally {
      callback.close();
      calloc.free(ownerPid);
    }
    return windows;
  }

  /// Запускает PowerShell без окна консоли. Скрипт передаётся через
  /// -EncodedCommand, результат — JSON в Base64, чтобы не зависеть от кодировок.
  Future<Object?> _powershell(String script) async {
    final wrapped =
        '\$ErrorActionPreference = "Stop"\n'
        '\$value = & {\n$script\n}\n'
        '\$json = ConvertTo-Json -Compress -Depth 4 -InputObject \$value\n'
        '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]\$json))';
    final encoded = base64Encode([
      for (final unit in wrapped.codeUnits) ...[unit & 0xFF, unit >> 8],
    ]);
    // detachedWithStdio: консольный процесс без собственного окна, но с доступом к выводу.
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encoded,
    ], mode: ProcessStartMode.detachedWithStdio);
    final errors = process.stderr.transform(utf8.decoder).join();
    final output = (await process.stdout.transform(utf8.decoder).join()).trim();
    if (output.isEmpty) {
      throw ProcessException('powershell.exe', const [], await errors);
    }
    final json = utf8.decode(base64Decode(output));
    return json.isEmpty ? null : jsonDecode(json);
  }
}

class _Installation {
  const _Installation({required this.exe, this.familyName, this.appId});

  final String exe;
  final String? familyName;
  final String? appId;

  String? get aumid =>
      familyName != null && appId != null ? '$familyName!$appId' : null;
}

int _compareVersionDirs(String a, String b) {
  List<int> parts(String path) => p
      .basename(path)
      .substring('app-'.length)
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final left = parts(a), right = parts(b);
  for (var i = 0; i < left.length && i < right.length; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return left.length.compareTo(right.length);
}
