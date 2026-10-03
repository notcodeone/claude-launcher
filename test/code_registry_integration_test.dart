import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:claude_launcher/src/integrations/claude_code_integration.dart';
import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/integrations/code_session_registry.dart';
import 'package:claude_launcher/src/integrations/notification_handoff.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'claude_code_events_test.dart'
    show ProfileMetadataHost, FakeNotifier, post;

void main() {
  late Directory dir;
  late ProfileMetadataHost host;
  late LauncherController launcher;
  late AppSettings settings;
  late File registryFile;
  final integrations = <ClaudeCodeIntegration>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('claude_registry_integration');
    host = ProfileMetadataHost(dir.path);
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    await launcher.init();
    launcher.setParallelLaunch(true);
    host.start(null);
    await launcher.refresh();
    settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.load();
    await settings.setEventsPort(0);
    registryFile = File('${dir.path}/registry.json');
  });
  tearDown(() async {
    for (final integration in integrations) {
      integration.dispose();
    }
    integrations.clear();
    launcher.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> metadata(String root) async {
    final file = File('$root/claude-code-sessions/account/org/local_test.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'sessionId': 'local_test', 'cliSessionId': 's1'}),
    );
  }

  Future<ClaudeCodeIntegration> start({FakeNotifier? notifier}) async {
    final hooks = ClaudeCodeHooks(File('${dir.path}/hooks.json'));
    final integration = ClaudeCodeIntegration(
      settings: settings,
      launcher: launcher,
      registry: CodeSessionRegistry(registryFile),
      hooks: hooks,
      notifier: notifier,
      handoff: notifier == null
          ? null
          : NotificationHandoff(
              stateFile: File('${dir.path}/handoff.json'),
              hooks: hooks,
              samePath: host.samePath,
            ),
    );
    integrations.add(integration);
    await integration.setEnabled(true);
    return integration;
  }

  Future<void> send(ClaudeCodeIntegration integration, String kind) async {
    await post(
      settings.eventsPort,
      {'hook_event_name': kind, 'session_id': 's1'},
      token: settings.eventsToken,
      hostSession: 'local_test',
    );
    await integration.pendingEvents;
  }

  Future<void> restart(ClaudeCodeIntegration first) async {
    await first.flushSessions();
    first.dispose();
    integrations.remove(first);
    // Stop the owned listener before the next integration takes over its hooks.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('обычный режим: реестр сессий не пишется', () async {
    launcher.setParallelLaunch(false);
    await metadata(host.defaultDataDir);
    final integration = await start();
    await send(integration, 'UserPromptSubmit');
    await send(integration, 'PostToolUse');
    await integration.flushSessions();
    expect(integration.sessions.all, hasLength(1));
    expect(registryFile.existsSync(), isFalse);
  });

  test(
    'restart validates ownership, restores unknown state and sends no notification',
    () async {
      await metadata(host.defaultDataDir);
      final first = await start();
      await send(first, 'UserPromptSubmit');
      expect(first.sessions.all.single.state, CodeSessionState.working);
      await restart(first);
      final notifier = FakeNotifier();
      final next = await start(notifier: notifier);
      expect(next.registryError, isNull);
      expect(next.sessions.all.single.profileId, launcher.profiles.single.id);
      expect(next.sessions.all.single.state, CodeSessionState.unknown);
      expect(next.sessions.anyWorking, isFalse);
      expect(notifier.log, isEmpty);
      await send(next, 'PostToolUse');
      expect(next.sessions.all.single.state, CodeSessionState.working);
      await send(next, 'SessionEnd');
      await restart(next);
      final last = await start();
      expect(last.sessions.isEmpty, isTrue);
    },
  );

  test(
    'closed profile and copied metadata do not restore into remaining neighbor',
    () async {
      await metadata(host.defaultDataDir);
      final first = await start();
      await send(first, 'UserPromptSubmit');
      await restart(first);
      final saved = await registryFile.readAsString();
      final second = await launcher.addProfile(name: 'Second');
      host.instances.clear();
      host.start(launcher.dataDirOf(second));
      await launcher.refresh();
      final closed = await start();
      expect(closed.sessions.isEmpty, isTrue);
      closed.dispose();
      integrations.remove(closed);
      host.start(null);
      await launcher.refresh();
      await metadata(launcher.dataDirOf(second));
      await registryFile.writeAsString(saved);
      final copied = await start();
      expect(copied.sessions.isEmpty, isTrue);
    },
  );

  test(
    'cached owner mismatch and corrupt cache fail closed without disabling hooks',
    () async {
      await metadata(host.defaultDataDir);
      final first = await start();
      await send(first, 'UserPromptSubmit');
      await restart(first);
      final second = await launcher.addProfile(name: 'Second');
      host.start(launcher.dataDirOf(second));
      await launcher.refresh();
      final saved = jsonDecode(await registryFile.readAsString()) as Map;
      (saved['sessions'] as List).single['profileId'] = second.id;
      await registryFile.writeAsString(jsonEncode(saved));
      final mismatch = await start();
      expect(mismatch.sessions.isEmpty, isTrue);
      mismatch.dispose();
      integrations.remove(mismatch);
      await registryFile.writeAsString('{');
      final corrupt = await start();
      expect(corrupt.connected, isTrue);
      expect(corrupt.registryError, isNotNull);
      expect(corrupt.sessions.isEmpty, isTrue);
      await send(corrupt, 'UserPromptSubmit');
      expect(corrupt.sessions.all.single.profileId, launcher.profiles.first.id);
      expect(corrupt.registryError, isNull);
    },
  );

  test('disabling hooks clears persisted references', () async {
    await metadata(host.defaultDataDir);
    final first = await start();
    await send(first, 'UserPromptSubmit');
    await first.setEnabled(false);
    expect(await CodeSessionRegistry(registryFile).load(), isEmpty);
    await first.setEnabled(true);
    expect(first.sessions.isEmpty, isTrue);
  });
}
