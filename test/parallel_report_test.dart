import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/diagnostics/parallel_report.dart';
import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/egress_config.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

class ReportConfig extends EgressConfig {
  @override
  Future<bool> isPinned(String dataDir, {int? port}) async => port == 47821;
}

void main() {
  late Directory dir;
  late LauncherController launcher;
  late FakeHost host;
  late AppSettings settings;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('parallel-report');
    host = FakeHost()..targetedLinks = true;
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    await launcher.init();
    settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.setParallelLaunch(true);
  });
  tearDown(() async {
    launcher.dispose();
    settings.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'two profiles, duplicate and unknown processes; no account or task data',
    () async {
      final second = await launcher.addProfile(
        name: 'SECRET-name',
        email: 'SECRET-email',
        note: 'SECRET-note',
      );
      host.start(null);
      host.start(launcher.dataDirOf(second));
      host.start(launcher.dataDirOf(second));
      host.start('/SECRET-external');
      final session =
          CodeSession(
              id: 'SECRET-session',
              profileId: second.id,
              startedAt: DateTime.now(),
            )
            ..hostSessionId = 'SECRET-host-session'
            ..cwd = '/SECRET-cwd'
            ..transcriptPath = '/SECRET-transcript'
            ..message = 'SECRET-message'
            ..state = CodeSessionState.needsAnswer;
      launcher.lastError = 'SECRET-error';
      final report = await parallelReport(
        version: '1.5.10.8',
        launcher: launcher,
        settings: settings,
        sessions: [session],
        config: ReportConfig(),
      );
      final data = jsonDecode(report);
      expect(data['processScan'], 'ok');
      expect(data['runningCount'], 4);
      expect(data['unknownProcessCount'], 1);
      expect(data['profiles'][1]['duplicateProcesses'], isTrue);
      expect(data['profiles'][1]['codeSessionCounts'], {'needsAnswer': 1});
      expect(data['profiles'][0]['proxyConfigMatchesGate'], isTrue);
      expect(report, isNot(contains('SECRET')));
      expect(report, isNot(contains(second.id)));
      expect(report, isNot(contains(dir.path)));
      expect(host.calls, isEmpty);
    },
  );

  test('failed scan does not export stale processes as current', () async {
    host.start(null);
    await launcher.refresh();
    host.scanFails = true;
    final data = jsonDecode(
      await parallelReport(
        version: '1.5.10.8',
        launcher: launcher,
        settings: settings,
        sessions: [],
        config: ReportConfig(),
      ),
    );
    expect(data['processScan'], 'failed');
    expect(data['runningCount'], isNull);
    expect(data['unknownProcessCount'], isNull);
    expect(data['profiles'][0]['pids'], isNull);
    expect(data['profiles'][0]['duplicateProcesses'], isNull);
  });
}
