import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import 'countries.dart';

/// Публичный сервис, который по IP-адресу называет страну. Все — без ключей;
/// спрашиваем по очереди до первого внятного ответа.
class CountrySource {
  const CountrySource(this.name, this.url, this.parse);

  final String name;
  final String url;

  /// Код страны из ответа; `null` — ответ не подошёл.
  final String? Function(String body) parse;

  static const all = [
    CountrySource('country.is', 'https://api.country.is/', _countryField),
    CountrySource(
      'Cloudflare',
      'https://www.cloudflare.com/cdn-cgi/trace',
      _traceLoc,
    ),
    CountrySource(
      'ipwho.is',
      'https://ipwho.is/?fields=success,country_code',
      _countryCodeField,
    ),
    CountrySource('ipapi.co', 'https://ipapi.co/country/', _plain),
  ];

  /// `{"ip": "…", "country": "DE"}`
  static String? _countryField(String body) => _jsonField(body, 'country');

  /// `{"success": true, "country_code": "DE"}`
  static String? _countryCodeField(String body) =>
      _jsonField(body, 'country_code');

  /// Строки `ключ=значение`, страна — `loc=DE`.
  static String? _traceLoc(String body) =>
      RegExp(r'^loc=(\S+)$', multiLine: true).firstMatch(body)?.group(1);

  /// Просто `DE`.
  static String? _plain(String body) => body.trim();

  static String? _jsonField(String body, String field) {
    try {
      final json = jsonDecode(body);
      return json is Map ? json[field] as String? : null;
    } on FormatException {
      return null;
    }
  }
}

/// Не удалось узнать страну ни у одного сервиса.
class CountryLookupException implements Exception {
  const CountryLookupException(this.errors);

  /// Что ответил каждый сервис.
  final List<String> errors;

  @override
  String toString() => errors.join('; ');
}

typedef CountryLookup = Future<({String country, String source})> Function();

/// Флаг страны эмодзи: буквы кода ISO 3166-1 — региональные символы Юникода
/// (FI → 🇫🇮). Нарисует его шрифт эмодзи системы.
String countryFlag(String code) => String.fromCharCodes([
  for (final letter in code.toUpperCase().codeUnits) 0x1F1E6 + letter - 0x41,
]);

/// Страна по IP-адресу: код ISO 3166-1 и какой сервис ответил.
///
/// Сервисы спрашиваем с подстраховкой: следующий — если прежние не ответили
/// за [stagger] или ответили ошибкой. Обычно хватает первого, а медленный или
/// недоступный сервис не задерживает проверку.
Future<({String country, String source})> lookupCountry({
  List<CountrySource> sources = CountrySource.all,
  Duration timeout = const Duration(seconds: 4),
  Duration stagger = const Duration(milliseconds: 300),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'ClaudeLauncher'
    // Всегда напрямую: страна — та, через которую компьютер выходит в сеть, а
    // прокси из окружения может оказаться закрытым затвором Kill Switch.
    ..findProxy = (_) => 'DIRECT';
  final result = Completer<({String country, String source})>();
  final errors = List<String?>.filled(sources.length, null);
  final asked = <Future<void>>[];
  var settled = Completer<void>();
  try {
    for (final (index, source) in sources.indexed) {
      if (index > 0) {
        await Future.any([Future<void>.delayed(stagger), settled.future]);
        settled = Completer<void>();
      }
      if (result.isCompleted) break;
      asked.add(
        _ask(client, source, timeout)
            .then(
              (country) {
                if (!result.isCompleted) {
                  result.complete((country: country, source: source.name));
                }
              },
              onError: (Object error) {
                errors[index] = '${source.name}: $error';
              },
            )
            .whenComplete(() {
              if (!settled.isCompleted) settled.complete();
            }),
      );
    }
    await Future.any([result.future, Future.wait(asked)]);
    if (result.isCompleted) return result.future;
    throw CountryLookupException([...errors.nonNulls]);
  } finally {
    // Остальные запросы больше не нужны.
    client.close(force: true);
  }
}

Future<String> _ask(
  HttpClient client,
  CountrySource source,
  Duration timeout,
) async {
  final request = await client.getUrl(Uri.parse(source.url)).timeout(timeout);
  final response = await request.close().timeout(timeout);
  final body = await utf8.decodeStream(response).timeout(timeout);
  if (response.statusCode != HttpStatus.ok) {
    throw _Failure('HTTP ${response.statusCode}');
  }
  // Сервисы отвечают и не странами: XX — неизвестно, T1 — Tor.
  final code = source.parse(body)?.toUpperCase();
  if (code == null || !countryNames.containsKey(code)) {
    throw const _Failure('страна не указана');
  }
  return code;
}

class _Failure implements Exception {
  const _Failure(this.message);

  final String message;

  @override
  String toString() => message;
}

enum LocationState {
  /// Ещё не проверяли или не удалось узнать.
  unknown,

  /// Claude в этой стране доступен.
  supported,

  /// Claude в этой стране недоступен — профили не запускаем.
  unsupported,
}

/// Проверка страны перед запуском профиля: Claude доступен не везде
/// (см. [supportedCountries]). Страну узнаём по IP-адресу.
class LocationGuard extends ChangeNotifier {
  LocationGuard({
    required this.settings,
    CountryLookup? lookup,
    this.maxAge = const Duration(seconds: 30),
    this.recheckEvery = const Duration(seconds: 20),
    this.startupRetries = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) : lookup = lookup ?? lookupCountry;

  final AppSettings settings;
  final CountryLookup lookup;

  /// Сколько доверять прошлой проверке — например, запуску профиля сразу
  /// после проверки при старте. Смену VPN или сети это почти не задерживает.
  final Duration maxAge;

  /// Как часто перепроверять страну в фоне, пока запускать нельзя (см.
  /// [recheckWhile]).
  final Duration recheckEvery;

  /// Паузы перед повторами при запуске лаунчера: сеть может ещё подниматься.
  final List<Duration> startupRetries;

  LocationState state = LocationState.unknown;

  /// Код страны ISO 3166-1; `null` — неизвестна.
  String? country;

  /// Какой сервис назвал страну.
  String? source;

  DateTime? checkedAt;

  /// Почему не удалось узнать страну.
  String? error;

  bool checking = false;
  Future<LocationState>? _pending;

  /// Идёт фоновая проверка — её не показываем.
  bool _background = false;
  Timer? _recheck;

  bool get enabled => settings.locationCheck;

  /// Показывать ли загрузку: идёт проверка, которую ждёт пользователь.
  bool get showsProgress => checking && !_background;

  /// Claude в стране недоступен — профили не запускаются.
  bool get blocksLaunch => enabled && state == LocationState.unsupported;

  String? get countryName =>
      country == null ? null : countryNames[country] ?? country;

  /// Узнаёт страну. Свежий ответ (моложе [maxAge]) переиспользует, если не
  /// [force]; одновременные проверки сливаются в одну. [background] — без
  /// индикатора загрузки.
  Future<LocationState> check({bool force = false, bool background = false}) {
    if (_pending case final pending?) {
      // Фоновую проверку теперь ждёт пользователь — показываем её.
      if (!background && _background) {
        _background = false;
        notifyListeners();
      }
      return pending;
    }
    final checkedAt = this.checkedAt;
    if (!force &&
        state != LocationState.unknown &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < maxAge) {
      return Future.value(state);
    }
    _background = background;
    return _pending = _check();
  }

  /// Пока [active] (окно открыто), а профили запускать нельзя или страна
  /// неизвестна, перепроверяет её раз в [recheckEvery] — например, если
  /// сменилась сеть. Кнопки запуска оживут сами.
  void recheckWhile(ValueListenable<bool> active) {
    void sync() {
      final needed =
          active.value && enabled && state != LocationState.supported;
      if (!needed) {
        _recheck?.cancel();
        _recheck = null;
      } else {
        _recheck ??= Timer.periodic(
          recheckEvery,
          (_) => check(force: true, background: true),
        );
      }
    }

    active.addListener(sync);
    addListener(sync);
    sync();
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  Future<LocationState> _check() async {
    checking = true;
    notifyListeners();
    try {
      final result = await lookup();
      country = result.country;
      source = result.source;
      error = null;
      state = supportedCountries.contains(result.country)
          ? LocationState.supported
          : LocationState.unsupported;
    } catch (e) {
      country = null;
      source = null;
      error = '$e';
      state = LocationState.unknown;
    } finally {
      checkedAt = DateTime.now();
      checking = false;
      _pending = null;
      notifyListeners();
    }
    return state;
  }

  /// Перед запуском профиля (см. [LauncherController.launchGuard]): в стране,
  /// где Claude недоступен, не запускаем. Если страну узнать не удалось,
  /// запуск вручную разрешаем, а при старте лаунчера ([strict]) — нет: там
  /// проверка обязательна, и сначала ждём сеть.
  Future<void> ensureCanLaunch({required bool strict}) async {
    if (!enabled) return;
    var result = await check();
    if (strict) {
      for (final delay in startupRetries) {
        if (result != LocationState.unknown) break;
        await Future<void>.delayed(delay);
        result = await check(force: true);
      }
    }
    switch (result) {
      case LocationState.unsupported:
        // Причину и так видно в окне — предупреждение о стране.
        throw const LaunchBlocked();
      case LocationState.unknown when strict:
        throw const LaunchBlocked(
          'Не удалось определить страну по IP-адресу, поэтому профиль не '
          'открыт при запуске лаунчера. Проверьте подключение и откройте '
          'профиль сами.',
        );
      case _:
        return;
    }
  }
}
