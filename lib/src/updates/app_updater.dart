import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../app_settings.dart';

/// Выпуск на GitHub.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.page,
    required this.assets,
  });

  final String version;
  final Uri page;

  /// Имя файла → ссылка на скачивание.
  final Map<String, Uri> assets;

  /// Ответ `GET /repos/<repo>/releases/latest`. Тег — `vX.Y.Z`.
  static AppRelease? fromJson(Object? json) {
    if (json is! Map || json['draft'] == true || json['prerelease'] == true) {
      return null;
    }
    final tag = json['tag_name'];
    final page = Uri.tryParse('${json['html_url']}');
    if (tag is! String || page == null) return null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (parseVersion(version) == null) return null;
    return AppRelease(
      version: version,
      page: page,
      assets: {
        for (final asset in json['assets'] as List? ?? const [])
          if (asset case {
            'name': final String name,
            'browser_download_url': final String url,
          })
            if (Uri.tryParse(url) case final uri? when uri.scheme == 'https')
              name: uri,
      },
    );
  }

  /// Установщик для этой ОС; null — обновить можно только вручную.
  Uri? get installer => Platform.isMacOS
      ? assets['ClaudeLauncher-$version.dmg']
      : Platform.isWindows
      ? assets['ClaudeLauncher-Setup-$version.exe']
      : null;
}

/// «1.2.10» → [1, 2, 10]; null — не номер версии.
List<int>? parseVersion(String version) {
  final parts = version.split('+').first.split('.');
  if (parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  return numbers.contains(null) ? null : numbers.cast<int>();
}

bool isNewerVersion(String candidate, String current) {
  final a = parseVersion(candidate), b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

enum UpdatePhase { idle, available, downloading, installing, failed }

/// Обновление лаунчера из выпусков GitHub. Лаунчер скачивает установщик сам,
/// поэтому на файле нет пометки «скачано из интернета» — и macOS (Gatekeeper),
/// и Windows (SmartScreen) открывают новую версию без предупреждения.
///
/// macOS: DMG → копия приложения рядом с текущим → выход лаунчера → скрипт
/// заменяет приложение и запускает новое. Windows: тихий запуск установщика,
/// который после установки сам запускает лаунчер.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    required this.currentVersion,
    required this.settings,
    required this.quit,
  });

  static const repo = 'notcodeone/claude-launcher';
  static const _checkEvery = Duration(hours: 6);

  final String currentVersion;
  final AppSettings settings;

  /// Обычный выход лаунчера: возвращает Claude уведомления и завершает процесс.
  final Future<void> Function() quit;

  UpdatePhase phase = UpdatePhase.idle;
  AppRelease? release;

  /// Доля скачанного, 0–1; null — размер неизвестен.
  double? progress;
  String? error;

  /// Идёт проверка — для пункта меню «Проверяю обновления…».
  bool checking = false;

  /// Последняя проверка ответила, что новее версии нет.
  DateTime? upToDateAt;

  Timer? _timer;
  Timer? _retry;
  DateTime? _checkedAt;

  /// Когда GitHub последний раз ответил на проверку.
  DateTime? get checkedAt => _checkedAt;

  static const _retryAfter = Duration(minutes: 5);
  static const _staleAfter = Duration(minutes: 10);

  /// Проверяет сейчас и затем раз в 6 часов, пока проверка включена.
  void start() {
    unawaited(_removeLeftovers());
    _timer?.cancel();
    _timer = Timer.periodic(_checkEvery, (_) => check());
    Timer(const Duration(seconds: 15), check);
    _checkUpdates = settings.checkUpdates;
    settings.addListener(_onSettings);
  }

  bool _checkUpdates = true;

  /// Проверку включили в настройках — проверяем сразу.
  void _onSettings() {
    if (settings.checkUpdates && !_checkUpdates) check();
    _checkUpdates = settings.checkUpdates;
  }

  /// Установщик Windows не может удалить себя сам, а на macOS скрипт мог не
  /// успеть: убираем папки прошлых обновлений, если им больше часа.
  static Future<void> _removeLeftovers() async {
    try {
      await for (final entry in Directory.systemTemp.list()) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('claude-launcher-update')) {
          continue;
        }
        final age = DateTime.now().difference((await entry.stat()).modified);
        if (age > const Duration(hours: 1)) await entry.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Не удалось убрать файлы прошлого обновления: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _retry?.cancel();
    settings.removeListener(_onSettings);
    super.dispose();
  }

  /// Окно открыли: если с прошлой проверки прошло больше 10 минут — проверяем.
  void checkIfStale() {
    final checkedAt = _checkedAt;
    if (checkedAt == null ||
        DateTime.now().difference(checkedAt) > _staleAfter) {
      check();
    }
  }

  /// [manual] — по пункту меню: проверяет, даже если автоматическая проверка
  /// выключена в настройках.
  Future<void> check({bool manual = false}) async {
    if (checking || (!manual && !settings.checkUpdates)) return;
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.installing) {
      return;
    }
    _retry?.cancel();
    checking = true;
    notifyListeners();
    try {
      final latest = await _latest();
      _checkedAt = DateTime.now();
      if (isNewerVersion(latest.version, currentVersion)) {
        // Новый выпуск — прежняя причина «обновите вручную» к нему не относится.
        if (latest.version != release?.version) error = null;
        release = latest;
        upToDateAt = null;
        if (phase != UpdatePhase.failed) phase = UpdatePhase.available;
      } else {
        upToDateAt = _checkedAt;
        // Подпись «Обновлений нет» в меню — на минуту.
        Timer(const Duration(minutes: 1, seconds: 1), notifyListeners);
      }
    } catch (e) {
      // Нет сети, GitHub ограничил запросы (60 в час без входа) — повторим
      // через 5 минут, а не через 6 часов.
      debugPrint('Не удалось проверить обновления: $e');
      _retry = Timer(_retryAfter, check);
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<AppRelease> _latest() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.https('api.github.com', '/repos/$repo/releases/latest'),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'ClaudeLauncher/$currentVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('GitHub ответил ${response.statusCode}');
      }
      return AppRelease.fromJson(jsonDecode(body)) ??
          (throw const FormatException('Непонятный ответ GitHub'));
    } finally {
      client.close();
    }
  }

  /// Скачивает и ставит новую версию. Если здесь так не обновиться (лаунчер
  /// запущен не из «Программ» или переносная версия Windows), открывает
  /// страницу выпуска.
  Future<void> install() async {
    final known = this.release;
    if (known == null) return;
    var release = known;
    // Выпуск могли увидеть в первые минуты публикации, пока установщик ещё
    // не загружен, — спросим GitHub ещё раз.
    if (release.installer == null) {
      try {
        final latest = await _latest();
        if (latest.version == release.version) {
          this.release = latest;
          release = latest;
        }
      } catch (e) {
        debugPrint('Не удалось обновить сведения о выпуске: $e');
      }
    }
    final installer = release.installer;
    final target = Platform.isMacOS ? _macBundle() : _windowsInstalledExe();
    if (installer == null || target == null) {
      // Обновиться самим нельзя — объясняем почему и ведём на страницу.
      error = installer == null
          ? 'в выпуске ${release.version} нет установщика для этой системы'
          : Platform.isMacOS
          ? 'лаунчер запущен не из «Программ» (${Platform.resolvedExecutable})'
          : 'лаунчер не установлен установщиком — это переносная версия '
                '(${p.dirname(Platform.resolvedExecutable)})';
      notifyListeners();
      await launchUrl(release.page);
      return;
    }
    phase = UpdatePhase.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('claude-launcher-update');
      final file = File(p.join(temp.path, p.basename(installer.path)));
      await _download(installer, file);
      phase = UpdatePhase.installing;
      notifyListeners();
      if (Platform.isMacOS) {
        await _installMac(file, target, release.version, temp);
      } else {
        await _installWindows(file);
      }
      await quit();
    } catch (e) {
      phase = UpdatePhase.failed;
      error = '$e';
      notifyListeners();
      try {
        await temp?.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _download(Uri url, File file) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(url);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'ClaudeLauncher/$currentVersion',
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('GitHub ответил ${response.statusCode}', uri: url);
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          final next = total > 0 ? received / total : null;
          // Обновляем подпись не чаще, чем на процент.
          if (next == null || progress == null || next - progress! >= 0.01) {
            progress = next;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw const HttpException('Файл скачался не полностью');
      }
    } finally {
      client.close();
    }
  }

  /// Приложение, которое сейчас запущено, — если его можно заменить: это
  /// `.app` в папке, куда можно писать (обычно «Программы»).
  static String? _macBundle() {
    final exe = Platform.resolvedExecutable; // …/X.app/Contents/MacOS/X
    final bundle = p.dirname(p.dirname(p.dirname(exe)));
    if (!bundle.endsWith('.app') || bundle.startsWith('/Volumes/')) return null;
    final parent = p.dirname(bundle);
    final probe = File(p.join(parent, '.claude-launcher-write-test'));
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return bundle;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _installMac(
    File dmg,
    String bundle,
    String version,
    Directory temp,
  ) async {
    final mount = p.join(temp.path, 'mnt');
    await _run('hdiutil', [
      'attach',
      dmg.path,
      '-nobrowse',
      '-readonly',
      '-noautoopen',
      '-mountpoint',
      mount,
    ]);
    // Копия — рядом с приложением: на том же диске замена — переименование.
    final staged = p.join(p.dirname(bundle), '.ClaudeLauncher-update.app');
    try {
      await _run('rm', ['-rf', staged]);
      await _run('ditto', [p.join(mount, 'ClaudeLauncher.app'), staged]);
    } finally {
      await Process.run('hdiutil', ['detach', mount, '-quiet']);
    }
    final stagedVersion = (await _run('plutil', [
      '-extract',
      'CFBundleShortVersionString',
      'raw',
      '-o',
      '-',
      p.join(staged, 'Contents', 'Info.plist'),
    ])).trim();
    if (stagedVersion != version) {
      await _run('rm', ['-rf', staged]);
      throw StateError('В образе версия $stagedVersion, ожидалась $version');
    }
    // Ждёт выхода лаунчера, заменяет приложение и запускает новое.
    // Перерегистрация в Launch Services — чтобы значок в уведомлениях и Dock
    // брался у новой версии, а не у временной копии.
    const script = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
rm -rf "$2" && mv "$3" "$2"
xattr -cr "$2" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$2" 2>/dev/null
open "$2"
rm -rf "$4"
''';
    await Process.start('/bin/sh', [
      '-c',
      script,
      'update',
      '$pid',
      bundle,
      staged,
      temp.path,
    ], mode: ProcessStartMode.detached);
  }

  /// Установленная версия Windows: `%LOCALAPPDATA%\Programs\ClaudeLauncher`.
  /// Лаунчер поставлен установщиком — рядом с exe его деинсталлятор
  /// (`unins000.exe`). Папка может быть любой: обновление сохраняет прежнюю,
  /// в том числе «Claude Launcher» до переименования. Без деинсталлятора —
  /// portable-версия: её лаунчер не обновляет, только ведёт на страницу выпуска.
  static String? _windowsInstalledExe() {
    final exe = Platform.resolvedExecutable;
    try {
      final installed = Directory(p.dirname(exe)).listSync().any(
        (entity) => RegExp(
          r'^unins\d{3}\.exe$',
          caseSensitive: false,
        ).hasMatch(p.basename(entity.path)),
      );
      return installed ? exe : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Лаунчер обновит себя сам; false — только скачать со страницы выпуска
  /// (portable-версия на Windows, приложение не из «Программ» на macOS).
  bool get selfUpdates =>
      release?.installer != null &&
      (Platform.isMacOS ? _macBundle() : _windowsInstalledExe()) != null;

  /// Подпись кнопки: «Обновить до 1.6.0» или «Скачать 1.6.0».
  String get actionLabel => selfUpdates
      ? 'Обновить до ${release?.version}'
      : 'Скачать ${release?.version}';

  /// Установщик ждёт выхода лаунчера (`/update=1`, см. claude_launcher.iss),
  /// ставит тихо и запускает новую версию; если не вышло — прежнюю
  /// (`/relaunch`). Журнал — `%TEMP%\ClaudeLauncher-update.log`.
  Future<void> _installWindows(File setup) async {
    await Process.start(setup.path, [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/update=1',
      '/relaunch=${Platform.resolvedExecutable}',
      '/LOG=${p.join(Directory.systemTemp.path, 'ClaudeLauncher-update.log')}',
    ], mode: ProcessStartMode.detached);
  }

  static Future<String> _run(String command, List<String> arguments) async {
    final result = await Process.run(command, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        command,
        arguments,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return '${result.stdout}';
  }
}
