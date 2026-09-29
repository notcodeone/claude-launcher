import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/countries.dart';
import 'package:claude_launcher/src/location/location_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('список стран Anthropic', () {
    expect(supportedCountries, hasLength(185));
    for (final code in ['US', 'DE', 'GB', 'KZ', 'UA', 'TR', 'CZ', 'CD']) {
      expect(supportedCountries, contains(code), reason: code);
    }
    for (final code in ['RU', 'BY', 'CN', 'IR', 'KP', 'HK']) {
      expect(supportedCountries, isNot(contains(code)), reason: code);
    }
    expect(countryNames.keys, containsAll(supportedCountries));
    expect(countryNames['RU'], 'Россия');
  });

  group('сервисы', () {
    late HttpServer server;
    final responses = <String, (int, String)>{};

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final (status, body) = responses[request.uri.path] ?? (404, '');
        // Медленный сервис: клиент может не дождаться и закрыть соединение.
        if (request.uri.path.startsWith('/slow')) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        try {
          request.response
            ..statusCode = status
            ..write(body);
          await request.response.close();
        } on Object {
          // Соединение уже закрыто.
        }
      });
    });
    tearDown(() => server.close(force: true));

    CountrySource local(CountrySource source, String path) => CountrySource(
      source.name,
      'http://127.0.0.1:${server.port}$path',
      source.parse,
    );

    final [countryIs, cloudflare, ipwho, ipapi] = CountrySource.all;

    test('по очереди до первого внятного ответа', () async {
      responses
        ..['/a'] = (500, '')
        // Tor — не страна.
        ..['/b'] = (200, 'fl=1\nip=1.2.3.4\nloc=T1\ntls=TLSv1.3\n')
        ..['/c'] = (200, '{"success":true,"country_code":"de"}')
        ..['/d'] = (200, 'US');
      final result = await lookupCountry(
        sources: [
          local(countryIs, '/a'),
          local(cloudflare, '/b'),
          local(ipwho, '/c'),
          local(ipapi, '/d'),
        ],
      );
      expect(result, (country: 'DE', source: 'ipwho.is'));
    });

    test('разбор ответа каждого сервиса', () async {
      responses
        ..['/country.is'] = (200, '{"ip":"1.2.3.4","country":"KZ"}')
        ..['/trace'] = (200, 'fl=1\nloc=GB\nwarp=off\n')
        ..['/plain'] = (200, 'JP\n');
      expect(
        (await lookupCountry(
          sources: [local(countryIs, '/country.is')],
        )).country,
        'KZ',
      );
      expect(
        (await lookupCountry(sources: [local(cloudflare, '/trace')])).country,
        'GB',
      );
      expect(
        (await lookupCountry(sources: [local(ipapi, '/plain')])).country,
        'JP',
      );
    });

    test(
      'медленный сервис не задерживает: следующий спрашиваем раньше',
      () async {
        responses
          ..['/slow'] = (200, 'US')
          ..['/fast'] = (200, 'DE');
        final watch = Stopwatch()..start();
        final result = await lookupCountry(
          sources: [local(ipapi, '/slow'), local(ipapi, '/fast')],
          stagger: const Duration(milliseconds: 50),
        );
        expect(result.country, 'DE');
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );

    test('никто не ответил — ошибка с причинами', () async {
      responses['/bad'] = (200, 'не страна');
      await expectLater(
        lookupCountry(
          sources: [local(countryIs, '/missing'), local(ipapi, '/bad')],
        ),
        throwsA(
          isA<CountryLookupException>().having((e) => e.errors, 'errors', [
            'country.is: HTTP 404',
            'ipapi.co: страна не указана',
          ]),
        ),
      );
    });
  });

  group('проверка', () {
    late Directory dir;
    late AppSettings settings;
    late List<String?> answers;
    late int lookups;

    /// Ответы сервисов по очереди: код страны или `null` — нет ответа.
    Future<({String country, String source})> lookup() async {
      lookups++;
      final answer = answers.length > 1 ? answers.removeAt(0) : answers.single;
      if (answer == null) throw const CountryLookupException(['нет сети']);
      return (country: answer, source: 'тест');
    }

    LocationGuard guard({Duration maxAge = const Duration(minutes: 1)}) =>
        LocationGuard(
          settings: settings,
          lookup: lookup,
          maxAge: maxAge,
          startupRetries: const [Duration.zero, Duration.zero],
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('claude_launcher_location');
      settings = AppSettings(File('${dir.path}/settings.json'));
      await settings.load();
      answers = ['DE'];
      lookups = 0;
    });
    tearDown(() => dir.delete(recursive: true));

    test('страна, где Claude доступен или нет', () async {
      final location = guard();
      expect(await location.check(), LocationState.supported);
      expect(location.country, 'DE');
      expect(location.countryName, 'Германия');

      answers = ['RU'];
      expect(
        await location.check(),
        LocationState.supported,
        reason: 'свежий ответ переиспользуется',
      );
      expect(await location.check(force: true), LocationState.unsupported);
      expect(location.countryName, 'Россия');
      expect(lookups, 2);
    });

    test('одновременные проверки — один запрос', () async {
      final location = guard();
      final results = await Future.wait([
        location.check(),
        location.check(force: true),
      ]);
      expect(results, [LocationState.supported, LocationState.supported]);
      expect(lookups, 1);
    });

    test('нет ответа — страна неизвестна и перепроверяется', () async {
      answers = [null];
      final location = guard();
      expect(await location.check(), LocationState.unknown);
      expect(location.error, contains('нет сети'));
      answers = ['DE'];
      expect(await location.check(), LocationState.supported);
    });

    test('где Claude недоступен, профиль не запускается', () async {
      answers = ['RU'];
      final location = guard();
      await expectLater(
        location.ensureCanLaunch(strict: false),
        throwsA(isA<LaunchBlocked>().having((e) => e.message, 'message', null)),
      );
    });

    test('страна неизвестна: вручную можно, при старте — нет', () async {
      answers = [null];
      final location = guard();
      await location.ensureCanLaunch(strict: false);
      expect(lookups, 1);
      await expectLater(
        location.ensureCanLaunch(strict: true),
        throwsA(
          isA<LaunchBlocked>().having(
            (e) => e.message,
            'message',
            contains('определить страну'),
          ),
        ),
      );
      expect(lookups, 4, reason: 'при старте — ещё два повтора');
    });

    test('при старте ждёт, пока поднимется сеть', () async {
      answers = [null, 'DE'];
      await guard().ensureCanLaunch(strict: true);
      expect(lookups, 2);
    });

    test('фоновая проверка идёт без индикатора загрузки', () async {
      final location = guard();
      final progress = <bool>[];
      location.addListener(() => progress.add(location.showsProgress));
      await location.check(force: true, background: true);
      expect(progress, [false, false]);

      // Пользователь попросил проверить, пока идёт фоновая, — показываем.
      progress.clear();
      final background = location.check(force: true, background: true);
      final visible = location.check(force: true);
      expect(location.showsProgress, isTrue);
      await Future.wait([background, visible]);
      expect(lookups, 2);
      expect(progress.last, isFalse);
    });

    test(
      'пока запускать нельзя и окно открыто, страна перепроверяется сама',
      () async {
        answers = ['RU'];
        final location = LocationGuard(
          settings: settings,
          lookup: lookup,
          recheckEvery: const Duration(milliseconds: 20),
        );
        addTearDown(location.dispose);
        final visible = ValueNotifier(false);
        location.recheckWhile(visible);
        await location.check();
        expect(location.blocksLaunch, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(lookups, 1, reason: 'окно закрыто — не проверяем');

        visible.value = true;
        answers = ['DE'];
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(location.state, LocationState.supported);
        expect(location.blocksLaunch, isFalse);
        final settled = lookups;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          lookups,
          settled,
          reason: 'Claude доступен — больше не проверяем',
        );
      },
    );

    test('выключенная проверка ничего не спрашивает', () async {
      await settings.setLocationCheck(false);
      answers = ['RU'];
      await guard().ensureCanLaunch(strict: true);
      expect(lookups, 0);
    });
  });
}
