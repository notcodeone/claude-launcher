import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/claude/claude_icon_keeper.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

void main() {
  late Directory dir;
  late AppSettings settings;
  late FakeHost host;
  late LauncherController launcher;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('icon_keeper');
    settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.load();
    host = FakeHost();
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
  });

  tearDown(() => dir.delete(recursive: true));

  int hides() => host.calls.where((call) => call == 'icon hidden').length;

  test('Claude открылся — значок прячется сразу и потом снова', () async {
    await settings.setHideClaudeIcon(true);
    final keeper = ClaudeIconKeeper(
      settings: settings,
      launcher: launcher,
      every: const Duration(milliseconds: 30),
    )..start();
    addTearDown(keeper.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // Claude не открыт — прятать нечего.
    expect(hides(), 0);

    host.start(null);
    await launcher.refresh();
    expect(hides(), 1);
    // Пока открыт — снова: после обновления Claude запись о значке новая.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hides(), greaterThan(1));
  });

  test('настройка выключена — не трогает значок', () async {
    final keeper = ClaudeIconKeeper(
      settings: settings,
      launcher: launcher,
      every: const Duration(milliseconds: 30),
    )..start();
    addTearDown(keeper.dispose);
    host.start(null);
    await launcher.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hides(), 0);
  });
}
