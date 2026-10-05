import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../claude/claude_credentials.dart';
import '../http_proxy.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_usage.dart';

/// Свежие лимиты от Anthropic — тем же запросом, которым их получает сам
/// Claude (`GET /api/oauth/usage` с токеном профиля).
///
/// Запрос — только когда пользователь открыл лимиты (меню на карточке или
/// страницу «Лимиты»), не в фоне: так решил автор, чтобы не слать Anthropic
/// лишнего. Ответ живёт минуту, как у самого Claude: повторное открытие в эту
/// минуту сервер не трогает.
class LiveUsage extends ChangeNotifier {
  LiveUsage({
    required this.launcher,
    ClaudeCredentials? credentials,
    this.allowed,
    Future<Object?> Function(String token)? request,
    DateTime Function()? now,
  }) : _credentials = credentials ?? ClaudeCredentials(),
       _request = request ?? _get,
       _now = now ?? DateTime.now;

  final LauncherController launcher;
  final ClaudeCredentials _credentials;

  /// Можно ли сейчас выходить в сеть от имени профиля: при Kill Switch с
  /// закрытым затвором или в неподходящей стране — нельзя, запрос ушёл бы мимо
  /// защиты.
  final bool Function()? allowed;

  final Future<Object?> Function(String token) _request;
  final DateTime Function() _now;

  static const fresh = Duration(minutes: 1);

  /// «Проверить снова» — вручную, но не чаще: двойной клик не шлёт два запроса.
  static const freshManual = Duration(seconds: 10);
  static const endpoint = '${ClaudeCredentials.apiHost}/api/oauth/usage';

  final _cache = <String, ({DateTime at, ProfileUsage usage})>{};
  final _inFlight = <String, Future<ProfileUsage?>>{};

  /// Идёт запрос к Anthropic — статус в шапке.
  bool get fetching => _inFlight.isNotEmpty;

  /// macOS: доступ к «Claude Safe Storage» по согласию пользователя.
  Future<bool> unlock() => _credentials.unlock();

  /// Последний ответ для аккаунта профиля — без запроса.
  ProfileUsage? cached(Profile profile) => _cache[_keyOf(profile)]?.usage;

  /// Свежие лимиты профиля: из ответа младше минуты или новым запросом.
  /// `null` — нет входа, нет доступа к ключу, сеть нельзя или сервер отказал;
  /// тогда показываем данные из файлов Claude.
  /// [manual] — «Проверить снова»: ответ старше 10 секунд уже не годится.
  Future<ProfileUsage?> fetch(Profile profile, {bool manual = false}) {
    final key = _keyOf(profile);
    if (key == null) return Future.value();
    final hit = _cache[key];
    if (hit != null &&
        _now().difference(hit.at) < (manual ? freshManual : fresh)) {
      return Future.value(hit.usage);
    }
    if (!_inFlight.containsKey(key)) {
      // Уведомить после постановки запроса в очередь (ниже), не до.
      scheduleMicrotask(notifyListeners);
    }
    // Блок, а не `=>`: `remove` вернул бы этот же запрос, и whenComplete
    // ждал бы сам себя.
    return _inFlight[key] ??= _fetch(profile, key).whenComplete(() {
      _inFlight.remove(key);
      notifyListeners();
    });
  }

  String? _keyOf(Profile profile) {
    final identity = launcher.identities[profile.id];
    final account = identity?.accountUuid;
    final org = identity?.orgUuid;
    return account == null || org == null ? null : '$account|$org';
  }

  Future<ProfileUsage?> _fetch(Profile profile, String key) async {
    if (!(allowed?.call() ?? true)) return null;
    final identity = launcher.identities[profile.id]!;
    try {
      String? token;
      for (final dir in launcher.readableDataDirsOf(profile)) {
        token = await _credentials.accessToken(
          dataDir: dir,
          account: identity.accountUuid!,
          org: identity.orgUuid!,
        );
        if (token != null) break;
      }
      if (token == null) return null;
      final usage = ProfileUsage.fromOAuthUsage(await _request(token));
      if (usage != null) _cache[key] = (at: _now(), usage: usage);
      return usage;
    } catch (error) {
      // Без текста ответа и заголовков — там может быть токен.
      debugPrint('Лимиты от Anthropic не получены: ${error.runtimeType}');
      return null;
    }
  }

  static Future<Object?> _get(String token) async {
    final client = HttpClient()
      ..findProxy = launcherProxy
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 10));
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..headers.set('anthropic-beta', 'oauth-2025-04-20');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}
