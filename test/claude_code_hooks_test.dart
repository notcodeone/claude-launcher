import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  late ClaudeCodeHooks hooks;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_launcher_hooks');
    file = File('${dir.path}/.claude/settings.json');
    hooks = ClaudeCodeHooks(file);
  });
  tearDown(() => dir.delete(recursive: true));

  Map<String, Object?> read() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  test('создаёт файл, если его нет', () async {
    await hooks.install(port: 5000, token: 'secret');
    expect(await hooks.isInstalled(port: 5000, token: 'secret'), isTrue);
    final stop = (read()['hooks'] as Map)['Stop'] as List;
    final hook = ((stop.single as Map)['hooks'] as List).single as Map;
    expect(hook['type'], 'http');
    expect(hook['url'], 'http://127.0.0.1:5000/claude-launcher/v1/event');
    expect(hook['headers'], {'X-Claude-Launcher-Token': 'secret'});
    expect(
      hooks.backup.existsSync(),
      isFalse,
      reason: 'копировать было нечего',
    );
  });

  test('не трогает чужие настройки и хуки, делает резервную копию', () async {
    file.parent.createSync(recursive: true);
    final original = {
      'model': 'opus',
      'permissions': {
        'allow': ['Bash(ls:*)'],
      },
      'hooks': {
        'Stop': [
          {
            'hooks': [
              {'type': 'command', 'command': 'say done'},
            ],
          },
        ],
        'PreToolUse': [
          {
            'matcher': 'Bash',
            'hooks': [
              {'type': 'command', 'command': 'echo pre'},
            ],
          },
        ],
      },
    };
    file.writeAsStringSync(jsonEncode(original));

    await hooks.install(port: 5000, token: 't');
    final settings = read();
    expect(settings['model'], 'opus');
    expect(settings['permissions'], original['permissions']);
    final hooksSection = settings['hooks'] as Map;
    expect(
      hooksSection['PreToolUse'],
      (original['hooks'] as Map)['PreToolUse'],
    );
    expect(hooksSection['Stop'] as List, hasLength(2));
    expect(jsonDecode(hooks.backup.readAsStringSync()), original);

    await hooks.uninstall();
    expect(read(), original);
  });

  test(
    'повторная установка не дублирует хуки и обновляет порт и ключ',
    () async {
      await hooks.install(port: 5000, token: 'a');
      await hooks.install(port: 5001, token: 'b');
      final stop = (read()['hooks'] as Map)['Stop'] as List;
      expect(stop, hasLength(1));
      expect(await hooks.isInstalled(port: 5001, token: 'b'), isTrue);
      expect(await hooks.isInstalled(port: 5000, token: 'a'), isFalse);
      expect(await hooks.isInstalled(port: 5001, token: 'a'), isFalse);
    },
  );

  test('удаление убирает пустые разделы', () async {
    await hooks.install(port: 5000, token: 't');
    await hooks.uninstall();
    expect(read().containsKey('hooks'), isFalse);
    expect(await hooks.isInstalled(port: 5000, token: 't'), isFalse);
  });

  test('повреждённый файл не перезаписывается', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{ не json');
    await expectLater(
      hooks.install(port: 5000, token: 't'),
      throwsFormatException,
    );
    expect(file.readAsStringSync(), '{ не json');
  });
}
