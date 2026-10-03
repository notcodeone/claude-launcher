import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Кто вошёл в профиль Claude — по файлам, которые Claude пишет сам. Без
/// токенов и cookies: только идентификаторы, почта и название организации.
///
/// Источники и их надёжность — docs/dev/research/claude-desktop-data.md,
/// «Аккаунт и организация». Каждое значение берётся, только если источники
/// не противоречат друг другу; иначе — `null`, без угадывания: от аккаунта и
/// организации зависит, в какую папку перенос положит сессию.
class ProfileIdentity {
  const ProfileIdentity({
    this.accountUuid,
    this.orgUuid,
    this.email,
    this.orgName,
  });

  final String? accountUuid;
  final String? orgUuid;
  final String? email;
  final String? orgName;

  /// Известны аккаунт и организация — можно найти папку сессий профиля.
  bool get resolved => accountUuid != null && orgUuid != null;

  /// Папка карточек сессий Code профиля относительно его папки данных.
  String? get sessionsFolder =>
      resolved ? p.join('claude-code-sessions', accountUuid, orgUuid) : null;

  static const unknown = ProfileIdentity();

  /// [dataDirs] — папки данных профиля (у пакета MSIX — ещё копия в папке
  /// пакета); [claudeCodeConfigs] — `.claude.json` Claude Code, где может
  /// быть `oauthAccount`: свой у профиля со своей памятью, общий — у остальных.
  static Future<ProfileIdentity> read({
    required List<String> dataDirs,
    required List<String> claudeCodeConfigs,
  }) async {
    String? lastKnown, owner, blocklistOrg;
    final dxtOrgs = <String>{};
    final cardFolders = <(String, String)>{};
    for (final dir in dataDirs) {
      final config = await _json(p.join(dir, 'config.json'));
      if (config is Map) {
        lastKnown ??= _uuid(config['lastKnownAccountUuid']);
        for (final key in config.keys) {
          if (key is String && key.startsWith(_dxtPrefix)) {
            if (_uuid(key.substring(_dxtPrefix.length)) case final org?) {
              dxtOrgs.add(org);
            }
          }
        }
      }
      final ops = await _json(p.join(dir, 'cowork-enabled-cli-ops.json'));
      if (ops is Map) owner ??= _uuid(ops['ownerAccountId']);
      blocklistOrg ??= _orgFromBlocklist(
        await _json(p.join(dir, 'extensions-blocklist.json')),
      );
      cardFolders.addAll(await _cardFolders(dir));
    }

    // Аккаунт: последний вошедший; второй источник, если есть, должен совпасть.
    final account = owner == null || owner == lastKnown ? lastKnown : null;
    if (account == null) return unknown;

    // Claude Code этого аккаунта: почта, организация и её название.
    Map<Object?, Object?>? oauth;
    for (final path in claudeCodeConfigs) {
      final json = await _json(path);
      if (json case {
        'oauthAccount': final Map<Object?, Object?> found,
      } when found['accountUuid'] == account) {
        oauth = found;
        break;
      }
    }
    final oauthOrg = _uuid(oauth?['organizationUuid']);

    // Организация: из списка расширений, иначе из Claude Code; если есть оба —
    // должны совпасть. Без них — единственная папка сессий этого аккаунта.
    final orgs = {?blocklistOrg, ?oauthOrg};
    final accountFolders = {
      for (final (acc, org) in cardFolders)
        if (acc == account) org,
    };
    final String? org = switch (orgs.length) {
      1 => orgs.single,
      0 when accountFolders.length == 1 => accountFolders.single,
      _ => null,
    };
    // Организация, о которой Claude ничего не знает, — признак старых данных.
    final known =
        org != null &&
        (dxtOrgs.isEmpty || dxtOrgs.contains(org) || org == oauthOrg);

    return ProfileIdentity(
      accountUuid: account,
      orgUuid: known ? org : null,
      email: _text(oauth?['emailAddress']),
      orgName: org != null && org == oauthOrg
          ? _text(oauth?['organizationName'])
          : null,
    );
  }

  static const _dxtPrefix = 'dxt:allowlistLastUpdated:';

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static String? _uuid(Object? value) =>
      value is String && _uuidPattern.hasMatch(value) ? value : null;

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _orgFromBlocklist(Object? json) {
    final orgs = {
      for (final match in RegExp(
        r'/organizations/([0-9a-f-]{36})/',
      ).allMatches(jsonEncode(json)))
        ?_uuid(match[1]),
    };
    return orgs.length == 1 ? orgs.single : null;
  }

  static Future<Set<(String, String)>> _cardFolders(String dataDir) async {
    final root = Directory(p.join(dataDir, 'claude-code-sessions'));
    final result = <(String, String)>{};
    try {
      await for (final account in root.list()) {
        if (account is! Directory) continue;
        final accountId = _uuid(p.basename(account.path));
        if (accountId == null) continue;
        await for (final org in account.list()) {
          if (org is! Directory) continue;
          if (_uuid(p.basename(org.path)) case final orgId?) {
            result.add((accountId, orgId));
          }
        }
      }
    } on FileSystemException {
      // Сессий Code в профиле ещё не было.
    }
    return result;
  }

  /// Файл JSON не больше 8 МБ; нет, не читается или испорчен — `null`.
  static Future<Object?> _json(String path) async {
    try {
      final file = File(path);
      if (await file.length() > 8 * 1024 * 1024) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }
}
