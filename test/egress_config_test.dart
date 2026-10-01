import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/location/egress_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String dataDir;
  late String configDir;
  const config = EgressConfig();

  Future<Map<String, Object?>> read(String relative) async =>
      jsonDecode(await File(p.join(configDir, relative)).readAsString())
          as Map<String, Object?>;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('egress_config');
    dataDir = p.join(root.path, 'Claude-Work');
    configDir = '$dataDir-3p';
  });

  tearDown(() => root.delete(recursive: true));

  test('закрепляет профиль за прокси и убирает за собой', () async {
    expect(await config.pin(dataDir, 47821), isTrue);
    expect(await config.isPinned(dataDir), isTrue);

    final meta = await read('configLibrary/_meta.json');
    expect(meta['appliedId'], EgressConfig.entryId);
    final entry = await read('configLibrary/${EgressConfig.entryId}.json');
    expect(entry['egressProxyUrl'], 'http://127.0.0.1:47821');
    expect(entry['disableAutoUpdates'], isTrue);
    expect((await read('claude_desktop_config.json'))['deploymentMode'], '1p');

    await config.unpin(dataDir);
    expect(await config.isPinned(dataDir), isFalse);
    expect(
      await Directory(p.join(configDir, 'configLibrary')).exists(),
      isFalse,
    );
  });

  test('сохраняет остальные ключи claude_desktop_config.json', () async {
    await Directory(configDir).create(recursive: true);
    await File(p.join(configDir, 'claude_desktop_config.json')).writeAsString(
      jsonEncode({
        'mcpServers': {'x': 1},
      }),
    );
    expect(await config.pin(dataDir, 1234), isTrue);
    final desktop = await read('claude_desktop_config.json');
    expect(desktop['mcpServers'], {'x': 1});
    expect(desktop['deploymentMode'], '1p');
  });

  test('чужую конфигурацию не трогает', () async {
    final library = Directory(p.join(configDir, 'configLibrary'));
    await library.create(recursive: true);
    final foreign = jsonEncode({
      'appliedId': 'admin',
      'entries': [
        {'id': 'admin', 'name': 'Компания'},
      ],
    });
    await File(p.join(library.path, '_meta.json')).writeAsString(foreign);

    expect(await config.pin(dataDir, 47821), isFalse);
    expect(await config.isPinned(dataDir), isFalse);
    await config.unpin(dataDir);
    expect(
      await File(p.join(library.path, '_meta.json')).readAsString(),
      foreign,
    );
  });

  test('режим стороннего шлюза (3p) не трогает', () async {
    await Directory(configDir).create(recursive: true);
    await File(
      p.join(configDir, 'claude_desktop_config.json'),
    ).writeAsString(jsonEncode({'deploymentMode': '3p'}));
    expect(await config.pin(dataDir, 47821), isFalse);
    expect(
      await Directory(p.join(configDir, 'configLibrary')).exists(),
      isFalse,
    );
  });

  test('повторное закрепление меняет порт', () async {
    await config.pin(dataDir, 1000);
    expect(await config.pin(dataDir, 2000), isTrue);
    final entry = await read('configLibrary/${EgressConfig.entryId}.json');
    expect(entry['egressProxyUrl'], 'http://127.0.0.1:2000');
  });
}
