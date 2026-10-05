import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/claude/link_handler_platform.dart';
import 'package:claude_launcher/src/integrations/claude_links.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

const claude = 'com.anthropic.claudefordesktop';
const own = 'com.notcodeone.claudeLauncher';

/// Как macOS: обработчик — id приложения; [choice] — как выбор пользователя
/// в «Приложениях по умолчанию» Windows, который лаунчер не меняет.
class FakeLinkPlatform implements LinkHandlerPlatform {
  String? handler = claude;
  String? choice;
  final links = <String>[];

  @override
  Future<String?> currentHandler() async => choice ?? handler;

  @override
  Future<String?> ownId() async => own;

  @override
  Future<void> claim() async => handler = own;

  @override
  Future<void> restore(String? previous) async {
    if (handler == own) handler = previous ?? claude;
  }

  @override
  Future<String?> blocker() async => choice;

  bool shortcutsRegistered = false;

  @override
  Future<void> registerShortcuts() async => shortcutsRegistered = true;

  @override
  Future<void> removeShortcuts() async => shortcutsRegistered = false;

  @override
  Future<List<String>> takeLinks() async {
    final taken = [...links];
    links.clear();
    return taken;
  }
}

void main() {
  final now = DateTime(2026, 10, 3, 20);
  Profile profile(String id, {Duration? launchedAgo}) => Profile(
    id: id,
    name: id,
    folderName: 'Claude-$id',
    lastLaunchedAt: launchedAgo == null ? null : now.subtract(launchedAgo),
  );

  test('виды ссылок', () {
    ClaudeLinkKind kind(String link) => ClaudeLinks.kindOf(Uri.parse(link));
    expect(kind('claude://login/google-auth?code=x'), ClaudeLinkKind.login);
    expect(kind('claude://claude.ai/magic-link#a:b'), ClaudeLinkKind.login);
    expect(kind('claude://claude.ai/sso-callback?x=1'), ClaudeLinkKind.login);
    expect(kind('claude://claude.ai/epitaxy/local_1'), ClaudeLinkKind.session);
    expect(kind('claude://claude.ai/new'), ClaudeLinkKind.other);
    expect(kind('claude://cowork/x'), ClaudeLinkKind.other);
    expect(
      ClaudeLinks.sessionIdOf(Uri.parse('claude://claude.ai/epitaxy/local_1')),
      'local_1',
    );
    // В журнал — без кода входа.
    expect(
      ClaudeLinks.describe(Uri.parse('claude://claude.ai/magic-link#a:b')),
      'claude://claude.ai/magic-link',
    );
  });

  group('куда отдать ссылку', () {
    final old = profile('old', launchedAgo: const Duration(hours: 2));
    final fresh = profile('fresh', launchedAgo: const Duration(minutes: 1));
    final closed = profile('closed', launchedAgo: const Duration(minutes: 30));

    LinkRoute route(
      ClaudeLinkKind kind,
      List<Profile> running, {
      Profile? owner,
      String? fallback,
    }) => ClaudeLinks.route(
      kind: kind,
      profiles: [old, fresh, closed],
      isRunning: running.contains,
      now: now,
      sessionOwner: owner,
      fallback: fallback,
    );

    Profile? target(LinkRoute route) =>
        route is DeliverLink ? route.profile : null;

    test('вход — профилю, открытому последним за 10 минут', () {
      expect(target(route(ClaudeLinkKind.login, [old, fresh])), fresh);
    });

    test('вход: недавних нет — единственному открытому, иначе спросить', () {
      expect(target(route(ClaudeLinkKind.login, [old])), old);
      final staleTwo = ClaudeLinks.route(
        kind: ClaudeLinkKind.login,
        profiles: [old, closed],
        isRunning: (_) => true,
        now: now,
      );
      expect(staleTwo, isA<AskForProfile>());
      expect((staleTwo as AskForProfile).candidates, [closed, old]);
    });

    test('сессия — туда, где лежит, открыв профиль', () {
      final result = route(ClaudeLinkKind.session, [fresh], owner: closed);
      expect(target(result), closed);
      expect((result as DeliverLink).launch, isTrue);
    });

    test('прочее — последнему открытому, без открытых — по умолчанию', () {
      expect(target(route(ClaudeLinkKind.other, [old, fresh])), fresh);
      final launched = route(ClaudeLinkKind.other, [], fallback: 'old');
      expect(target(launched), old);
      expect((launched as DeliverLink).launch, isTrue);
      expect(target(route(ClaudeLinkKind.other, [])), fresh);
    });
  });

  group('обработчик', () {
    late Directory dir;
    late AppSettings settings;
    late LauncherController launcher;
    late FakeHost host;
    late FakeLinkPlatform platform;
    late ClaudeLinkHandler handler;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('links');
      settings = AppSettings(File('${dir.path}/s.json'));
      await settings.load();
      host = FakeHost();
      launcher = LauncherController(
        host: host,
        store: ProfileStore(File('${dir.path}/p.json')),
      );
      await launcher.init();
      platform = FakeLinkPlatform();
      handler = ClaudeLinkHandler(
        launcher: launcher,
        settings: settings,
        platform: platform,
        sessionOwner: (_) async => null,
        choose: (_, _) async => null,
        bootDelay: Duration.zero,
      );
    });

    tearDown(() async {
      handler.dispose();
      await dir.delete(recursive: true);
    });

    test('забирает роль, помнит прежнего и возвращает его', () async {
      await handler.start();
      expect(platform.handler, own);
      expect(settings.previousLinkHandler, claude);

      await settings.setClaudeLinks(false);
      await Future<void>.delayed(Duration.zero);
      expect(platform.handler, claude);
    });

    test('чужую роль при выходе не трогает', () async {
      platform.handler = 'com.example.other';
      await settings.setClaudeLinks(false);
      await handler.release();
      expect(platform.handler, 'com.example.other');
    });

    test('выбор пользователя перекрывает лаунчер — blocked', () async {
      platform.choice = 'AppX.claude';
      await handler.start();
      expect(handler.blocked, isTrue);
      platform.choice = null;
      await settings.setClaudeLinks(false);
      await settings.setClaudeLinks(true);
      await Future<void>.delayed(Duration.zero);
      expect(handler.blocked, isFalse);
    });

    test('ссылка из аргументов запуска (Windows)', () async {
      await launcher.switchTo(launcher.profiles.single);
      await handler.start(initial: ['claude://claude.ai/new', 'not a link']);
      expect(
        host.calls.where((call) => call.startsWith('link ')),
        hasLength(1),
      );
    });

    test('ссылка, пришедшая до запуска, уходит открытому профилю', () async {
      final main = launcher.profiles.single;
      await launcher.switchTo(main);
      platform.links.add('claude://claude.ai/new');
      await handler.start();
      expect(
        host.calls.where((call) => call.startsWith('link ')),
        hasLength(1),
      );
      expect(host.calls.last, endsWith('claude://claude.ai/new'));
    });
  });
}
