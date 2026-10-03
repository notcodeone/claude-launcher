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
  test(
    'проверяет порт, запись, отключение обновлений и обычный режим входа',
    () async {
      await config.pin(dataDir, 47821);
      expect(await config.isPinned(dataDir, port: 47821), isTrue);
      expect(await config.isPinned(dataDir, port: 47822), isFalse);
      final entry = File(
        p.join(configDir, 'configLibrary/${EgressConfig.entryId}.json'),
      );
      for (final values in [
        {'egressProxyUrl': 'http://remote:47821', 'disableAutoUpdates': true},
        {
          'egressProxyUrl': 'http://127.0.0.1:47821',
          'disableAutoUpdates': false,
        },
        {
          'egressProxyUrl': 'http://127.0.0.1:47821/path',
          'disableAutoUpdates': true,
        },
        {
          'egressProxyUrl': 'http://127.0.0.1:47821?x=1',
          'disableAutoUpdates': true,
        },
      ]) {
        await entry.writeAsString(jsonEncode(values));
        expect(await config.isPinned(dataDir), isFalse);
      }
      await config.pin(dataDir, 47821);
      await File(
        p.join(configDir, 'claude_desktop_config.json'),
      ).writeAsString('{"deploymentMode":"3p"}');
      expect(await config.isPinned(dataDir), isFalse);
      await entry.delete();
      expect(await config.isPinned(dataDir), isFalse);
    },
  );

  test(
    'повреждённые и не-объектные файлы не перезаписываются как пустые',
    () async {
      for (final relative in [
        'configLibrary/_meta.json',
        'claude_desktop_config.json',
      ]) {
        final file = File(p.join(configDir, relative));
        await file.parent.create(recursive: true);
        for (final content in ['{bad', '[]', '{"entries":[null]}']) {
          // The entries case applies only to metadata.
          if (relative == 'claude_desktop_config.json' &&
              content.contains('entries')) {
            continue;
          }
          await file.writeAsString(content);
          expect(await config.pin(dataDir, 47821), isFalse);
          expect(await config.isPinned(dataDir), isFalse);
          expect(await file.readAsString(), content);
        }
        await file.delete();
      }
    },
  );

  test(
    'чужой appliedId сохраняется даже со списком прежней собственной записи',
    () async {
      await config.pin(dataDir, 47821);
      final meta = File(p.join(configDir, 'configLibrary/_meta.json'));
      final values = await read('configLibrary/_meta.json');
      values['appliedId'] = 'admin';
      final content = jsonEncode(values);
      await meta.writeAsString(content);
      expect(await config.pin(dataDir, 47821), isFalse);
      await config.unpin(dataDir);
      expect(await meta.readAsString(), content);
    },
  );

  test(
    'симлинки и слишком большой файл не дают подтверждения защиты',
    () async {
      final outside = File(p.join(root.path, 'outside.json'));
      const original = '{"deploymentMode":"3p"}';
      await outside.writeAsString(original);
      await Directory(configDir).create();
      final link = Link(p.join(configDir, 'claude_desktop_config.json'));
      await link.create(outside.path);
      expect(await config.pin(dataDir, 47821), isFalse);
      expect(await config.isPinned(dataDir), isFalse);
      expect(await outside.readAsString(), original);
      await link.delete();
      await File(link.path).writeAsString(' ' * (1024 * 1024 + 1));
      expect(await config.pin(dataDir, 47821), isFalse);
      expect(await config.isPinned(dataDir), isFalse);
    },
  );

  test(
    'пересекающиеся pin/read/unpin одной Windows-папки выполняются по порядку',
    () async {
      final first = EgressConfig(directoryForProfile: (_) => configDir);
      final second = EgressConfig(directoryForProfile: (_) => configDir);
      final a = first.pin('profile A', 1000);
      final observedA = second.isPinned('profile B', port: 1000);
      final b = second.pin('profile B', 2000);
      final observedB = first.isPinned('profile A', port: 2000);
      final remove = first.unpin('profile A');
      final absent = second.isPinned('profile B');
      expect(await a, isTrue);
      expect(await observedA, isTrue);
      expect(await b, isTrue);
      expect(await observedB, isTrue);
      await remove;
      expect(await absent, isFalse);
      expect(
        await Directory(configDir)
            .list(recursive: true)
            .any((e) => e.path.contains('.launcher-config-')),
        isFalse,
      );
    },
  );

  test(
    'повреждённая собственная запись и симлинк не заменяются при pin',
    () async {
      await config.pin(dataDir, 47821);
      final entry = File(
        p.join(configDir, 'configLibrary/${EgressConfig.entryId}.json'),
      );
      await entry.writeAsString('{bad');
      expect(await config.pin(dataDir, 47821), isFalse);
      expect(await entry.readAsString(), '{bad');
      await entry.delete();
      final outside = File(p.join(root.path, 'outside-entry.json'));
      const content = '{"egressProxyUrl":"http://remote:1234"}';
      await outside.writeAsString(content);
      final link = Link(entry.path);
      await link.create(outside.path);
      expect(await config.pin(dataDir, 47821), isFalse);
      expect(await config.isPinned(dataDir), isFalse);
      expect(await link.exists(), isTrue);
      expect(await outside.readAsString(), content);
    },
  );

  test('недопустимый порт не записывается', () async {
    expect(await config.pin(dataDir, 0), isFalse);
    expect(await config.pin(dataDir, 65536), isFalse);
    expect(await Directory(configDir).exists(), isFalse);
  });
}
