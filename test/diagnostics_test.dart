import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/diagnostics/diagnostics.dart';
import 'package:claude_launcher/src/integrations/claude_links.dart';
import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:claude_launcher/src/integrations/session_overview.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'claude_links_test.dart' show FakeLinkPlatform;
import 'launcher_controller_test.dart' show FakeHost;

class MissingClaude extends FakeHost {
  @override
  Future<String?> locate() async => null;
}

void main() {
  late Directory dir;
  late AppSettings settings;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diagnostics');
    settings = AppSettings(File('${dir.path}/s.json'));
    await settings.load();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<LauncherController> launcherWith(FakeHost host) async {
    final launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/p.json')),
    );
    await launcher.init();
    return launcher;
  }

  DiagnosticCheck find(List<DiagnosticCheck> checks, String title) =>
      checks.firstWhere((check) => check.title.startsWith(title));

  test('нет Claude — проблема', () async {
    final diagnostics = Diagnostics(
      launcher: await launcherWith(MissingClaude()),
      settings: settings,
      readSessions: () async => const [],
    );
    final checks = await diagnostics.run();
    expect(find(checks, 'Claude').status, CheckStatus.problem);
  });

  test(
    'пропавшая папка профиля, которым пользовались, — предупреждение',
    () async {
      final launcher = await launcherWith(FakeHost());
      final profile = await launcher.addProfile(name: 'Тест');
      await launcher.switchTo(profile);
      final checks = await Diagnostics(
        launcher: launcher,
        settings: settings,
        readSessions: () async => const [],
      ).run();
      // Папки FakeHost (/support/…) на диске нет.
      final check = find(checks, 'Профиль «Тест»');
      expect(check.status, CheckStatus.warning);
    },
  );

  test('ссылки: выбор пользователя мешает — проблема с «Выбрать»', () async {
    final launcher = await launcherWith(FakeHost());
    final platform = FakeLinkPlatform()..choice = 'AppX.claude';
    final links = ClaudeLinkHandler(
      launcher: launcher,
      settings: settings,
      platform: platform,
      sessionOwner: (_) async => null,
      choose: (_, _) async => null,
    );
    await links.start();
    var opened = false;
    final checks = await Diagnostics(
      launcher: launcher,
      settings: settings,
      links: links,
      readSessions: () async => const [],
      openDefaultApps: () async => opened = true,
    ).run();
    final check = find(checks, 'Ссылки');
    expect(check.status, CheckStatus.problem);
    await check.fix!();
    expect(opened, isTrue);
    links.dispose();
  });

  test('ссылки у Claude — «Исправить» забирает роль', () async {
    final launcher = await launcherWith(FakeHost());
    final platform = FakeLinkPlatform();
    final links = ClaudeLinkHandler(
      launcher: launcher,
      settings: settings,
      platform: platform,
      sessionOwner: (_) async => null,
      choose: (_, _) async => null,
    );
    await links.start();
    platform.handler = 'com.anthropic.claudefordesktop';
    final diagnostics = Diagnostics(
      launcher: launcher,
      settings: settings,
      links: links,
      readSessions: () async => const [],
    );
    final check = find(await diagnostics.run(), 'Ссылки');
    expect(check.status, CheckStatus.warning);
    await check.fix!();
    expect(find(await diagnostics.run(), 'Ссылки').status, CheckStatus.ok);
    links.dispose();
  });

  test('непонятые карточки сессий и отчёт без путей', () async {
    final launcher = await launcherWith(FakeHost());
    final diagnostics = Diagnostics(
      launcher: launcher,
      settings: settings,
      readSessions: () async => [
        ProfileSessions(
          profile: launcher.profiles.single,
          identity: const ProfileIdentity(accountUuid: 'a', orgUuid: 'o'),
          sessions: const [],
          unreadable: 3,
        ),
      ],
    );
    final checks = await diagnostics.run();
    final sessions = find(checks, 'Сессии Code');
    expect(sessions.status, CheckStatus.warning);
    expect(sessions.detail, contains('3 сессии'));
    final report = diagnostics.report(checks, version: '1.7.2');
    expect(report, startsWith('ClaudeLauncher 1.7.2'));
    expect(report, contains('! Сессии Code'));
    expect(report, isNot(contains('/support')));
    expect(report, isNot(contains(dir.path)));
  });

  test('всё хорошо — без исправлений', () async {
    final checks = await Diagnostics(
      launcher: await launcherWith(FakeHost()),
      settings: settings,
      readSessions: () async => const [],
    ).run();
    expect(
      checks.where((check) => check.status == CheckStatus.problem),
      isEmpty,
    );
    expect(find(checks, 'Профили').detail, '1 в списке, открыто 0');
  });
}
