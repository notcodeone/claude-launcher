import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../http_proxy.dart';
import '../app_settings.dart';
import '../launcher_controller.dart';
import '../location/kill_switch.dart';
import '../profile.dart';
import 'claude_host.dart';

/// Новая версия Claude из его ленты обновлений.
class ClaudeRelease {
  const ClaudeRelease({required this.version, required this.url, this.sha256});

  final String version;
  final Uri url;

  /// Контрольная сумма архива (лента macOS её даёт, Windows — нет: там подпись
  /// пакета проверяет сама система).
  final String? sha256;

  /// Ответ ленты `serverType: json`: `currentRelease` и список выпусков.
  static ClaudeRelease? parse(Object? json) {
    if (json is! Map) return null;
    final current = json['currentRelease'];
    final releases = json['releases'];
    if (current is! String || releases is! List) return null;
    for (final release in releases) {
      if (release is! Map || release['version'] != current) continue;
      final update = release['updateTo'];
      if (update is! Map) continue;
      final url = Uri.tryParse('${update['url']}');
      if (url == null || url.scheme != 'https') return null;
      final sha = update['sha256'];
      return ClaudeRelease(
        version: current,
        url: url,
        sha256: sha is String && sha.isNotEmpty ? sha : null,
      );
    }
    return null;
  }
}

enum ClaudeUpdatePhase { idle, downloading, installing, failed }

/// Обновление Claude, пока включён Kill Switch.
///
/// Встроенное обновление Claude ходит к Anthropic мимо прокси-затвора, поэтому
/// на это время лаунчер его выключает ([EgressConfig]) и обновляет Claude сам —
/// только когда затвор открыт, то есть сеть проверена. Ленту спрашивает так
/// же, как Claude, но со случайным `device_id` — без привязки к устройству.
/// Скачанное обновление проверяет (контрольная сумма, подпись разработчика),
/// закрывает Claude так же, как при переключении, ставит и открывает снова.
class ClaudeUpdates extends ChangeNotifier {
  ClaudeUpdates({
    required this.host,
    required this.launcher,
    required this.killSwitch,
    required this.settings,
    this.checkEvery = const Duration(hours: 2),
    this.feedBase = 'https://api.anthropic.com/api/desktop',
    @visibleForTesting this.downloadOverride,
    @visibleForTesting this._cacheDir,
  });

  final Directory? _cacheDir;

  /// Журнал установки, если он есть: после ошибки по нему видно, что
  /// ответила система.
  String? get installLog => switch (host.installLogPath) {
    final path? when File(path).existsSync() => path,
    _ => null,
  };

  /// Значок установленного Claude (PNG) — для карточки в «Обновлениях».
  String? iconPath;

  final ClaudeHost host;
  final LauncherController launcher;
  final KillSwitch killSwitch;
  final AppSettings settings;
  final Duration checkEvery;
  final String feedBase;

  /// Тесты: откуда качать вместо адреса из ленты.
  final Uri? downloadOverride;

  /// Версия установленного Claude — после проверки.
  String? installed;

  /// Вышла новая версия — её можно поставить.
  ClaudeRelease? available;

  ClaudeUpdatePhase phase = ClaudeUpdatePhase.idle;

  /// Доля скачанного, 0–1; `null` — размер неизвестен.
  double? progress;
  String? error;

  DateTime? _checkedAt;
  bool _checking = false;
  Timer? _timer;

  /// Когда лента ответила в последний раз.
  DateTime? get checkedAt => _checkedAt;

  /// Лента спрашивается прямо сейчас.
  bool get checking => _checking;

  /// Лаунчер обновляет Claude сам: Kill Switch включён, а Claude — такой,
  /// какой лаунчер умеет обновлять.
  bool get active => settings.killSwitch && host.updateFeed != null;

  bool get busy =>
      phase == ClaudeUpdatePhase.downloading ||
      phase == ClaudeUpdatePhase.installing;

  void start() {
    killSwitch.addListener(_maybeCheck);
    settings.addListener(_maybeCheck);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _maybeCheck());
    _maybeCheck();
    unawaited(_loadIcon());
  }

  Future<void> _loadIcon() async {
    try {
      iconPath = await host.iconPath();
      installed ??= await host.installedVersion();
      notifyListeners();
    } catch (error) {
      debugPrint('Не удалось найти значок Claude: $error');
    }
  }

  @override
  void dispose() {
    killSwitch.removeListener(_maybeCheck);
    settings.removeListener(_maybeCheck);
    _timer?.cancel();
    super.dispose();
  }

  void _maybeCheck() {
    if (!active) {
      // Kill Switch выключен — Claude снова обновляется сам; скачанное
      // лаунчером больше не понадобится.
      if (available != null && !busy) {
        available = null;
        unawaited(ClaudeHost.removeQuietly(cacheDir.path));
        notifyListeners();
      }
      return;
    }
    final checkedAt = _checkedAt;
    if (killSwitch.open &&
        !_checking &&
        !busy &&
        (checkedAt == null ||
            DateTime.now().difference(checkedAt) > checkEvery)) {
      unawaited(check());
    }
  }

  /// Спрашивает ленту Claude, вышла ли новая версия. Только через проверенную
  /// сеть: пока затвор закрыт, не спрашивает.
  Future<void> check() async {
    final feed = host.updateFeed;
    if (feed == null || !killSwitch.open || _checking || busy) return;
    _checking = true;
    notifyListeners();
    try {
      final version = installed = await host.installedVersion();
      if (version == null) return;
      final uri = Uri.parse('$feedBase/$feed/update').replace(
        queryParameters: {
          'device_id': _randomId(),
          'version': version,
          'os_version': _osVersion(),
        },
      );
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = launcherProxy
        ..userAgent = 'ClaudeLauncher';
      try {
        final request = await client.getUrl(uri);
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        final body = await response.transform(utf8.decoder).join();
        _checkedAt = DateTime.now();
        if (response.statusCode != 200) return;
        final release = ClaudeRelease.parse(jsonDecode(body));
        available = release != null && isNewer(release.version, version)
            ? release
            : null;
        notifyListeners();
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      debugPrint('Не удалось проверить обновление Claude: $error');
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Скачивает, проверяет и ставит [available]. Открытый Claude закрывается
  /// так же, как при переключении профиля, а после обновления открывается.
  Future<void> install() async {
    final release = available;
    if (release == null || busy) return;
    error = null;
    phase = ClaudeUpdatePhase.downloading;
    progress = 0;
    notifyListeners();
    try {
      final package = await _cachedPackage(release);

      phase = ClaudeUpdatePhase.installing;
      progress = null;
      notifyListeners();
      await launcher.withMaintenance((operation) async {
        await launcher.refresh(strict: true);
        if (launcher.unknownInstances.isNotEmpty) {
          throw StateError(
            'Закройте Claude, открытый вне списка профилей, перед обновлением',
          );
        }
        final reopen = <Profile>[...launcher.runningProfiles];
        final restore = launcher.parallelLaunch
            ? reopen
            : reopen.take(1).toList();
        var installing = false;
        try {
          for (final profile in reopen) {
            final closed = await operation.close(profile);
            if (!closed.succeeded) throw StateError(closed.error!);
          }
          await launcher.refresh(strict: true);
          if (operation.interrupted) {
            throw StateError('Обновление отменено аварийным закрытием Claude');
          }
          if (launcher.instances.isNotEmpty) {
            throw StateError(
              'Claude снова открыт — закройте его и попробуйте снова',
            );
          }
          installing = true;
          await host.installUpdate(package, release.version);
        } catch (installationError) {
          // Before installation the old app is unchanged. Afterwards the host
          // must verify that a usable app survived or was rolled back.
          var safe = !installing;
          if (!safe) {
            try {
              safe = await host.canLaunchAfterUpdateFailure();
            } catch (_) {
              safe = false;
            }
          }
          final recoveryErrors = safe && !operation.interrupted
              ? await _restoreProfiles(operation, restore)
              : <String>[];
          if (recoveryErrors.isNotEmpty) {
            throw StateError(
              '${_errorMessage(installationError)}. '
              'Не восстановлены профили: ${recoveryErrors.join('; ')}',
            );
          }
          rethrow;
        }
        // Keep the installation reservation until every profile is restored.
        installed = release.version;
        available = null;
        await ClaudeHost.removeQuietly(cacheDir.path);
        try {
          iconPath = await host.iconPath();
        } catch (_) {
          iconPath = null;
        }
        final recoveryErrors = operation.interrupted
            ? ['восстановление отменено аварийным закрытием Claude']
            : await _restoreProfiles(operation, restore);
        if (operation.interrupted && recoveryErrors.isEmpty) {
          recoveryErrors.add(
            'восстановление отменено аварийным закрытием Claude',
          );
        }
        if (recoveryErrors.isNotEmpty) {
          throw StateError(
            'Claude обновлён. Не восстановлены профили: ${recoveryErrors.join('; ')}',
          );
        }
      });
      phase = ClaudeUpdatePhase.idle;
      notifyListeners();
    } catch (e) {
      // Без имени класса исключения: «Claude не закрылся — …», а не
      // «Bad state: …».
      error = _errorMessage(e);
      phase = ClaudeUpdatePhase.failed;
      notifyListeners();
    } finally {
      progress = null;
    }
  }

  Future<List<String>> _restoreProfiles(
    LauncherMaintenance operation,
    List<Profile> profiles,
  ) async {
    final failures = <String>[];
    for (final profile in profiles) {
      if (operation.interrupted) break;
      // The profile may have been removed while the installer was running.
      final current = launcher.profiles
          .where((p) => p.id == profile.id)
          .firstOrNull;
      if (current == null) continue;
      final result = await operation.reopen(current);
      if (!result.succeeded) failures.add('«${current.name}»: ${result.error}');
    }
    return failures;
  }

  static String _errorMessage(Object error) => switch (error) {
    StateError(:final message) => message,
    LaunchBlocked(:final message) => message ?? 'Запуск профиля запрещён',
    FileSystemException(:final message, :final path?) => '$message: $path',
    ProcessException(:final message) when message.isNotEmpty => message,
    _ => '$error',
  };

  /// Папка загрузки: в ней не больше одного архива — той версии, что
  /// ставим. После ошибки архив остаётся, и повторная попытка не качает его
  /// снова; после установки папка удаляется.
  Directory get cacheDir =>
      _cacheDir ?? Directory(p.join(ClaudeHost.workDir.path, 'claude-update'));

  /// Готовый к установке архив [release]: уже скачанный и проверенный — или
  /// скачанный сейчас. Всё остальное в папке загрузки удаляется.
  Future<File> _cachedPackage(ClaudeRelease release) async {
    final dir = cacheDir;
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, p.basename(release.url.path)));
    await for (final entity in dir.list()) {
      if (entity.path != file.path) {
        await ClaudeHost.removeQuietly(entity.path);
      }
    }
    // Архив появляется под своим именем, только когда скачан целиком.
    if (await file.exists() && await _matches(file, release)) {
      progress = 1;
      notifyListeners();
      return file;
    }
    final part = File('${file.path}.part');
    try {
      await _download(release, part);
      if (!await _matches(part, release)) {
        throw StateError('Скачанный архив повреждён: не сошлась сумма');
      }
      return await part.rename(file.path);
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  /// Сумма из ленты (на macOS). Без неё (Windows) — архив цел, раз скачан
  /// до конца, а подпись пакета проверит сама система при установке.
  static Future<bool> _matches(File file, ClaudeRelease release) async {
    final expected = release.sha256;
    if (expected == null) return true;
    return '${await sha256.bind(file.openRead()).first}' ==
        expected.toLowerCase();
  }

  /// Скачивает [release] в [file]. Затвор закрылся — сеть сменилась, и
  /// загрузка прерывается: её запросы не должны уйти из непроверенной сети.
  Future<void> _download(ClaudeRelease release, File file) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = launcherProxy
      ..userAgent = 'ClaudeLauncher';
    void abortIfClosed() {
      if (!killSwitch.open) client.close(force: true);
    }

    killSwitch.addListener(abortIfClosed);
    try {
      if (!killSwitch.open) throw StateError('Сеть ещё не проверена');
      final response = await (await client.getUrl(
        downloadOverride ?? release.url,
      )).close();
      if (response.statusCode != 200) {
        throw HttpException('загрузка: HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          if (!killSwitch.open) {
            throw StateError('Сеть сменилась — загрузка прервана');
          }
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final next = received / total;
            if (next - (progress ?? 0) >= 0.01) {
              progress = next;
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
    } on SocketException {
      if (!killSwitch.open) {
        throw StateError('Сеть сменилась — загрузка прервана');
      }
      rethrow;
    } on HttpException {
      if (!killSwitch.open) {
        throw StateError('Сеть сменилась — загрузка прервана');
      }
      rethrow;
    } finally {
      killSwitch.removeListener(abortIfClosed);
      client.close(force: true);
    }
  }

  /// [candidate] новее [current]: `2.16120.0` > `2.16110.0.0`.
  static bool isNewer(String candidate, String current) {
    List<int> parts(String version) => [
      for (final part in version.split('.')) int.tryParse(part) ?? 0,
    ];
    final a = parts(candidate), b = parts(current);
    for (var i = 0; i < max(a.length, b.length); i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static String _randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Версия ОС, как её шлёт Claude: `26.0` на macOS, `10.0.26100` на Windows.
  static String _osVersion() {
    final text = Platform.operatingSystemVersion;
    if (Platform.isWindows) {
      final version = RegExp(r'(\d+\.\d+)').firstMatch(text)?.group(1);
      final build = RegExp(r'Build (\d+)').firstMatch(text)?.group(1);
      if (version != null && build != null) return '$version.$build';
    }
    return RegExp(r'\d+(\.\d+)+').firstMatch(text)?.group(0) ?? text;
  }
}
