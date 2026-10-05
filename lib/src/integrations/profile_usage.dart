import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libcompress/libcompress.dart';
import 'package:path/path.dart' as p;

/// Лимиты профиля — из двух файлов, которые Claude пишет сам. Без входа,
/// cookies и Связки ключей:
///
/// - ответ `/usage` в HTTP-кэше Chromium: проценты, время сброса и все
///   категории, как в «Настройки → Использование» Claude. Обновляется, когда
///   Claude его запрашивает — например, при открытии этого экрана;
/// - `plan-usage-history.json`: проценты раз в 15 минут, пока Claude открыт.
///
/// Проценты берутся из того, что новее. Недельный сброс повторяется каждые
/// 7 дней в одно и то же время, поэтому известен и по старому ответу.
/// Пятичасовой — точно, пока не истёк ответ из кэша, иначе примерно по истории.

/// Окно лимита.
enum UsageWindow { session, weekly, other }

class UsageLimit {
  const UsageLimit({
    required this.label,
    required this.usedPercent,
    required this.window,
    this.resetsAt,
    this.resetApproximate = false,
    this.wasResetAt,
  });

  final String label;
  final double usedPercent;
  final UsageWindow window;

  /// Следующий сброс; null — неизвестен или окно ещё не началось.
  final DateTime? resetsAt;

  /// Время сброса ([resetsAt] или [wasResetAt]) оценено по истории, а не
  /// получено от сервера.
  final bool resetApproximate;

  /// Окно уже сбросилось, а замера после сброса ещё нет: новое окно могло
  /// начаться, но Claude об этом пока не сообщил.
  final DateTime? wasResetAt;

  /// Пятичасовое окно не идёт: по последнему замеру ничего не использовано.
  bool get idle =>
      window == UsageWindow.session &&
      resetsAt == null &&
      wasResetAt == null &&
      usedPercent == 0;
}

class ProfileUsage {
  const ProfileUsage({required this.limits});

  final List<UsageLimit> limits;

  static const _session = Duration(hours: 5);
  static const _week = Duration(days: 7);

  /// Шаг истории — 15 минут; оценке по паре соседних снимков с большим
  /// разрывом не верим.
  static const _maxGap = Duration(minutes: 30);

  /// Объединяет историю и ответ из кэша одной организации — текущей у профиля:
  /// той, что в самом свежем снимке истории, или в самом свежем ответе.
  static ProfileUsage? combine({
    required List<UsageSample> history,
    required List<CachedUsage> cached,
    required DateTime now,
  }) {
    final samples = [...history]..sort((a, b) => a.time.compareTo(b.time));
    final responses = [...cached]
      ..sort((a, b) => a.fetchedAt.compareTo(b.fetchedAt));
    final String? org;
    if (samples.isNotEmpty &&
        (responses.isEmpty ||
            !samples.last.time.isBefore(responses.last.fetchedAt))) {
      org = samples.last.org;
    } else if (responses.isNotEmpty) {
      org = responses.last.org;
    } else {
      return null;
    }
    // В старом формате истории организации нет — такие снимки подходят любой.
    final own = [
      for (final s in samples)
        if (s.org == null || s.org == org) s,
    ];
    final response = responses.where((r) => r.org == org).lastOrNull;
    final latest = own.lastOrNull;

    final weeklyReset = _weeklyReset(own, response, now);
    final sessionReset = _sessionReset(own, response, now);

    final keys = <String>[
      ..._order.where(
        (key) =>
            (latest?.values.containsKey(key) ?? false) ||
            (response?.limits.containsKey(key) ?? false),
      ),
      ...?response?.limits.keys.where((key) => !_order.contains(key)),
    ];
    final limits = <UsageLimit>[];
    for (final key in keys) {
      final fromHistory = latest?.values[key];
      final fromResponse = response?.limits[key];
      final useHistory =
          fromHistory != null &&
          (fromResponse == null || !latest!.time.isBefore(response!.fetchedAt));
      final percent = useHistory ? fromHistory : fromResponse!.percent;
      final measuredAt = useHistory ? latest!.time : response!.fetchedAt;
      final label = useHistory || fromResponse == null
          ? _labels[key] ?? key
          : fromResponse.label;
      final window = _windowOf(key);
      switch (window) {
        case UsageWindow.weekly:
          final reset = weeklyReset;
          // Неделя сбросилась после замера — значит, использовано 0%.
          final passed =
              reset != null && measuredAt.isBefore(reset.at.subtract(_week));
          limits.add(
            UsageLimit(
              label: label,
              usedPercent: passed ? 0 : percent,
              window: window,
              resetsAt: reset?.at,
              resetApproximate: reset?.approximate ?? false,
            ),
          );
        case UsageWindow.session:
          final reset = sessionReset;
          final ended =
              reset.endedAfter != null &&
              !measuredAt.isAfter(reset.endedAfter!);
          limits.add(
            UsageLimit(
              label: label,
              usedPercent: ended ? 0 : percent,
              window: window,
              resetsAt: ended ? null : reset.at,
              resetApproximate: reset.approximate,
              wasResetAt: ended ? reset.endedAfter : null,
            ),
          );
        case UsageWindow.other:
          limits.add(
            UsageLimit(label: label, usedPercent: percent, window: window),
          );
      }
    }
    return limits.isEmpty ? null : ProfileUsage(limits: limits);
  }

  /// Недельный сброс: точный — из ответа сервера, иначе по падению
  /// недельного процента в истории. Сдвигается вперёд на целые недели.
  static ({DateTime at, bool approximate})? _weeklyReset(
    List<UsageSample> samples,
    CachedUsage? response,
    DateTime now,
  ) {
    DateTime? anchor = response?.limits['weekly']?.resetsAt;
    var approximate = false;
    if (anchor == null) {
      for (var i = samples.length - 1; i > 0; i--) {
        final before = samples[i - 1].values['weekly'];
        final after = samples[i].values['weekly'];
        if (before == null || after == null || after >= before) continue;
        final gap = samples[i].time.difference(samples[i - 1].time);
        if (gap > _maxGap) break;
        anchor = samples[i - 1].time.add(gap ~/ 2);
        approximate = true;
        break;
      }
    }
    if (anchor == null) return null;
    while (!anchor!.isAfter(now)) {
      anchor = anchor.add(_week);
    }
    return (at: anchor, approximate: approximate);
  }

  /// Пятичасовой сброс. [endedAfter] — окно, в котором сделан замер, уже
  /// закончилось в этот момент или позже, и нового замера с тех пор нет.
  static ({DateTime? at, bool approximate, DateTime? endedAfter}) _sessionReset(
    List<UsageSample> samples,
    CachedUsage? response,
    DateTime now,
  ) {
    final known = response?.limits['session']?.resetsAt;
    if (known != null && known.isAfter(now)) {
      return (at: known, approximate: false, endedAfter: null);
    }
    final latest = samples.lastOrNull;
    if (latest == null || (known != null && !latest.time.isAfter(known))) {
      // Нового замера после сброса нет — окно не идёт.
      return (at: null, approximate: false, endedAfter: known);
    }
    if ((latest.values['session'] ?? 0) == 0) {
      return (at: null, approximate: false, endedAfter: null);
    }
    // Окно началось перед первым снимком текущего роста процента.
    var first = samples.length - 1;
    while (first > 0) {
      final previous = samples[first - 1];
      final value = previous.values['session'] ?? 0;
      if (value == 0 ||
          value > samples[first].values['session']! ||
          samples[first].time.difference(previous.time) > _maxGap) {
        break;
      }
      first--;
    }
    final hi = samples[first].time;
    var lo = first > 0 ? samples[first - 1].time : null;
    if (known != null && (lo == null || known.isAfter(lo))) lo = known;
    if (lo == null ||
        hi.difference(lo) > _maxGap ||
        latest.time.difference(hi) > _session) {
      return (at: null, approximate: false, endedAfter: null);
    }
    final at = lo.add(hi.difference(lo) ~/ 2).add(_session);
    if (!at.isAfter(now)) {
      return (at: null, approximate: true, endedAfter: at);
    }
    return (at: at, approximate: true, endedAfter: null);
  }

  static const _order = [
    'session',
    'weekly',
    'weekly:Opus',
    'weekly:Sonnet',
    'weekly:apps',
    'weekly:Cowork',
    'weekly:Claude Design',
    'promo',
    'extra',
  ];

  static const _labels = {
    'session': 'За 5 часов',
    'weekly': 'За неделю · все модели',
    'weekly:Opus': 'За неделю · Opus',
    'weekly:Sonnet': 'За неделю · Sonnet',
    'weekly:apps': 'За неделю · приложения',
    'weekly:Cowork': 'За неделю · Cowork',
    'weekly:Claude Design': 'За неделю · Claude Design',
    'promo': 'Бонус · Claude Design',
    'extra': 'Дополнительное использование',
  };

  static UsageWindow _windowOf(String key) => key == 'session'
      ? UsageWindow.session
      : key == 'weekly' || key.startsWith('weekly:')
      ? UsageWindow.weekly
      : UsageWindow.other;

  static String labelOf(String key) => _labels[key] ?? key;

  /// Ответ `GET /api/oauth/usage` (как его получает Claude): окна `five_hour`,
  /// `seven_day`, `seven_day_*` с `utilization` и `resets_at`, и `limits[]` —
  /// в том числе недельные лимиты отдельных моделей. `null` — лимитов нет.
  static ProfileUsage? fromOAuthUsage(Object? json) {
    if (json is! Map) return null;
    final byKey = <String, UsageLimit>{};
    void add(String key, Object? percent, Object? resets, {String? name}) {
      if (percent is! num) return;
      byKey[key] = UsageLimit(
        label: name != null && !_labels.containsKey(key)
            ? 'За неделю · $name'
            : labelOf(key),
        usedPercent: percent.toDouble(),
        window: _windowOf(key),
        resetsAt: _resetOf(resets),
      );
    }

    const windows = {
      'five_hour': 'session',
      'seven_day': 'weekly',
      'seven_day_opus': 'weekly:Opus',
      'seven_day_sonnet': 'weekly:Sonnet',
      'seven_day_oauth_apps': 'weekly:apps',
      'seven_day_cowork': 'weekly:Cowork',
    };
    for (final MapEntry(:key, :value) in windows.entries) {
      final window = json[key];
      if (window is Map) add(value, window['utilization'], window['resets_at']);
    }
    final list = json['limits'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final scope = item['scope'];
        final model = scope is Map && scope['model'] is Map
            ? (scope['model'] as Map)['display_name']
            : null;
        final name = model is String && model.trim().isNotEmpty ? model : null;
        final key = switch (item['kind']) {
          'session' => 'session',
          'weekly_all' => 'weekly',
          'weekly_scoped' when name != null => 'weekly:$name',
          _ => null,
        };
        if (key != null) {
          add(key, item['percent'], item['resets_at'], name: name);
        }
      }
    }
    final extra = json['extra_usage'];
    if (extra is Map && extra['is_enabled'] == true) {
      add('extra', extra['utilization'], null);
    }
    if (byKey.isEmpty) return null;
    // Порядок как в Claude: 5 часов, неделя, модели, остальное.
    final ordered = [
      ?byKey.remove('session'),
      ?byKey.remove('weekly'),
      ...byKey.values,
    ];
    return ProfileUsage(limits: ordered);
  }

  /// `resets_at` — строка ISO или секунды Unix.
  static DateTime? _resetOf(Object? value) => switch (value) {
    final String text => DateTime.tryParse(text)?.toLocal(),
    final num seconds => DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
    ),
    _ => null,
  };
}

/// Снимок из `plan-usage-history.json`.
class UsageSample {
  const UsageSample({required this.time, required this.values, this.org});

  final DateTime time;
  final String? org;

  /// Проценты по ключам [ProfileUsage] (`session`, `weekly`, …).
  final Map<String, double> values;

  static const _codes = {
    'fh': 'session',
    'sd': 'weekly',
    'so': 'weekly:Opus',
    'sn': 'weekly:Sonnet',
    'oa': 'weekly:apps',
    'cw': 'weekly:Cowork',
    'om': 'weekly:Claude Design',
    'op': 'promo',
    'xu': 'extra',
  };

  /// Версия 1 — проценты прямо в снимке, версия 2 — в `u` и с организацией.
  static List<UsageSample> parseHistory(Object? json) {
    if (json is! Map || !const [1, 2].contains(json['version'])) {
      throw const FormatException('Неизвестный формат истории лимитов');
    }
    final raw = json['samples'];
    if (raw is! List) throw const FormatException('Нет истории лимитов');
    final samples = <UsageSample>[];
    for (final sample in raw) {
      if (sample is! Map) continue;
      final t = sample['t'];
      if (t is! num || !t.isFinite || t <= 0 || t > 8640000000000000) continue;
      final values = json['version'] == 1 ? sample : sample['u'];
      if (values is! Map) continue;
      final parsed = <String, double>{
        for (final MapEntry(:key, :value) in _codes.entries)
          if (values[key] case final num v when v.isFinite && v >= 0)
            value: v.toDouble(),
      };
      if (parsed.isEmpty) continue;
      final org = sample['org'];
      samples.add(
        UsageSample(
          time: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
          org: org is String ? org : null,
          values: parsed,
        ),
      );
    }
    return samples;
  }
}

/// Лимит из ответа сервера.
class CachedLimit {
  const CachedLimit({
    required this.label,
    required this.percent,
    this.resetsAt,
  });

  final String label;
  final double percent;
  final DateTime? resetsAt;
}

/// Ответ `GET /api/organizations/<org>/usage`, сохранённый в HTTP-кэше.
class CachedUsage {
  const CachedUsage({
    required this.org,
    required this.fetchedAt,
    required this.limits,
  });

  final String org;
  final DateTime fetchedAt;
  final Map<String, CachedLimit> limits;

  static CachedUsage? fromJson(
    Object? json, {
    required String org,
    required DateTime fetchedAt,
  }) {
    if (json is! Map) return null;
    final limits = <String, CachedLimit>{};
    final list = json['limits'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map || item['percent'] is! num) continue;
        final scope = item['scope'];
        final model = scope is Map && scope['model'] is Map
            ? (scope['model'] as Map)['display_name']
            : null;
        final surface = scope is Map ? scope['surface'] : null;
        final name = model is String
            ? model
            : surface is String
            ? surface
            : null;
        final key = switch (item['kind']) {
          'session' => 'session',
          'weekly_all' => 'weekly',
          'weekly_scoped' when name != null => 'weekly:$name',
          _ => null,
        };
        if (key == null) continue;
        limits[key] = CachedLimit(
          label:
              key.startsWith('weekly:') &&
                  !ProfileUsage._labels.containsKey(key)
              ? 'За неделю · $name'
              : ProfileUsage.labelOf(key),
          percent: (item['percent'] as num).toDouble(),
          resetsAt: _date(item['resets_at']),
        );
      }
    } else {
      // Прежний формат ответа — поля окон.
      const fields = {
        'five_hour': 'session',
        'seven_day': 'weekly',
        'seven_day_opus': 'weekly:Opus',
        'seven_day_sonnet': 'weekly:Sonnet',
      };
      for (final MapEntry(:key, :value) in fields.entries) {
        final window = json[key];
        if (window is! Map || window['utilization'] is! num) continue;
        limits[value] = CachedLimit(
          label: ProfileUsage.labelOf(value),
          percent: (window['utilization'] as num).toDouble(),
          resetsAt: _date(window['resets_at']),
        );
      }
    }
    if (limits.isEmpty) return null;
    return CachedUsage(org: org, fetchedAt: fetchedAt, limits: limits);
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

/// Запись простого дискового кэша Chromium (`Cache_Data/<хеш>_0`): ключ, тело
/// ответа, затем сохранённые заголовки.
class ChromiumCacheEntry {
  const ChromiumCacheEntry({
    required this.key,
    required this.body,
    required this.headers,
  });

  final String key;
  final Uint8List body;

  /// Первая строка — статус (`HTTP/1.1 200`), имена заголовков — строчными.
  final List<String> headers;

  static const _magic = 0xfcfb6d1ba7725c30;
  static const _eofMagic = 0xf4fa6f45970d41d8;

  /// Имя файла записи: первые 8 байт SHA-1 ключа как число little-endian.
  static String fileNameFor(String key) {
    final digest = sha1.convert(utf8.encode(key)).bytes;
    final hex = StringBuffer();
    for (var i = 7; i >= 0; i--) {
      hex.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return '${hex}_0';
  }

  static ChromiumCacheEntry? parse(Uint8List bytes) {
    if (bytes.length < 24) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint64(0, Endian.little) != _magic) return null;
    final keyLength = data.getUint32(12, Endian.little);
    final bodyStart = 24 + keyLength;
    if (bodyStart > bytes.length) return null;
    final key = utf8.decode(bytes.sublist(24, bodyStart), allowMalformed: true);
    var eof = -1;
    for (var i = bodyStart; i + 8 <= bytes.length; i++) {
      if (data.getUint64(i, Endian.little) == _eofMagic) {
        eof = i;
        break;
      }
    }
    if (eof < 0) return null;
    // Заголовки — строки через NUL, до двух NUL подряд.
    final status = _indexOf(bytes, ascii.encode('HTTP/'), eof);
    if (status < 0) return null;
    var end = status;
    while (end + 1 < bytes.length &&
        !(bytes[end] == 0 && bytes[end + 1] == 0)) {
      end++;
    }
    final headers = latin1
        .decode(bytes.sublist(status, end))
        .split('\u0000')
        .where((line) => line.isNotEmpty)
        .toList();
    return ChromiumCacheEntry(
      key: key,
      body: bytes.sublist(bodyStart, eof),
      headers: [
        headers.first,
        for (final line in headers.skip(1)) _lowerName(line),
      ],
    );
  }

  String? header(String name) {
    for (final line in headers.skip(1)) {
      if (line.startsWith('$name:')) {
        return line.substring(name.length + 1).trim();
      }
    }
    return null;
  }

  bool get ok => headers.first.split(' ').elementAtOrNull(1) == '200';

  /// Тело без сжатия; null — сжатие, которое лаунчер не разбирает (br).
  Uint8List? get decodedBody => switch (header('content-encoding')) {
    null || 'identity' => body,
    'zstd' => ZstdCodec().decompress(body),
    'gzip' => Uint8List.fromList(gzip.decode(body)),
    _ => null,
  };

  static String _lowerName(String line) {
    final colon = line.indexOf(':');
    return colon < 0
        ? line
        : line.substring(0, colon).toLowerCase() + line.substring(colon);
  }

  static int _indexOf(Uint8List bytes, List<int> pattern, int from) {
    outer:
    for (var i = from; i + pattern.length <= bytes.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// Читает только папки выбранного профиля: историю лимитов и записи HTTP-кэша
/// с ответом `/usage`. Не читает cookies, токены и Связку ключей, не меняет
/// файлы Claude.
class ProfileUsageReader {
  const ProfileUsageReader();

  /// Запросы, которыми Claude получает лимиты. Запись кэша ищется по имени —
  /// хешу ключа, без обхода тысяч файлов кэша.
  static const _queries = ['', '?skip_spend=1', '?cedar_ember=1&skip_spend=1'];

  static final _uuid = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  );

  Future<ProfileUsage?> read(List<String> dataDirs, {DateTime? now}) async {
    final history = <UsageSample>[];
    final cached = <CachedUsage>[];
    Object? failure;
    for (final dir in dataDirs) {
      final orgs = <String>{};
      try {
        final file = File(p.join(dir, 'plan-usage-history.json'));
        if (await file.exists()) {
          final samples = UsageSample.parseHistory(
            jsonDecode(await file.readAsString()),
          );
          history.addAll(samples);
          orgs.addAll(samples.map((s) => s.org).nonNulls);
        }
      } on FormatException catch (error) {
        failure = error;
      } on FileSystemException catch (error) {
        failure = error;
      }
      orgs.addAll(await _configOrgs(dir));
      for (final org in orgs) {
        final usage = await _cachedUsage(dir, org);
        if (usage != null) cached.add(usage);
      }
    }
    final usage = ProfileUsage.combine(
      history: history,
      cached: cached,
      now: now ?? DateTime.now(),
    );
    if (usage == null && failure != null) throw failure;
    return usage;
  }

  /// Организации, которые Claude упоминает в своих настройках, — на случай,
  /// если истории ещё нет.
  Future<Set<String>> _configOrgs(String dir) async {
    try {
      final text = await File(p.join(dir, 'config.json')).readAsString();
      final json = jsonDecode(text);
      if (json is! Map) return {};
      return {
        for (final key in json.keys)
          if (key is String && key.startsWith('dxt:'))
            ?_uuid.firstMatch(key)?.group(0),
      };
    } on Object {
      return {};
    }
  }

  Future<CachedUsage?> _cachedUsage(String dir, String org) async {
    CachedUsage? newest;
    for (final query in _queries) {
      final key = '1/0/https://claude.ai/api/organizations/$org/usage$query';
      final file = File(
        p.join(dir, 'Cache', 'Cache_Data', ChromiumCacheEntry.fileNameFor(key)),
      );
      try {
        if (!await file.exists()) continue;
        final entry = ChromiumCacheEntry.parse(await file.readAsBytes());
        if (entry == null || entry.key != key || !entry.ok) continue;
        final body = entry.decodedBody;
        final date = entry.header('date');
        if (body == null || date == null) continue;
        final usage = CachedUsage.fromJson(
          jsonDecode(utf8.decode(body)),
          org: org,
          fetchedAt: HttpDate.parse(date).toLocal(),
        );
        if (usage != null &&
            (newest == null || usage.fetchedAt.isAfter(newest.fetchedAt))) {
          newest = usage;
        }
      } on Object {
        // Запись перезаписывается Claude или в незнакомом формате — пропускаем.
        continue;
      }
    }
    return newest;
  }
}
