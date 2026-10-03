import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

import 'claude_host.dart';
import 'command_line.dart';
import 'windows_package.dart';
import 'windows_powershell.dart';
import 'windows_window_activation.dart';

/// Windows: Claude ставится пакетом MSIX, путь к `Claude.exe` меняется с каждым
/// обновлением, поэтому ищем его заново перед запуском.
///
/// Стандартный профиль запускаем через пакет (как из меню «Пуск»), чтобы Claude
/// видел свою обычную папку данных. Остальные — прямым запуском `Claude.exe`
/// с `--user-data-dir` в `%APPDATA%`: там её ищет виртуальная машина Cowork.
/// Если Windows прямой запуск запрещает, — тоже через пакет, с аргументами.
///
/// Всё — через API Windows, без PowerShell: из приложения без консоли он
/// запускается ненадёжно, а консольные окна мелькали бы при каждом опросе.
class WindowsClaudeHost extends ClaudeHost {
  _Installation? _installation;

  String get _appData => Platform.environment['APPDATA']!;
  String get _localAppData => Platform.environment['LOCALAPPDATA']!;

  @override
  String get profilesBaseDir => _appData;

  /// Где стандартная папка, решает сам Claude: если %APPDATA% на сетевом
  /// диске (перемещаемые профили в организациях), данные — в
  /// `%LOCALAPPDATA%\Claude-Data`, иначе — в %APPDATA%\Claude, у пакета MSIX
  /// виртуализированном в папку пакета.
  @override
  String get defaultDataDir {
    if (isUnc(_appData) && !isUnc(_localAppData)) {
      return p.join(_localAppData, 'Claude-Data');
    }
    return _roamingDataDir;
  }

  /// Путь на сетевом диске: `\\server\share\…`.
  @visibleForTesting
  static bool isUnc(String path) => path.startsWith(r'\\');

  String get _roamingDataDir => switch (_installation?.familyName) {
    // У пакета MSIX %APPDATA% виртуализирован в папку пакета.
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
  Duration get pollInterval => const Duration(seconds: 3);

  @override
  Duration get manualQuitHintAfter => const Duration(seconds: 6);

  /// При закрытии окна Claude уходит в трей, а попросить его выйти извне
  /// нельзя. Поэтому, если за 5 секунд он не вышел сам (вдруг в настройках
  /// Claude выключена работа в фоне), завершаем его принудительно. Запас — на
  /// случай, когда Claude выходит сам, но не мгновенно: принудительное
  /// завершение обрывает сессии Code и Cowork.
  @override
  Duration get autoForceQuitAfter => const Duration(seconds: 5);

  @override
  String get manualQuitHint =>
      'Claude свернулся в трей и продолжает работать. Закройте его '
      'принудительно или сами: значок Claude в трее (стрелка ▲ у часов) → '
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

  // ------------------------------------------------------------------- поиск

  @override
  List<String> readableDataDirs(ClaudeInstance instance) {
    final dir = dataDirOf(instance);
    final family = _installation?.familyName;
    return [
      dir,
      if (family != null && p.isWithin(_appData, dir))
        p.join(
          _localAppData,
          'Packages',
          family,
          'LocalCache',
          'Roaming',
          p.relative(dir, from: _appData),
        ),
    ];
  }

  @override
  Future<String?> locate() async {
    _installation =
        _locatePackaged() ?? _locateFromRunning() ?? await _locateLegacy();
    return _installation?.exe;
  }

  /// Лаунчер обновляет только Claude из пакета MSIX — им Claude ставится
  /// сейчас; старую установку обновлять не берётся.
  @override
  String? get updateFeed => switch (_installation) {
    _Installation(familyName: _?, :final architecture?)
        when architecture.isNotEmpty =>
      'win32/${architecture.toLowerCase()}/msix',
    _ => null,
  };

  @override
  Future<String?> installedVersion() async {
    if (_installation == null) await locate();
    return _installation?.version;
  }

  /// Значок — логотип пакета MSIX из его манифеста. Файлы лежат с
  /// пометкой масштаба (`Square150x150Logo.scale-200.png`) — берём самый
  /// крупный.
  @override
  Future<String?> iconPath() async {
    if (_installation == null) await locate();
    final root = _installation?.root;
    if (root == null) return null;
    try {
      final manifest = await File(
        p.join(root, 'AppxManifest.xml'),
      ).readAsString();
      final logo =
          RegExp(
            r'Square150x150Logo="([^"]+)"',
          ).firstMatch(manifest)?.group(1) ??
          RegExp(r'<Logo>([^<]+)</Logo>').firstMatch(manifest)?.group(1);
      if (logo == null) return null;
      final path = p.join(root, logo.replaceAll('/', r'\'));
      if (File(path).existsSync()) return path;
      final dir = Directory(p.dirname(path));
      final stem = p.basenameWithoutExtension(path).toLowerCase();
      final variants = [
        for (final file in dir.listSync().whereType<File>())
          if (p.basename(file.path).toLowerCase().startsWith('$stem.') &&
              file.path.toLowerCase().endsWith('.png'))
            file,
      ]..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      return variants.isEmpty ? null : variants.first.path;
    } on FileSystemException {
      return null;
    }
  }

  /// Пакет MSIX ставит сама Windows: она же проверяет подпись Anthropic.
  ///
  /// В пакете Claude — служба (машина Cowork, `packagedServices`), а такие
  /// пакеты Windows обычно ставит только с правами администратора. Поэтому
  /// сначала — обычная установка, а если Windows отказала — та же, но с
  /// повышением прав: Windows спросит разрешение (UAC). Claude к этому моменту
  /// закрыт; на каждую попытку — не больше 10 минут ([WindowsPowerShell]).
  @override
  Future<void> installUpdate(File package, String version) async {
    final work = Directory(p.join(ClaudeHost.workDir.path, 'claude-install'));
    await ClaudeHost.removeQuietly(work.path);
    try {
      // Журнал попыток — во временной папке лаунчера: по нему видно, что
      // ответила Windows, если обновление не встало.
      final log = File(installLogPath);
      await log.parent.create(recursive: true);
      await log.writeAsString(
        '${DateTime.now()} Claude $version: ${package.path}\n',
      );
      final script = installScript(package.path);
      var (_, outcome) = await WindowsPowerShell.run(
        script,
        work: work,
        elevated: false,
        log: log,
      );
      if (!await _installed(version)) {
        final first = outcome;
        (_, outcome) = await WindowsPowerShell.run(
          script,
          work: work,
          elevated: true,
          log: log,
        );
        if (!await _installed(version)) {
          throw StateError(
            'Windows не поставила пакет Claude: $outcome'
            '${first == outcome ? '' : ' (без прав администратора: $first)'}',
          );
        }
      }
    } finally {
      await ClaudeHost.removeQuietly(work.path);
    }
  }

  /// Установка пакета — тело сценария для [WindowsPowerShell.run].
  @visibleForTesting
  static String installScript(String package) =>
      'Add-AppxPackage -Path ${WindowsPowerShell.quote(package)} '
      '-ForceApplicationShutdown';

  @override
  String get installLogPath =>
      p.join(ClaudeHost.workDir.path, 'claude-install.log');

  Future<bool> _installed(String version) async {
    await locate();
    final installed = _installation?.version;
    return installed != null && _atLeast(installed, version);
  }

  static bool _atLeast(String installed, String version) {
    List<int> parts(String v) => [
      for (final part in v.split('.')) int.tryParse(part) ?? 0,
    ];
    final a = parts(installed), b = parts(version);
    for (var i = 0; i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      if (x != b[i]) return x > b[i];
    }
    return true;
  }

  static const _packagesKey =
      r'Software\Classes\Local Settings\Software\Microsoft\Windows'
      r'\CurrentVersion\AppModel\Repository\Packages';

  /// Пакеты Магазина текущего пользователя перечислены в его реестре вместе
  /// с папкой установки (`PackageRootFolder`).
  _Installation? _locatePackaged() {
    final RegistryKey packages;
    try {
      packages = CURRENT_USER.open(_packagesKey);
    } on WindowsException {
      return null;
    }
    final found = <(List<int>, _Installation)>[];
    try {
      for (final fullName in packages.keys) {
        final package = WindowsPackageName.parse(fullName);
        if (package == null || !claudePackageNames.contains(package.name)) {
          continue;
        }
        final root = packages.getString('PackageRootFolder', path: fullName);
        if (root == null) continue;
        final installation = _fromPackageRoot(root, package);
        if (installation != null) found.add((package.version, installation));
      }
    } finally {
      packages.close();
    }
    found.sort((a, b) => compareVersions(a.$1, b.$1));
    return found.isEmpty ? null : found.last.$2;
  }

  /// Запасной путь: если Claude открыт, путь к нему видно по процессу.
  _Installation? _locateFromRunning() {
    for (final process in _claudeProcesses()) {
      if (!process.exe.toLowerCase().contains(r'\windowsapps\')) continue;
      final root = p.dirname(
        p.dirname(process.exe),
      ); // …\<пакет>\app\Claude.exe
      final package = WindowsPackageName.parse(p.basename(root));
      if (package == null) continue;
      final installation = _fromPackageRoot(root, package);
      if (installation != null) return installation;
    }
    return null;
  }

  _Installation? _fromPackageRoot(String root, WindowsPackageName package) {
    final exe = p.join(root, 'app', 'Claude.exe');
    if (!File(exe).existsSync()) return null;
    String? appId;
    try {
      appId = manifestApplicationId(
        File(p.join(root, 'AppxManifest.xml')).readAsStringSync(),
      );
    } on FileSystemException {
      appId = null;
    }
    return _Installation(
      exe: exe,
      familyName: package.familyName,
      appId: appId ?? 'Claude',
      version: package.version.join('.'),
      architecture: package.architecture,
      root: root,
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

  // -------------------------------------------------------------- процессы

  @override
  Future<List<ClaudeInstance>> running() async {
    final instances = <ClaudeInstance>[];
    for (final process in _claudeProcesses()) {
      if (!isClaudeDesktopExe(process.exe)) continue;
      if (process.commandLine.isEmpty) {
        throw StateError(
          'Не удалось прочитать командную строку Claude: принадлежность профилю неизвестна',
        );
      }
      if (!isWindowsChildProcess(process.commandLine)) {
        instances.add(
          ClaudeInstance(
            pid: process.pid,
            dataDir: windowsUserDataDir(process.commandLine),
          ),
        );
      }
    }
    return instances;
  }

  @override
  Future<String?> commandLineOf(int pid) async {
    final handle = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      false,
      pid,
    ).value;
    if (handle.address == 0) return null;
    try {
      return _commandLine(handle);
    } finally {
      CloseHandle(handle);
    }
  }

  /// Все процессы `Claude.exe` текущего пользователя с путём и командной строкой.
  List<({int pid, String exe, String commandLine})> _claudeProcesses() {
    const capacity = 8192;
    final ids = calloc<Uint32>(capacity);
    final needed = calloc<Uint32>();
    final result = <({int pid, String exe, String commandLine})>[];
    try {
      if (!EnumProcesses(ids, capacity * sizeOf<Uint32>(), needed).value) {
        throw StateError('Windows не предоставила список процессов Claude');
      }
      if (needed.value >= capacity * sizeOf<Uint32>()) {
        throw StateError('Список процессов Windows превышает доступный размер');
      }
      final count = needed.value ~/ sizeOf<Uint32>();
      for (var i = 0; i < count; i++) {
        final pid = ids[i];
        if (pid == 0) continue;
        final handle = OpenProcess(
          PROCESS_QUERY_LIMITED_INFORMATION,
          false,
          pid,
        ).value;
        // Чужие и системные процессы открыть нельзя — просто пропускаем.
        if (handle.address == 0) continue;
        try {
          final exe = _imagePath(handle);
          if (exe == null || p.basename(exe).toLowerCase() != 'claude.exe') {
            continue;
          }
          result.add((
            pid: pid,
            exe: exe,
            commandLine: _commandLine(handle) ?? '',
          ));
        } finally {
          CloseHandle(handle);
        }
      }
    } finally {
      calloc.free(ids);
      calloc.free(needed);
    }
    return result;
  }

  String? _imagePath(HANDLE process) {
    const capacity = 1024;
    final buffer = calloc<Uint16>(capacity).cast<Utf16>();
    final size = calloc<Uint32>()..value = capacity;
    try {
      final ok = QueryFullProcessImageName(
        process,
        PROCESS_NAME_WIN32,
        PWSTR(buffer),
        size,
      ).value;
      return ok ? buffer.toDartString(length: size.value) : null;
    } finally {
      calloc.free(buffer);
      calloc.free(size);
    }
  }

  /// Командная строка процесса: `NtQueryInformationProcess` с классом
  /// ProcessCommandLineInformation (60) возвращает UNICODE_STRING
  /// { Length, MaximumLength, Buffer } и сами символы следом в том же буфере.
  String? _commandLine(HANDLE process) {
    const processCommandLineInformation = 60;
    final needed = calloc<Uint32>();
    try {
      _ntQueryInformationProcess(
        process,
        processCommandLineInformation,
        nullptr,
        0,
        needed,
      );
      final size = needed.value;
      if (size == 0) return null;
      final buffer = calloc<Uint8>(size);
      try {
        final status = _ntQueryInformationProcess(
          process,
          processCommandLineInformation,
          buffer,
          size,
          needed,
        );
        if (status != 0) return null;
        final lengthInBytes = buffer.cast<Uint16>().value;
        // Поле Buffer — после двух USHORT и выравнивания до 8 байт.
        final text = Pointer<Pointer<Utf16>>.fromAddress(
          buffer.address + 8,
        ).value;
        return text.toDartString(length: lengthInBytes ~/ 2);
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(needed);
    }
  }

  // ----------------------------------------------------------------- запуск

  @override
  Future<void> launch(String? dataDir) => _start(dataDir);

  /// Стандартный профиль — из пакета MSIX, как из «Пуска»; ссылку ему передаёт
  /// протокол `claude:`, тоже от имени пакета. Остальные — напрямую с папкой.
  Future<void> _start(String? dataDir, {Uri? link}) async {
    final installation = await locate().then((_) => _installation);
    if (installation == null) throw StateError('Claude не найден');

    final aumid = installation.aumid;
    if (dataDir == null && aumid != null) {
      await Process.start('explorer.exe', [
        link?.toString() ?? 'shell:AppsFolder\\$aumid',
      ], mode: ProcessStartMode.detached);
      return;
    }
    final arguments = [
      if (dataDir != null) '--user-data-dir=$dataDir',
      if (link != null) '$link',
    ];
    try {
      await Process.start(
        installation.exe,
        arguments,
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (error) {
      // На части компьютеров Windows не даёт запускать программы из папки
      // пакета напрямую — «Отказано в доступе». Тогда запускаем через пакет.
      if (error.errorCode != ERROR_ACCESS_DENIED || aumid == null) rethrow;
      _activatePackaged(aumid, arguments);
    }
  }

  /// Запуск из пакета, как из «Пуска», но с аргументами командной строки.
  /// Claude работает тогда от имени пакета, и новые файлы в папке профиля
  /// Windows может складывать в папку пакета (`LocalCache\Roaming`), а для
  /// Claude — показывать их на месте.
  void _activatePackaged(String aumid, List<String> arguments) {
    final com = CoInitializeEx(COINIT_APARTMENTTHREADED);
    try {
      final manager = createInstance<IApplicationActivationManager>(
        ApplicationActivationManager,
      );
      try {
        using(
          (arena) => manager.activateApplication(
            arena.pcwstr(aumid),
            // Пути бывают с пробелами; в конце пути обратной косой черты нет.
            arena.pcwstr(arguments.map((argument) => '"$argument"').join(' ')),
            AO_NONE,
          ),
        );
      } finally {
        manager.release();
      }
    } finally {
      // S_FALSE (COM на потоке уже был) тоже требует парного вызова.
      if (com.isOk) CoUninitialize();
    }
  }

  /// Показывает существующее окно по PID, включая скрытое в трее.
  /// Повторный запуск exe не используется: дедупликация зависит от Claude.
  @override
  Future<void> activate(ClaudeInstance instance) async {
    final current = (await running())
        .where((p) => p.pid == instance.pid)
        .firstOrNull;
    if (current == null || !samePath(dataDirOf(current), dataDirOf(instance))) {
      throw StateError('Выбранный процесс Claude уже закрыт или изменился.');
    }
    WindowsWindowActivator(NativeWindowsWindowApi()).activate(instance.pid);
  }

  /// Доставка через повторный запуск и single-instance transport Claude.
  /// При нескольких экземплярах контроллер блокирует этот непроверенный путь.
  @override
  Future<void> openLink(ClaudeInstance instance, Uri link) async {
    AllowSetForegroundWindow(0xFFFFFFFF); // ASFW_ANY
    final dir = dataDirOf(instance);
    await _start(samePath(dir, defaultDataDir) ? null : dir, link: link);
  }

  /// Все процессы Claude (и вспомогательные Electron) и Claude Code, который
  /// он ставит в свою папку данных (`…\Claude*\claude-code\…`). Свой Claude
  /// Code пользователя, установленный отдельно, не трогаем.
  @override
  Future<void> killEverything() async {
    final bundledCode = RegExp(
      r'\\claude[^\\]*\\claude-code\\',
      caseSensitive: false,
    );
    for (final process in _claudeProcesses()) {
      if (isClaudeDesktopExe(process.exe) ||
          bundledCode.hasMatch(process.exe)) {
        Process.killPid(process.pid);
      }
    }
  }

  /// Окна Electron принадлежат главному процессу — сравниваем с ним.
  @override
  Future<bool> isFrontmost(ClaudeInstance instance) async {
    final ownerPid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(GetForegroundWindow(), ownerPid);
      return ownerPid.value == instance.pid;
    } finally {
      calloc.free(ownerPid);
    }
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

  // ------------------------------------------------------------ значок в трее

  @override
  bool get iconChangeNeedsRestart => false;

  static const _notifyIconsKey = r'Control Panel\NotifyIconSettings';

  /// Windows 11 хранит видимость значков трея в реестре пользователя:
  /// `IsPromoted = 0` — значок под стрелкой ▲, `1` — на панели задач.
  /// Путь к Claude.exe меняется с версиями, поэтому правим все его записи.
  ///
  /// Запись появляется, только когда Claude впервые показал значок, а после
  /// обновления Claude — новая, по новому пути. Поэтому лаунчер вызывает это
  /// снова, пока Claude открыт ([ClaudeIconKeeper]); пишем, только если
  /// значение другое.
  @override
  Future<void> setClaudeIconHidden(bool hidden) async {
    final RegistryKey root;
    try {
      root = CURRENT_USER.open(_notifyIconsKey);
    } on WindowsException {
      return; // Windows 10: такого раздела нет.
    }
    try {
      for (final id in root.keys) {
        final exe = root.getString('ExecutablePath', path: id) ?? '';
        if (!isClaudeDesktopExe(exe)) continue;
        final icon = root.open(
          id,
          config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
        );
        try {
          final want = hidden ? 0 : 1;
          if (icon.getInt('IsPromoted') != want) {
            icon.setValue('IsPromoted', RegistryValue.dword(want));
          }
        } finally {
          icon.close();
        }
      }
    } finally {
      root.close();
    }
  }

  @override
  Future<void> openIconSettings() async {
    await Process.start('explorer.exe', [
      'ms-settings:taskbar',
    ], mode: ProcessStartMode.detached);
  }
}

/// `NtQueryInformationProcess` нет в пакете win32 — подключаем из ntdll сами.
/// Поле верхнего уровня ленивое: на macOS библиотека не загружается.
final _ntQueryInformationProcess = DynamicLibrary.open('ntdll.dll')
    .lookupFunction<
      Int32 Function(Pointer, Uint32, Pointer, Uint32, Pointer<Uint32>),
      int Function(Pointer, int, Pointer, int, Pointer<Uint32>)
    >('NtQueryInformationProcess');

class _Installation {
  const _Installation({
    required this.exe,
    this.familyName,
    this.appId,
    this.version,
    this.architecture,
    this.root,
  });

  final String exe;
  final String? familyName;
  final String? appId;

  /// Версия пакета MSIX: `2.16120.0.0`.
  final String? version;

  /// Архитектура пакета: лаунчер собран под x64 и на ARM работает в
  /// эмуляции, поэтому берём её у самого Claude, а не у себя.
  final String? architecture;

  /// Папка пакета MSIX — в ней манифест и логотипы.
  final String? root;

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
  return compareVersions(parts(a), parts(b));
}
