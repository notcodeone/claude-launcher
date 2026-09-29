// Проверка на настоящем Claude (только macOS):
//   flutter test integration_test/macos_host_test.dart -d macos
//
// Запускает отдельный тестовый профиль Claude во временной папке, находит его
// среди процессов, закрывает так же, как Cmd+Q, и удаляет папку. Уже открытые
// экземпляры Claude не трогаются.
import 'dart:io';

import 'package:claude_launcher/src/claude/macos_claude_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('запуск, поиск и закрытие профиля Claude', (tester) async {
    final host = MacClaudeHost();
    expect(await host.locate(), isNotNull, reason: 'Claude.app не найден');

    final testDir = p.join(host.profilesBaseDir, 'Claude-LauncherSelfTest');
    addTearDown(() async {
      final dir = Directory(testDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final before = await host.running();
    final pidsBefore = {for (final instance in before) instance.pid};
    // ignore: avoid_print
    print('Открыто до теста: ${before.map((i) => '${i.pid} → ${host.dataDirOf(i)}').join('; ')}');
    expect(before.any((i) => host.samePath(host.dataDirOf(i), testDir)), isFalse);

    await host.launch(testDir);
    final launched = await _waitFor(() async {
      for (final instance in await host.running()) {
        if (!pidsBefore.contains(instance.pid) &&
            host.samePath(host.dataDirOf(instance), testDir)) {
          return instance;
        }
      }
      return null;
    });
    expect(launched, isNotNull, reason: 'Запущенный профиль не найден среди процессов');
    // ignore: avoid_print
    print('Тестовый профиль запущен: pid ${launched!.pid}, ${launched.dataDir}');

    // Даём приложению подняться, чтобы проверить обычный выход, а не прерывание запуска.
    await Future<void>.delayed(const Duration(seconds: 5));
    await host.requestQuit(launched);

    final gone = await _waitFor(() async {
      final pids = {for (final instance in await host.running()) instance.pid};
      return pids.contains(launched.pid) ? null : true;
    });
    expect(gone, isTrue, reason: 'Тестовый профиль не закрылся за отведённое время');

    final after = {for (final instance in await host.running()) instance.pid};
    expect(after.containsAll(pidsBefore), isTrue,
        reason: 'Тест не должен закрывать уже открытые экземпляры');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<T?> _waitFor<T>(Future<T?> Function() check,
    {Duration timeout = const Duration(seconds: 40)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await check();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return null;
}
