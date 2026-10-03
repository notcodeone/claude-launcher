import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Закрепляет трафик Claude за прокси-затвором лаунчера ([EgressGate]) —
/// официальной настройкой самого Claude `egressProxyUrl`. С ней через прокси
/// должен идти поддержанный трафик Claude и его локальных сред исполнения.
/// Проверка файлов ниже не подтверждает принятие настройки процессом и не
/// является аудитом всех сетевых путей приложения, Code, MCP и Cowork VM. Встроенное обновление Claude прокси не слушает, поэтому
/// на это время оно выключено (`disableAutoUpdates`).
///
/// Настройка читается при запуске Claude из «локальной конфигурации» —
/// библиотеки конфигураций в папке `<папка профиля>-3p` (на Windows —
/// `%LOCALAPPDATA%\Claude-3p`, одна на всех): `configLibrary/_meta.json`
/// называет применённую запись, в ней — настройки. Рядом, в
/// `claude_desktop_config.json`, лаунчер явно ставит обычный режим входа
/// (`deploymentMode: 1p`), чтобы Claude не принял конфигурацию за вход через
/// сторонний шлюз.
///
/// Лаунчер пишет только свою запись и не трогает папку, где уже есть чужая
/// конфигурация: её мог настроить администратор.
class EgressConfig {
  const EgressConfig({this.directoryForProfile});

  /// Also permits testing the shared Windows store without modifying LOCALAPPDATA.
  final String Function(String)? directoryForProfile;
  String _directory(String dataDir) =>
      directoryForProfile?.call(dataDir) ?? configDir(dataDir);

  // Separate objects (UI, guard, cleanup) can access the same Windows store.
  static final _pending = <String, Future<void>>{};
  static Future<T> _serial<T>(String dir, Future<T> Function() action) async {
    final key = Platform.isWindows
        ? p.normalize(dir).toLowerCase()
        : p.normalize(dir);
    final previous = _pending[key];
    final complete = Completer<void>();
    final current = _pending[key] = complete.future;
    try {
      await previous;
      return await action();
    } finally {
      complete.complete();
      if (identical(_pending[key], current)) _pending.remove(key);
    }
  }

  static Future<void> _checkDirectories(String dir) async {
    for (final path in [dir, p.join(dir, 'configLibrary')]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Configuration directory is not a regular directory',
          path,
        );
      }
    }
  }

  /// Своя запись в библиотеке — по ней лаунчер узнаёт, что убирать.
  static const entryId = '6c4e1f8a-2b3d-4c5e-9f70-a1b2c3d4e5f6';
  static const entryName = 'ClaudeLauncher Kill Switch';

  /// Папка локальной конфигурации профиля с папкой данных [dataDir].
  static String configDir(String dataDir) {
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) return p.join(local, 'Claude-3p');
    }
    return '$dataDir-3p';
  }

  /// Пакеты MSIX, под которыми ставится Claude на Windows.
  static const _packageFamilies = [
    'Claude_pzs8sxrjxfjjc',
    'AnthropicPBC.Claude_fnn82j28hfe8t',
  ];

  /// Копии в папке пакета MSIX (`Packages\<пакет>\LocalCache\Local\
  /// Claude-3p`), которые писали версии 1.5.1–1.5.8. Они не нужны: Claude
  /// исключил `%LOCALAPPDATA%\Claude-3p` из виртуализации (манифест пакета)
  /// и читает настоящую папку. Остались — убираем вместе со своей записью.
  static List<String> _legacyMirrors() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || local == null) return const [];
    return [
      for (final family in _packageFamilies)
        p.join(local, 'Packages', family, 'LocalCache', 'Local', 'Claude-3p'),
    ];
  }

  /// Закрепляет профиль за прокси на [port]. false — папка занята чужой
  /// конфигурацией, профиль не защищён.
  Future<bool> pin(String dataDir, int port) async {
    if (port < 1 || port > 65535) return false;
    final dir = _directory(dataDir);
    return _serial(dir, () async {
      try {
        await _checkDirectories(dir);
        if (await _foreign(dir)) return false;
        return await _pinDir(dir, port);
      } catch (error) {
        debugPrint('Kill Switch: конфигурация недоступна: $error');
        return false;
      }
    });
  }

  /// Только выключает встроенное обновление Claude, без прокси: в параллельном
  /// режиме один экземпляр иначе заменил бы приложение под работающим соседом
  /// (Claude ставит скачанное обновление при выходе, в простое без окон и
  /// принудительно через 72 часа). Запись Kill Switch с прокси не ослабляет.
  /// false — папка занята чужой конфигурацией или недоступна.
  Future<bool> holdUpdates(String dataDir) async {
    final dir = _directory(dataDir);
    return _serial(dir, () async {
      try {
        await _checkDirectories(dir);
        if (await _foreign(dir)) return false;
        final current = await _ownEntry(dir);
        if (current != null &&
            current['egressProxyUrl'] != null &&
            current['disableAutoUpdates'] == true) {
          return true;
        }
        return await _pinDir(dir, null);
      } catch (error) {
        debugPrint('Обновления Claude: конфигурация недоступна: $error');
        return false;
      }
    });
  }

  /// Снимает [holdUpdates]. Запись с прокси (Kill Switch) остаётся.
  Future<void> releaseUpdates(String dataDir) async {
    final dir = _directory(dataDir);
    await _serial(dir, () async {
      try {
        await _checkDirectories(dir);
        final current = await _ownEntry(dir);
        if (current == null || current['egressProxyUrl'] != null) return;
        await _unpinDir(dir);
      } catch (error) {
        debugPrint('Обновления Claude: не удалось вернуть их Claude: $error');
      }
    });
  }

  /// Встроенное обновление Claude выключено записью лаунчера (с прокси или без).
  Future<bool> holdsUpdates(String dataDir) async {
    final dir = _directory(dataDir);
    return _serial(dir, () async {
      try {
        await _checkDirectories(dir);
        final entry = await _ownEntry(dir);
        final desktop = await _readJson(
          File(p.join(dir, 'claude_desktop_config.json')),
        );
        return entry?['disableAutoUpdates'] == true &&
            desktop?['deploymentMode'] == '1p';
      } catch (_) {
        return false;
      }
    });
  }

  /// Своя запись, если именно она применена; иначе `null`.
  static Future<Map<String, Object?>?> _ownEntry(String dir) async {
    final library = p.join(dir, 'configLibrary');
    final meta = await _readJson(File(p.join(library, '_meta.json')));
    final entries = meta?['entries'];
    if (meta?['appliedId'] != entryId ||
        entries is! List ||
        entries.length != 1 ||
        entries.single is! Map ||
        (entries.single as Map)['id'] != entryId) {
      return null;
    }
    return _readJson(File(p.join(library, '$entryId.json')));
  }

  /// В папке уже чужая конфигурация — её мог настроить администратор.
  Future<bool> _foreign(String dir) async {
    final meta = await _readJson(
      File(p.join(dir, 'configLibrary', '_meta.json')),
    );
    final entries = meta?['entries'];
    final desktop = await _readJson(
      File(p.join(dir, 'claude_desktop_config.json')),
    );
    return (meta != null &&
            (entries is! List ||
                (meta['appliedId'] != null && meta['appliedId'] != entryId))) ||
        (entries is List &&
            entries.any((e) => e is! Map || e['id'] != entryId)) ||
        desktop?['deploymentMode'] == '3p';
  }

  /// [port] `null` — только удержание обновлений, без прокси.
  Future<bool> _pinDir(String dir, int? port) async {
    final library = Directory(p.join(dir, 'configLibrary'));
    final metaFile = File(p.join(library.path, '_meta.json'));
    final config = File(p.join(dir, 'claude_desktop_config.json'));
    try {
      final desktop = await _readJson(config) ?? <String, Object?>{};
      final entryFile = File(p.join(library.path, '$entryId.json'));
      // An existing malformed file or symlink is not an empty owned record.
      await _readJson(entryFile);
      await library.create(recursive: true);
      await _writeJson(entryFile, {
        if (port != null) 'egressProxyUrl': 'http://127.0.0.1:$port',
        // Обновления Claude качает системой в обход прокси (на macOS —
        // Squirrel), то есть прямо к Anthropic. Пока профиль закреплён, их
        // нет: Claude обновляет лаунчер (ClaudeUpdates).
        'disableAutoUpdates': true,
      });
      await _writeJson(metaFile, {
        'appliedId': entryId,
        'entries': [
          {'id': entryId, 'name': entryName},
        ],
      });
      await _writeJson(config, {...desktop, 'deploymentMode': '1p'});
      return true;
    } catch (error) {
      debugPrint('Kill Switch: не удалось закрепить прокси для $dir: $error');
      return false;
    }
  }

  /// Убирает свою запись — и копии от прежних версий лаунчера.
  Future<void> unpin(String dataDir) async {
    for (final dir in {_directory(dataDir), ..._legacyMirrors()}) {
      await _serial(dir, () => _unpinDir(dir));
    }
  }

  Future<void> _unpinDir(String dir) async {
    final library = Directory(p.join(dir, 'configLibrary'));
    final metaFile = File(p.join(library.path, '_meta.json'));
    try {
      await _checkDirectories(dir);
      final meta = await _readJson(metaFile);
      final entries = meta?['entries'];
      final ours =
          meta?['appliedId'] == entryId &&
          entries is List &&
          entries.length == 1 &&
          entries.single is Map &&
          (entries.single as Map)['id'] == entryId;
      if (!ours) return;
      final entry = File(p.join(library.path, '$entryId.json'));
      if (await entry.exists()) await entry.delete();
      await metaFile.delete();
      if (await library.list().isEmpty) await library.delete();
      // claude_desktop_config.json оставляем: в нём лишь обычный режим входа.
    } catch (error) {
      debugPrint('Kill Switch: не удалось убрать прокси для $dir: $error');
    }
  }

  /// Verify the entire launcher-owned configuration, optionally for this gate's
  /// port. This verifies files, not whether an already running process adopted them.
  Future<bool> isPinned(String dataDir, {int? port}) async {
    final dir = _directory(dataDir);
    return _serial(dir, () async {
      try {
        await _checkDirectories(dir);
        final library = p.join(dir, 'configLibrary');
        final meta = await _readJson(File(p.join(library, '_meta.json')));
        final entries = meta?['entries'];
        if (meta?['appliedId'] != entryId ||
            entries is! List ||
            entries.length != 1 ||
            entries.single is! Map ||
            (entries.single as Map)['id'] != entryId) {
          return false;
        }
        final entry = await _readJson(File(p.join(library, '$entryId.json')));
        final desktop = await _readJson(
          File(p.join(dir, 'claude_desktop_config.json')),
        );
        final url = entry?['egressProxyUrl'];
        if (url is! String ||
            entry?['disableAutoUpdates'] != true ||
            desktop?['deploymentMode'] != '1p') {
          return false;
        }
        final uri = Uri.tryParse(url);
        if (uri == null ||
            uri.scheme != 'http' ||
            uri.host != '127.0.0.1' ||
            !uri.hasPort ||
            uri.port < 1 ||
            uri.port > 65535 ||
            uri.userInfo.isNotEmpty ||
            uri.path.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment) {
          return false;
        }
        return port == null || uri.port == port;
      } catch (_) {
        return false;
      }
    });
  }

  static Future<Map<String, Object?>?> _readJson(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Configuration is not a regular file',
        file.path,
      );
    }
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('Configuration too large');
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, Object?>) {
      throw const FormatException('Configuration must be an object');
    }
    return json;
  }

  static Future<void> _writeJson(File file, Map<String, Object?> json) async {
    final work = await Directory(
      file.parent.path,
    ).createTemp('.launcher-config-');
    try {
      final tmp = File(p.join(work.path, 'record.json'));
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      await tmp.rename(file.path);
    } finally {
      await work.delete(recursive: true);
    }
  }
}
