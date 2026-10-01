import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('остаток лимита, ноль и превышение', () {
    final usage = ProfileUsage.fromHistory({
      'version': 2,
      'samples': [
        {
          't': 1000,
          'org': 'a',
          'u': {'fh': 3, 'sd': 67, 'so': 105, 'sn': 0},
        },
      ],
    })!;
    expect(usage.limits.map((l) => l.remainingPercent), [97, 33, 0, 100]);
    expect(usage.updatedAt.millisecondsSinceEpoch, 1000);
  });

  test('последний снимок целиком, без смешивания организаций и периодов', () {
    final usage = ProfileUsage.fromHistory({
      'version': 2,
      'samples': [
        {
          't': 3000,
          'org': 'b',
          'u': {'fh': 20},
        },
        {
          't': 1000,
          'org': 'a',
          'u': {'fh': 10, 'sd': 90},
        },
      ],
    })!;
    expect(usage.limits, hasLength(1));
    expect(usage.limits.single.remainingPercent, 80);
  });

  test('старый формат истории и отсутствующие значения', () {
    final usage = ProfileUsage.fromHistory({
      'version': 1,
      'samples': [
        {'t': 1000, 'fh': null, 'sd': 40},
      ],
    })!;
    expect(usage.limits.single.remainingPercent, 60);
    expect(ProfileUsage.fromHistory({'version': 2, 'samples': []}), isNull);
    expect(
      ProfileUsage.fromHistory({
        'version': 2,
        'samples': [
          {
            't': 1000,
            'u': {'fh': null},
          },
        ],
      }),
      isNull,
    );
  });

  test('некорректные данные не становятся доступным лимитом', () {
    expect(
      () => ProfileUsage.fromHistory({'version': 3}),
      throwsFormatException,
    );
    final usage = ProfileUsage.fromHistory({
      'version': 2,
      'samples': [
        {
          't': double.infinity,
          'u': {'fh': 0},
        },
        {
          't': 1000,
          'u': {'fh': -1, 'sd': '0', 'so': double.nan},
        },
      ],
    });
    expect(usage, isNull);
  });

  test('устаревание снимка', () {
    final now = DateTime(2026, 10, 1, 12);
    expect(ProfileUsage(updatedAt: now, limits: []).isStale(now), isFalse);
    expect(
      ProfileUsage(
        updatedAt: now.subtract(const Duration(minutes: 16)),
        limits: [],
      ).isStale(now),
      isTrue,
    );
  });

  test(
    'читает только переданные папки, включая виртуализированную MSIX',
    () async {
      final root = await Directory.systemTemp.createTemp('launcher_usage');
      addTearDown(() => root.delete(recursive: true));
      final reader = const ProfileUsageReader();
      Future<void> write(String dir, int time, int used) async {
        await Directory(dir).create(recursive: true);
        await File('$dir/plan-usage-history.json').writeAsString(
          jsonEncode({
            'version': 2,
            'samples': [
              {
                't': time,
                'u': {'fh': used},
              },
            ],
          }),
        );
      }

      final a = '${root.path}/a';
      final b = '${root.path}/virtual/a';
      final other = '${root.path}/other';
      await write(a, 1000, 10);
      await write(b, 2000, 20);
      await write(other, 3000, 99);
      expect((await reader.read([a, b]))!.limits.single.remainingPercent, 80);
      expect(await reader.read(['${root.path}/missing']), isNull);
      await File('$a/plan-usage-history.json').writeAsString('{');
      expect((await reader.read([a, b]))!.limits.single.remainingPercent, 80);
      await expectLater(reader.read([a]), throwsFormatException);
    },
  );
}
