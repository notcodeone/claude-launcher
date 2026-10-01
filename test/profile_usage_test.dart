import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  UsageSample sample(
    DateTime time,
    Map<String, double> values, {
    String org = 'a',
  }) => UsageSample(time: time, org: org, values: values);

  CachedUsage response(
    DateTime fetchedAt,
    Map<String, ({double percent, DateTime? resetsAt})> limits, {
    String org = 'a',
  }) => CachedUsage(
    org: org,
    fetchedAt: fetchedAt,
    limits: {
      for (final MapEntry(:key, :value) in limits.entries)
        key: CachedLimit(
          label: ProfileUsage.labelOf(key),
          percent: value.percent,
          resetsAt: value.resetsAt,
        ),
    },
  );

  UsageLimit limit(ProfileUsage usage, String label) =>
      usage.limits.firstWhere((l) => l.label == label);

  group('история', () {
    test('версии 1 и 2, некорректные значения отбрасываются', () {
      final v2 = UsageSample.parseHistory({
        'version': 2,
        'samples': [
          {
            't': 1000,
            'org': 'a',
            'u': {'fh': 3, 'sd': 67, 'so': -1, 'xx': 5},
          },
          {
            't': -5,
            'org': 'a',
            'u': {'fh': 1},
          },
          {
            't': 2000,
            'org': 'a',
            'u': {'fh': null},
          },
        ],
      });
      expect(v2, hasLength(1));
      expect(v2.single.values, {'session': 3, 'weekly': 67});
      final v1 = UsageSample.parseHistory({
        'version': 1,
        'samples': [
          {'t': 1000, 'sd': 40},
        ],
      });
      expect(v1.single.values, {'weekly': 40});
      expect(v1.single.org, isNull);
      expect(
        () => UsageSample.parseHistory({'version': 9}),
        throwsFormatException,
      );
    });
  });

  group('объединение', () {
    test('точные сбросы из ответа, проценты — из более свежей истории', () {
      final usage = ProfileUsage.combine(
        history: [
          sample(now.subtract(const Duration(minutes: 5)), {
            'session': 12,
            'weekly': 70,
          }),
        ],
        cached: [
          response(now.subtract(const Duration(hours: 1)), {
            'session': (
              percent: 3,
              resetsAt: now.add(const Duration(hours: 2)),
            ),
            'weekly': (percent: 67, resetsAt: now.add(const Duration(days: 3))),
            'weekly:Fable': (
              percent: 0,
              resetsAt: now.add(const Duration(days: 3)),
            ),
          }),
        ],
        now: now,
      )!;
      expect(usage.limits.map((l) => l.label), [
        'За 5 часов',
        'За неделю · все модели',
        'weekly:Fable',
      ]);
      expect(usage.limits[0].usedPercent, 12);
      expect(usage.limits[0].resetsAt, now.add(const Duration(hours: 2)));
      expect(usage.limits[0].resetApproximate, isFalse);
      expect(usage.limits[1].usedPercent, 70);
      // Категория только из ответа — его значение и тот же недельный сброс.
      expect(usage.limits[2].usedPercent, 0);
      expect(usage.limits[2].resetsAt, now.add(const Duration(days: 3)));
    });

    test('прошедший недельный сброс сдвигается на неделю, процент — 0', () {
      final usage = ProfileUsage.combine(
        history: const [],
        cached: [
          response(now.subtract(const Duration(days: 2)), {
            'weekly': (
              percent: 67,
              resetsAt: now.subtract(const Duration(days: 1)),
            ),
          }),
        ],
        now: now,
      )!;
      final weekly = limit(usage, 'За неделю · все модели');
      expect(weekly.resetsAt, now.add(const Duration(days: 6)));
      expect(weekly.usedPercent, 0);
    });

    test('пятичасовое окно истекло и нового замера нет — ждёт запроса', () {
      final usage = ProfileUsage.combine(
        history: [
          sample(now.subtract(const Duration(hours: 3)), {'session': 40}),
        ],
        cached: [
          response(now.subtract(const Duration(hours: 3)), {
            'session': (
              percent: 40,
              resetsAt: now.subtract(const Duration(hours: 1)),
            ),
          }),
        ],
        now: now,
      )!;
      final session = limit(usage, 'За 5 часов');
      expect(session.usedPercent, 0);
      expect(session.resetsAt, isNull);
      expect(session.wasResetAt, now.subtract(const Duration(hours: 1)));
      expect(session.idle, isFalse);
    });

    test('новое окно после сброса — примерное время по истории', () {
      final start = now.subtract(const Duration(hours: 1));
      final usage = ProfileUsage.combine(
        history: [
          sample(start.subtract(const Duration(minutes: 15)), {'session': 0}),
          sample(start, {'session': 4}),
          sample(start.add(const Duration(minutes: 15)), {'session': 9}),
        ],
        cached: [
          response(now.subtract(const Duration(hours: 4)), {
            'session': (
              percent: 30,
              resetsAt: now.subtract(const Duration(hours: 2)),
            ),
          }),
        ],
        now: now,
      )!;
      final session = limit(usage, 'За 5 часов');
      expect(session.usedPercent, 9);
      expect(session.resetApproximate, isTrue);
      // Окно началось между снимками: посередине, плюс 5 часов.
      expect(
        session.resetsAt,
        start
            .subtract(const Duration(seconds: 450))
            .add(const Duration(hours: 5)),
      );
    });

    test('большой разрыв в истории — время сброса не выдумывается', () {
      final usage = ProfileUsage.combine(
        history: [
          sample(now.subtract(const Duration(hours: 3)), {'session': 0}),
          sample(now.subtract(const Duration(minutes: 10)), {'session': 5}),
        ],
        cached: const [],
        now: now,
      )!;
      final session = limit(usage, 'За 5 часов');
      expect(session.usedPercent, 5);
      expect(session.resetsAt, isNull);
      expect(session.idle, isFalse);
    });

    test('недельный сброс без ответа — по падению процента в истории', () {
      final drop = now.subtract(const Duration(days: 2));
      final usage = ProfileUsage.combine(
        history: [
          sample(drop.subtract(const Duration(minutes: 10)), {'weekly': 99}),
          sample(drop.add(const Duration(minutes: 10)), {'weekly': 0}),
          sample(now.subtract(const Duration(minutes: 1)), {'weekly': 20}),
        ],
        cached: const [],
        now: now,
      )!;
      final weekly = limit(usage, 'За неделю · все модели');
      expect(weekly.resetsAt, drop.add(const Duration(days: 7)));
      expect(weekly.resetApproximate, isTrue);
      expect(weekly.usedPercent, 20);
    });

    test('берётся организация самого свежего снимка, чужие не смешиваются', () {
      final usage = ProfileUsage.combine(
        history: [
          sample(now.subtract(const Duration(days: 9)), {
            'session': 50,
            'weekly': 90,
          }, org: 'old'),
          sample(now.subtract(const Duration(minutes: 3)), {
            'session': 7,
          }, org: 'new'),
        ],
        cached: [
          response(now.subtract(const Duration(days: 9)), {
            'weekly': (percent: 90, resetsAt: now.add(const Duration(days: 1))),
          }, org: 'old'),
        ],
        now: now,
      )!;
      expect(usage.limits.map((l) => (l.label, l.usedPercent)), [
        ('За 5 часов', 7),
      ]);
    });

    test('без данных — null', () {
      expect(
        ProfileUsage.combine(history: const [], cached: const [], now: now),
        isNull,
      );
    });
  });

  group('ответ сервера', () {
    test('список limits с моделями и прежний формат', () {
      final fetched = DateTime(2026, 10, 1);
      final usage = CachedUsage.fromJson(
        {
          'limits': [
            {
              'kind': 'session',
              'percent': 3,
              'resets_at': '2026-09-30T21:09:59.98+00:00',
            },
            {'kind': 'weekly_all', 'percent': 67, 'resets_at': null},
            {
              'kind': 'weekly_scoped',
              'percent': 0,
              'scope': {
                'model': {'display_name': 'Fable'},
              },
            },
            {'kind': 'unknown', 'percent': 5},
          ],
        },
        org: 'a',
        fetchedAt: fetched,
      )!;
      expect(usage.limits.keys, ['session', 'weekly', 'weekly:Fable']);
      expect(usage.limits['weekly:Fable']!.label, 'За неделю · Fable');
      expect(
        usage.limits['session']!.resetsAt!.isAtSameMomentAs(
          DateTime.utc(2026, 9, 30, 21, 9, 59, 980),
        ),
        isTrue,
      );
      final legacy = CachedUsage.fromJson(
        {
          'five_hour': {'utilization': 3.0, 'resets_at': null},
          'seven_day_opus': null,
        },
        org: 'a',
        fetchedAt: fetched,
      )!;
      expect(legacy.limits.keys, ['session']);
    });
  });

  group('кэш Chromium', () {
    test('имя файла — хеш ключа', () {
      // Проверено на настоящем кэше Claude.
      expect(
        ChromiumCacheEntry.fileNameFor(
          '1/0/https://claude.ai/api/organizations/'
          'f9318940-bb09-4fa1-a2e2-273952297901/usage'
          '?cedar_ember=1&skip_spend=1',
        ),
        '98facbf89d22c36a_0',
      );
    });

    test('читает сжатый ответ из папки профиля', () async {
      final root = await Directory.systemTemp.createTemp('launcher_usage');
      addTearDown(() => root.delete(recursive: true));
      const org = '11111111-2222-3333-4444-555555555555';
      final fetched = DateTime.utc(2026, 10, 1, 11, 30, 52);
      final resets = fetched.add(const Duration(hours: 3));
      await File('${root.path}/plan-usage-history.json').writeAsString(
        jsonEncode({
          'version': 2,
          'samples': [
            {
              't': fetched
                  .subtract(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
              'org': org,
              'u': {'fh': 1, 'sd': 60},
            },
          ],
        }),
      );
      const key = '1/0/https://claude.ai/api/organizations/$org/usage';
      final cache = Directory('${root.path}/Cache/Cache_Data')
        ..createSync(recursive: true);
      File(
        '${cache.path}/${ChromiumCacheEntry.fileNameFor(key)}',
      ).writeAsBytesSync(
        _cacheEntry(
          key,
          ZstdCodec().compress(
            utf8.encode(
              jsonEncode({
                'limits': [
                  {
                    'kind': 'session',
                    'percent': 5,
                    'resets_at': resets.toIso8601String(),
                  },
                  {'kind': 'weekly_all', 'percent': 62},
                ],
              }),
            ),
          ),
          [
            'HTTP/1.1 200',
            'date:${HttpDate.format(fetched)}',
            'content-type:application/json',
            'content-encoding:zstd',
          ],
        ),
      );
      final usage = (await const ProfileUsageReader().read([
        root.path,
      ], now: fetched.add(const Duration(minutes: 1))))!;
      final session = limit(usage, 'За 5 часов');
      // Ответ свежее истории — его проценты и точный сброс.
      expect(session.usedPercent, 5);
      expect(session.resetsAt, resets.toLocal());
      expect(limit(usage, 'За неделю · все модели').usedPercent, 62);
    });

    test('повреждённые файлы и отсутствие данных', () async {
      final root = await Directory.systemTemp.createTemp('launcher_usage');
      addTearDown(() => root.delete(recursive: true));
      expect(await const ProfileUsageReader().read([root.path]), isNull);
      await File('${root.path}/plan-usage-history.json').writeAsString('{');
      await expectLater(
        const ProfileUsageReader().read([root.path]),
        throwsFormatException,
      );
      expect(ChromiumCacheEntry.parse(Uint8List(10)), isNull);
    });
  });
}

/// Запись простого кэша Chromium: заголовок, ключ, тело, EOF, заголовки ответа.
Uint8List _cacheEntry(String key, List<int> body, List<String> headers) {
  final out = BytesBuilder();
  final head = ByteData(24)
    ..setUint64(0, 0xfcfb6d1ba7725c30, Endian.little)
    ..setUint32(8, 5, Endian.little)
    ..setUint32(12, utf8.encode(key).length, Endian.little);
  out
    ..add(head.buffer.asUint8List())
    ..add(utf8.encode(key))
    ..add(body)
    ..add(
      (ByteData(
        20,
      )..setUint64(0, 0xf4fa6f45970d41d8, Endian.little)).buffer.asUint8List(),
    )
    ..add(List.filled(8, 1))
    ..add(latin1.encode(headers.join('\u0000')))
    ..add([0, 0]);
  return out.toBytes();
}
