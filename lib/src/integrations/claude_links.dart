import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../claude/link_handler_platform.dart';
import '../launcher_controller.dart';
import '../profile.dart';

/// Что за ссылка `claude://` — от этого зависит, какому профилю её отдать.
enum ClaudeLinkKind {
  /// Вход: `claude://login/…`, письмо со ссылкой (`claude.ai/magic-link`),
  /// SSO (`claude.ai/sso-callback`).
  login,

  /// Сессия Claude Code: `claude://claude.ai/epitaxy/local_…`.
  session,

  /// Всё остальное (Cowork, предпросмотр, горячие клавиши…).
  other,
}

/// Куда отдать ссылку (см. [ClaudeLinks.route]).
sealed class LinkRoute {
  const LinkRoute();
}

/// В профиль [profile]; [launch] — он закрыт, сначала открыть.
class DeliverLink extends LinkRoute {
  const DeliverLink(this.profile, {this.launch = false});

  final Profile profile;
  final bool launch;
}

/// Однозначного получателя нет — спросить пользователя среди [candidates].
class AskForProfile extends LinkRoute {
  const AskForProfile(this.candidates);

  final List<Profile> candidates;
}

abstract final class ClaudeLinks {
  /// Вход ждёт профиль, который открыли недавно: ссылку из письма приносят
  /// через минуту-другую, а не через час.
  static const loginWindow = Duration(minutes: 10);

  static ClaudeLinkKind kindOf(Uri link) {
    if (link.host == 'login') return ClaudeLinkKind.login;
    if (link.host == 'claude.ai') {
      final segments = link.pathSegments;
      final first = segments.isEmpty ? null : segments.first;
      if (first == 'magic-link' || first == 'sso-callback') {
        return ClaudeLinkKind.login;
      }
      if (first == 'epitaxy' && segments.length > 1) {
        return ClaudeLinkKind.session;
      }
    }
    return ClaudeLinkKind.other;
  }

  static String? sessionIdOf(Uri link) =>
      kindOf(link) == ClaudeLinkKind.session ? link.pathSegments[1] : null;

  /// Для журнала: без параметров и хвоста — в ссылке входа там код.
  static String describe(Uri link) {
    final first = link.pathSegments.isEmpty ? '' : link.pathSegments.first;
    return 'claude://${link.host}/$first';
  }

  /// Правила:
  /// - сессия — в профиль, где она лежит ([sessionOwner]), открыв его, если закрыт;
  /// - вход — в открытый профиль, запущенный последним за [loginWindow]; если
  ///   такого нет, но открыт ровно один — в него; иначе спросить;
  /// - остальное — в открытый профиль, запущенный последним; если открытых
  ///   нет — открыть [fallback] (профиль по умолчанию) или последний.
  static LinkRoute route({
    required ClaudeLinkKind kind,
    required List<Profile> profiles,
    required bool Function(Profile) isRunning,
    required DateTime now,
    Profile? sessionOwner,
    String? fallback,
  }) {
    if (sessionOwner != null) {
      return DeliverLink(sessionOwner, launch: !isRunning(sessionOwner));
    }
    final running = _byLaunch(profiles.where(isRunning));
    if (kind == ClaudeLinkKind.login) {
      final recent = running.where(
        (profile) =>
            profile.lastLaunchedAt != null &&
            now.difference(profile.lastLaunchedAt!) <= loginWindow,
      );
      if (recent.isNotEmpty) return DeliverLink(recent.first);
      if (running.length == 1) return DeliverLink(running.single);
      return AskForProfile(running.isEmpty ? profiles : running);
    }
    if (running.isNotEmpty) return DeliverLink(running.first);
    final byDefault = profiles.where((profile) => profile.id == fallback);
    final target = byDefault.isNotEmpty
        ? byDefault.first
        : _byLaunch(profiles).firstOrNull;
    return target == null
        ? const AskForProfile([])
        : DeliverLink(target, launch: true);
  }

  /// Сначала запущенные позже; без времени запуска — в конце.
  static List<Profile> _byLaunch(Iterable<Profile> profiles) =>
      profiles.toList()..sort((a, b) {
        final at = a.lastLaunchedAt, bt = b.lastLaunchedAt;
        if (at != null && bt != null) return bt.compareTo(at);
        if (at == null && bt == null) return 0;
        return at == null ? 1 : -1;
      });
}

/// Лаунчер — обработчик ссылок `claude://`: ссылка входа из письма попадает в
/// профиль, который ждёт входа, а не в тот экземпляр Claude, что выберет
/// система.
///
/// Claude при каждом запуске забирает роль обработчика себе, поэтому после
/// запуска профиля лаунчер возвращает её через 2, 5, 10 и 20 секунд и
/// проверяет раз в 30 секунд. Прежний обработчик запоминается и
/// возвращается при выключении настройки, выходе и `--cleanup`.
///
/// Windows: если в «Приложениях по умолчанию» для `claude` выбран Claude,
/// лаунчер этого изменить не может — [blocked], и интерфейс просит выбрать
/// лаунчер там.
class ClaudeLinkHandler extends ChangeNotifier {
  ClaudeLinkHandler({
    required this.launcher,
    required this.settings,
    required this.platform,
    required this.sessionOwner,
    required this.choose,
    DateTime Function()? now,
    this.bootDelay = const Duration(seconds: 3),
  }) : _now = now ?? DateTime.now;

  final LauncherController launcher;
  final AppSettings settings;
  final LinkHandlerPlatform platform;

  /// Профиль, в котором лежит сессия Code с этим id (`local_…`).
  final Future<Profile?> Function(String sessionId) sessionOwner;

  /// Спросить пользователя, какому профилю отдать ссылку; `null` — отказался.
  final Future<Profile?> Function(List<Profile> candidates, ClaudeLinkKind kind)
  choose;

  /// Сколько дать только что запущенному Claude, прежде чем отдать ему ссылку.
  final Duration bootDelay;

  final DateTime Function() _now;
  Timer? _poll;
  final _reclaims = <Timer>[];
  Set<int> _pids = {};
  bool? _enabled;

  /// Ссылки открывает не лаунчер, и сам он это изменить не может (Windows:
  /// выбор пользователя в «Приложениях по умолчанию»).
  bool get blocked => _blocked;
  bool _blocked = false;

  /// [initial] — ссылки из аргументов запуска (Windows: `--open-url`).
  Future<void> start({List<String> initial = const []}) async {
    _pids = _runningPids();
    settings.addListener(_onSettings);
    launcher.addListener(_onLauncher);
    await _onSettings();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _reclaim());
    for (final link in initial) {
      await handleString(link);
    }
    await drain();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    launcher.removeListener(_onLauncher);
    _poll?.cancel();
    for (final timer in _reclaims) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _onSettings() async {
    if (_enabled == settings.claudeLinks) return;
    _enabled = settings.claudeLinks;
    await (settings.claudeLinks ? _reclaim() : release());
  }

  /// Запустился новый Claude — он заберёт роль себе, как только загрузится.
  void _onLauncher() {
    final pids = _runningPids();
    final started = pids.difference(_pids).isNotEmpty;
    _pids = pids;
    if (!started || !settings.claudeLinks) return;
    for (final seconds in const [2, 5, 10, 20]) {
      _reclaims.add(Timer(Duration(seconds: seconds), _reclaim));
    }
    _reclaims.removeWhere((timer) => !timer.isActive);
  }

  Set<int> _runningPids() => {
    for (final instance in launcher.instances) instance.pid,
  };

  Future<void> _reclaim() async {
    if (!settings.claudeLinks) return;
    try {
      final own = await platform.ownId();
      if (own == null) return;
      final current = await platform.currentHandler();
      if (current != own) {
        if (current != null && current != settings.previousLinkHandler) {
          await settings.setPreviousLinkHandler(current);
        }
        await platform.claim();
      }
      _setBlocked(await platform.blocker() != null);
    } catch (error) {
      debugPrint('Не удалось стать обработчиком claude://: $error');
    }
  }

  /// Для диагностики: ссылки сейчас открывает лаунчер.
  Future<bool> owned() async {
    final own = await platform.ownId();
    return own != null && await platform.currentHandler() == own;
  }

  /// «Исправить» в диагностике — забрать роль обработчика сейчас.
  Future<void> reclaim() => _reclaim();

  void _setBlocked(bool value) {
    if (_blocked == value) return;
    _blocked = value;
    notifyListeners();
  }

  /// Вернуть роль прежнему обработчику; чужую роль платформа не трогает.
  Future<void> release() async {
    _setBlocked(false);
    try {
      await platform.restore(settings.previousLinkHandler);
    } catch (error) {
      debugPrint('Не удалось вернуть обработчик claude://: $error');
    }
  }

  /// Забрать ссылки, которые система уже отдала (macOS), и разослать их.
  Future<void> drain() async {
    for (final link in await platform.takeLinks()) {
      await handleString(link);
    }
  }

  Future<void> handleString(String link) async {
    final uri = Uri.tryParse(link);
    if (uri != null && uri.scheme == 'claude') await handle(uri);
  }

  Future<void> handle(Uri link) async {
    final kind = ClaudeLinks.kindOf(link);
    final sessionId = ClaudeLinks.sessionIdOf(link);
    final route = ClaudeLinks.route(
      kind: kind,
      profiles: launcher.profiles,
      isRunning: launcher.isRunning,
      now: _now(),
      sessionOwner: sessionId == null ? null : await sessionOwner(sessionId),
      fallback: settings.startupProfileId,
    );
    final (profile, launch) = switch (route) {
      DeliverLink(:final profile, :final launch) => (profile, launch),
      AskForProfile(:final candidates) => (
        candidates.isEmpty ? null : await choose(candidates, kind),
        false,
      ),
    };
    if (profile == null) return;
    debugPrint('claude: ${ClaudeLinks.describe(link)} → «${profile.name}»');
    if (launch || !launcher.isRunning(profile)) {
      await launcher.switchTo(profile);
      if (!launcher.isRunning(profile)) return;
      await Future<void>.delayed(bootDelay);
    }
    await launcher.openLink(profile, link);
  }
}
