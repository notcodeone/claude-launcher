import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_identity.dart';

/// Сессия Code из карточки, которую хранит сам Claude
/// (`claude-code-sessions/<аккаунт>/<организация>/local_….json`).
class SessionCard {
  const SessionCard({
    required this.id,
    required this.cliSessionId,
    required this.cwd,
    required this.title,
    required this.lastActivity,
    this.model,
  });

  /// `local_…` — по нему Claude открывает сессию ссылкой.
  final String id;
  final String cliSessionId;
  final String cwd;

  /// Название из боковой панели Claude, иначе — папка проекта.
  final String title;
  final DateTime lastActivity;
  final String? model;
}

/// Сессии одного профиля.
class ProfileSessions {
  const ProfileSessions({
    required this.profile,
    required this.identity,
    required this.sessions,
    this.unreadable = 0,
    this.tokensToday,
  });

  final Profile profile;
  final ProfileIdentity identity;

  /// Не в архиве, последние сверху.
  final List<SessionCard> sessions;

  /// Карточки незнакомого вида — Claude поменял формат. Переносить такие
  /// нельзя, показывать — то, что поняли.
  final int unreadable;

  bool get formatKnown => unreadable == 0;

  /// Сколько токенов Claude написал сегодня в этом профиле — его собственный
  /// счётчик (`buddy-tokens.json`); `null` — сегодня не считал.
  final int? tokensToday;
}

/// Проект (папка на диске) и его сессии по профилям.
class SessionProject {
  SessionProject(this.cwd);

  final String cwd;
  final Map<String, List<SessionCard>> byProfile = {};

  DateTime get lastActivity => byProfile.values
      .expand((sessions) => sessions)
      .map((session) => session.lastActivity)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Обзор сессий Code всех профилей — только чтение.
abstract final class SessionOverview {
  /// Карточка больше этого — не карточка (самые большие ~1,4 МБ).
  static const _maxCard = 4 * 1024 * 1024;

  static Future<List<ProfileSessions>> read(LauncherController launcher) async {
    return [
      for (final profile in launcher.profiles)
        await readProfile(
          profile,
          dataDirs: launcher.readableDataDirsOf(profile),
          claudeCodeConfigs: launcher.claudeCodeConfigsOf(profile),
        ),
    ];
  }

  static Future<ProfileSessions> readProfile(
    Profile profile, {
    required List<String> dataDirs,
    required List<String> claudeCodeConfigs,
  }) async {
    final identity = await ProfileIdentity.read(
      dataDirs: dataDirs,
      claudeCodeConfigs: claudeCodeConfigs,
    );
    final tokens = await tokensToday(dataDirs, DateTime.now());
    final folder = identity.sessionsFolder;
    if (folder == null) {
      return ProfileSessions(
        profile: profile,
        identity: identity,
        sessions: const [],
        tokensToday: tokens,
      );
    }
    final sessions = <String, SessionCard>{};
    var unreadable = 0;
    for (final dataDir in dataDirs) {
      final dir = Directory(p.join(dataDir, folder));
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is! File ||
            !name.startsWith('local_') ||
            p.extension(name) != '.json') {
          continue;
        }
        switch (await _card(entity)) {
          case final SessionCard card:
            sessions.putIfAbsent(card.id, () => card);
          case false:
            unreadable++;
          case _:
          // В архиве — не показываем.
        }
      }
    }
    return ProfileSessions(
      profile: profile,
      identity: identity,
      sessions: sessions.values.toList()
        ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity)),
      unreadable: unreadable,
      tokensToday: tokens,
    );
  }

  /// `buddy-tokens.json` → `tokens-today` за сегодняшнюю дату (`ГГГГ-ММ-ДД`).
  static Future<int?> tokensToday(List<String> dataDirs, DateTime now) async {
    String two(int value) => value.toString().padLeft(2, '0');
    final today = '${now.year}-${two(now.month)}-${two(now.day)}';
    for (final dir in dataDirs) {
      try {
        final json = jsonDecode(
          await File(p.join(dir, 'buddy-tokens.json')).readAsString(),
        );
        if (json case {
          'tokens-today': {'date': final String date, 'tokens': final int n},
        } when date == today) {
          return n;
        }
      } catch (_) {
        // Нет файла или Claude как раз его пишет.
      }
    }
    return null;
  }

  /// Сколько места занимают папки профиля, байт. Обходит все файлы — для
  /// страницы, а не для опроса.
  static Future<int> diskUsage(List<String> dataDirs) async {
    var total = 0;
    for (final dir in dataDirs) {
      try {
        await for (final entity in Directory(
          dir,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              total += await entity.length();
            } on FileSystemException {
              // Файл удалили, пока считали.
            }
          }
        }
      } on FileSystemException {
        // Папки нет или нет доступа к её части.
      }
    }
    return total;
  }

  /// Карточка; `false` — незнакомого вида; `null` — в архиве.
  static Future<Object?> _card(File file) async {
    try {
      if (await file.length() > _maxCard) return false;
      final json = jsonDecode(await file.readAsString());
      if (json case {
        'sessionId': final String id,
        'cliSessionId': final String cliSessionId,
        'cwd': final String cwd,
        'lastActivityAt': final int lastActivityAt,
      } when id.startsWith('local_')) {
        if (json['isArchived'] == true) return null;
        final title = json['title'];
        final model = json['model'];
        return SessionCard(
          id: id,
          cliSessionId: cliSessionId,
          cwd: cwd,
          title: title is String && title.trim().isNotEmpty
              ? title.trim()
              : p.basename(cwd),
          lastActivity: DateTime.fromMillisecondsSinceEpoch(lastActivityAt),
          model: model is String && model.isNotEmpty ? model : null,
        );
      }
      return false;
    } on FormatException {
      // Claude как раз пишет карточку — прочитаем в следующий раз.
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Проекты, последние по активности сверху.
  static List<SessionProject> projects(List<ProfileSessions> profiles) {
    final byCwd = <String, SessionProject>{};
    for (final profile in profiles) {
      for (final session in profile.sessions) {
        (byCwd[session.cwd] ??= SessionProject(
          session.cwd,
        )).byProfile.putIfAbsent(profile.profile.id, () => []).add(session);
      }
    }
    return byCwd.values.toList()
      ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
  }
}
