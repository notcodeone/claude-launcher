import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Закрепляет трафик Claude за прокси-затвором лаунчера ([EgressGate]) —
/// официальной настройкой самого Claude `egressProxyUrl`. С ней через прокси
/// идут приложение, движок Claude Code (он получает `HTTPS_PROXY`) и, на macOS
/// и Windows, машина Cowork. Если прокси недоступен, Claude не идёт в обход, а
/// остаётся без сети. Встроенное обновление Claude прокси не слушает, поэтому
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
  const EgressConfig();

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
    final dir = configDir(dataDir);
    if (await _foreign(dir)) return false;
    return _pinDir(dir, port);
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
    return (entries is List &&
            entries.any((e) => e is Map && e['id'] != entryId)) ||
        desktop?['deploymentMode'] == '3p';
  }

  Future<bool> _pinDir(String dir, int port) async {
    final library = Directory(p.join(dir, 'configLibrary'));
    final metaFile = File(p.join(library.path, '_meta.json'));
    final config = File(p.join(dir, 'claude_desktop_config.json'));
    try {
      final desktop = await _readJson(config) ?? <String, Object?>{};
      await library.create(recursive: true);
      await _writeJson(File(p.join(library.path, '$entryId.json')), {
        'egressProxyUrl': 'http://127.0.0.1:$port',
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
    for (final dir in [configDir(dataDir), ..._legacyMirrors()]) {
      await _unpinDir(dir);
    }
  }

  Future<void> _unpinDir(String dir) async {
    final library = Directory(p.join(dir, 'configLibrary'));
    final metaFile = File(p.join(library.path, '_meta.json'));
    try {
      final meta = await _readJson(metaFile);
      final entries = meta?['entries'];
      final ours =
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

  /// Закреплён ли профиль за прокси лаунчера.
  Future<bool> isPinned(String dataDir) async {
    final meta = await _readJson(
      File(p.join(configDir(dataDir), 'configLibrary', '_meta.json')),
    );
    return meta?['appliedId'] == entryId;
  }

  static Future<Map<String, Object?>?> _readJson(File file) async {
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? json : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _writeJson(File file, Map<String, Object?> json) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
