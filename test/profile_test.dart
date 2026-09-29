import 'dart:io';

import 'package:claude_launcher/src/profile.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('folderNameFor', () {
    test('латиница и транслитерация', () {
      expect(folderNameFor('Work', []), 'Claude-Work');
      expect(folderNameFor('Личный', []), 'Claude-Lichnyy');
      expect(
        folderNameFor('Клиент: ООО «Ромашка»', []),
        'Claude-Klient-ooo-romashka',
      );
    });

    test('пустое или нелатинское имя', () {
      expect(folderNameFor('🙂', []), 'Claude-Profile');
      expect(folderNameFor('  ', []), 'Claude-Profile');
    });

    test('уникальность без учёта регистра', () {
      expect(folderNameFor('Work', ['claude-work']), 'Claude-Work-2');
      expect(
        folderNameFor('Work', ['Claude-Work', 'Claude-Work-2']),
        'Claude-Work-3',
      );
    });

    test('никогда не совпадает со стандартной папкой Claude', () {
      expect(folderNameFor('', []), isNot(equalsIgnoringCase('Claude')));
    });
  });

  test('хранилище сохраняет и читает профили', () async {
    final dir = await Directory.systemTemp.createTemp('claude_launcher_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = ProfileStore(File('${dir.path}/nested/profiles.json'));

    expect(await store.load(), isEmpty);

    final launched = DateTime.utc(2026, 9, 29, 10, 30);
    await store.save([
      const Profile(id: 'a', name: 'Рабочий', email: 'me@work.com'),
      Profile(
        id: 'b',
        name: 'Личный',
        marker: '🔵',
        icon: 'rocketLaunch',
        note: 'пет-проекты',
        folderName: 'Claude-Lichnyy',
        lastLaunchedAt: launched,
        sessionsCollapsed: true,
      ),
    ]);

    final loaded = await store.load();
    expect(loaded.map((profile) => profile.name), ['Рабочий', 'Личный']);
    expect(loaded[0].usesDefaultFolder, isTrue);
    expect(loaded[0].email, 'me@work.com');
    expect(loaded[1].folderName, 'Claude-Lichnyy');
    expect(loaded[1].marker, '🔵');
    expect(loaded[1].icon, 'rocketLaunch');
    expect(loaded[0].icon, Profile.defaultIcon);
    expect(loaded[1].lastLaunchedAt, launched);
    expect(loaded[0].sessionsCollapsed, isFalse);
    expect(loaded[1].sessionsCollapsed, isTrue);
  });
}
