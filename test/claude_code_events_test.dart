import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/integrations/claude_code_events.dart';
import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:claude_launcher/src/integrations/claude_code_integration.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

/// Запрос, как его шлёт HTTP-хук Claude Code.
Future<({int status, String body})> post(
  int port,
  Map<String, Object?> json, {
  String? token,
  String path = '/claude-launcher/v1/event',
  String method = 'POST',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.contentType = ContentType.json;
    if (token != null) request.headers.set('X-Claude-Launcher-Token', token);
    request.write(jsonEncode(json));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close();
  }
}

void main() {
  group('разбор событий хуков', () {
    test('Stop — задача завершена, текст ответа не сохраняется', () {
      final event = ClaudeCodeEvent.fromHookJson({
        'hook_event_name': 'Stop',
        'cwd': '/Users/me/project',
        'last_assistant_message': 'секретный код',
      });
      expect(event?.kind, ClaudeCodeEventKind.finished);
      expect(event?.cwd, '/Users/me/project');
      expect(event?.message, isEmpty);
    });

    test('Notification — разрешение или ожидание ввода', () {
      expect(
        ClaudeCodeEvent.fromHookJson({
          'hook_event_name': 'Notification',
          'notification_type': 'permission_prompt',
          'message': 'Claude needs your permission',
        })?.kind,
        ClaudeCodeEventKind.needsPermission,
      );
      expect(
        ClaudeCodeEvent.fromHookJson({
          'hook_event_name': 'Notification',
          'notification_type': 'idle_prompt',
        })?.kind,
        ClaudeCodeEventKind.waiting,
      );
    });

    test('прочие события игнорируются', () {
      expect(
        ClaudeCodeEvent.fromHookJson({'hook_event_name': 'PreToolUse'}),
        isNull,
      );
    });
  });

  group('приёмник событий', () {
    late ClaudeCodeEventServer server;
    late int port;
    final events = <ClaudeCodeEvent>[];

    setUp(() async {
      events.clear();
      server = ClaudeCodeEventServer(token: 'secret', onEvent: events.add);
      port = await server.start(0);
    });
    tearDown(() => server.stop());

    test('с верным ключом — 200 с пустым телом и событие', () async {
      final response = await post(port, {
        'hook_event_name': 'Stop',
      }, token: 'secret');
      expect(response.status, 200);
      expect(
        response.body,
        isEmpty,
        reason: 'иначе Claude Code сочтёт хук упавшим',
      );
      expect(events.single.kind, ClaudeCodeEventKind.finished);
    });

    test('без ключа, с чужим ключом или не тем запросом — 404', () async {
      expect((await post(port, {'hook_event_name': 'Stop'})).status, 404);
      expect(
        (await post(port, {'hook_event_name': 'Stop'}, token: 'x')).status,
        404,
      );
      expect(
        (await post(port, {}, token: 'secret', path: '/other')).status,
        404,
      );
      expect(
        (await post(port, {}, token: 'secret', method: 'PUT')).status,
        404,
      );
      expect(events, isEmpty);
    });
  });

  test(
    'интеграция: включение, событие открытого профиля, выключение',
    () async {
      final dir = await Directory.systemTemp.createTemp('claude_launcher_int');
      addTearDown(() => dir.delete(recursive: true));
      final host = FakeHost();
      final launcher = LauncherController(
        host: host,
        store: ProfileStore(File('${dir.path}/profiles.json')),
      );
      await launcher.init();
      addTearDown(launcher.dispose);
      final settings = AppSettings(File('${dir.path}/settings.json'));
      await settings.load();
      await settings.setEventsPort(0);
      final hooks = ClaudeCodeHooks(File('${dir.path}/.claude/settings.json'));
      final integration = ClaudeCodeIntegration(
        settings: settings,
        launcher: launcher,
        hooks: hooks,
      );
      addTearDown(integration.dispose);

      await integration.setEnabled(true);
      expect(integration.error, isNull);
      expect(integration.connected, isTrue);
      expect(settings.claudeCodeEvents, isTrue);
      final port = settings.eventsPort;
      expect(port, isNot(0));
      expect(
        await hooks.isInstalled(port: port, token: settings.eventsToken),
        isTrue,
      );

      host.start(null);
      await launcher.refresh();
      await post(port, {
        'hook_event_name': 'Stop',
        'cwd': '/p/demo',
      }, token: settings.eventsToken);
      final profile = launcher.profiles.single;
      expect(integration.lastEvents[profile.id]?.cwd, '/p/demo');

      await integration.setEnabled(false);
      expect(integration.connected, isFalse);
      expect(integration.lastEvents, isEmpty);
      expect(
        await hooks.isInstalled(port: port, token: settings.eventsToken),
        isFalse,
      );
    },
  );
}
