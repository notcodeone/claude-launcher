import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_settings.dart';
import '../launcher_controller.dart';
import '../notifications.dart';
import '../profile.dart';
import 'claude_code_events.dart';
import 'claude_code_hooks.dart';
import 'claude_code_sessions.dart';
import 'code_notifications.dart';
import 'notification_handoff.dart';

/// События Claude Code: подключение хуков, приём событий, сессии открытого
/// профиля (показываются на его карточке) и уведомления о них вместо самих
/// Claude. Задел для уведомлений в Telegram.
class ClaudeCodeIntegration extends ChangeNotifier {
  ClaudeCodeIntegration({
    required this.settings,
    required this.launcher,
    ClaudeCodeHooks? hooks,
    ValueListenable<bool>? windowVisible,
    this.handoff,
    this.notifier,
    this.onOpenWindow,
    this.tickInterval = const Duration(seconds: 1),
  }) : hooks = hooks ?? ClaudeCodeHooks.forCurrentUser(),
       windowVisible = windowVisible ?? ValueNotifier(true) {
    launcher.addListener(_onLauncherChanged);
    this.windowVisible.addListener(_updateWatching);
    notifier?.onTap = _onNotificationTap;
  }

  final AppSettings settings;
  final LauncherController launcher;
  final ClaudeCodeHooks hooks;

  /// Выключает уведомления самих Claude, пока их показывает лаунчер. Без него
  /// (или без [notifier]) лаунчер уведомлений не показывает и Claude не трогает.
  final NotificationHandoff? handoff;
  final Notifier? notifier;

  /// Окно лаунчера — по нажатию на уведомление, которое некуда открыть в Claude.
  final VoidCallback? onOpenWindow;

  /// Открыто ли окно лаунчера. Пока закрыто, время и токены не считаем.
  final ValueListenable<bool> windowVisible;

  /// Как часто обновлять время и токены работающих сессий.
  final Duration tickInterval;

  ClaudeCodeEventServer? _server;
  Timer? _ticker;
  Future<void> _reading = Future.value();
  String _watchKey = '';
  bool _disposed = false;

  final sessions = ClaudeCodeSessions();

  /// Почему не удалось подключить или отключить события — видно в настройках.
  String? error;

  bool get connected => _server?.port != null;

  /// Уведомления Claude Code сейчас показывает лаунчер, а не сами Claude.
  bool get notifying => _notifying;
  bool _notifying = false;

  /// Системные уведомления лаунчеру запрещены — тогда их показывают сами Claude.
  bool notificationsDenied = false;

  /// Почему не удалось выключить или вернуть уведомления Claude.
  String? notificationsError;

  Future<void> _syncing = Future.value();
  String _dirsKey = '';

  /// Сессии, о которых сейчас висит уведомление.
  final _shown = <String>{};

  /// При запуске лаунчера: поднимает приём, если события включены, и забирает
  /// уведомления у Claude (в том числе у наблюдателя, если он ещё работает).
  Future<void> start() async {
    await handoff?.claim();
    if (settings.claudeCodeEvents) await _connect();
    await _syncNotifications();
  }

  Future<void> setEnabled(bool enabled) async {
    await settings.setClaudeCodeEvents(enabled);
    if (enabled) {
      await _connect();
    } else {
      await _disconnect();
    }
    await _syncNotifications();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    await settings.setLauncherNotifications(enabled);
    await _syncNotifications();
  }

  /// Выход из лаунчера: возвращает Claude их уведомления. Возвращает, есть ли
  /// открытые Claude, которым вернуть их можно только после закрытия.
  Future<bool> releaseOnQuit() async {
    final handoff = this.handoff;
    if (handoff == null) return false;
    _notifying = false;
    await launcher.refresh();
    final result = await handoff.sync(
      active: false,
      profiles: _profileDirs,
      running: _runningDirs,
    );
    await handoff.resign();
    return result.pending;
  }

  /// Перед запуском Claude лаунчером: если уведомления показывает лаунчер,
  /// выключает их у этого Claude.
  Future<void> beforeLaunch(String dataDir) async {
    final handoff = this.handoff;
    if (handoff == null || !_notifying) return;
    final error = await handoff.takeBeforeLaunch(dataDir);
    if (error != null) {
      notificationsError = 'Не удалось выключить уведомления Claude: $error';
      _notify();
    }
  }

  List<String> get _profileDirs => [
    for (final profile in launcher.profiles) launcher.dataDirOf(profile),
  ];

  List<String> get _runningDirs => [
    for (final instance in launcher.instances)
      launcher.host.dataDirOf(instance),
  ];

  /// Кто показывает уведомления: лаунчер (если события подключены, уведомления
  /// включены и система их разрешает) или сами Claude.
  Future<void> _syncNotifications() => _syncing = _syncing.then((_) async {
    final handoff = this.handoff;
    final notifier = this.notifier;
    if (handoff == null || notifier == null || _disposed) return;
    var active = connected && settings.launcherNotifications;
    if (active) {
      try {
        notificationsDenied = !await notifier.allowed();
      } catch (e) {
        debugPrint('Не удалось проверить разрешение на уведомления: $e');
        notificationsDenied = true;
      }
      active = !notificationsDenied;
    }
    final result = await handoff.sync(
      active: active,
      profiles: _profileDirs,
      running: _runningDirs,
    );
    _notifying = active;
    notificationsError = switch (result.error) {
      final error? => 'Не удалось изменить уведомления Claude: $error',
      null => null,
    };
    _notify();
  });

  Future<void> _connect() async {
    try {
      final server = _server ??= ClaudeCodeEventServer(
        token: settings.eventsToken,
        onEvent: _onEvent,
      );
      final port = await server.start(settings.eventsPort);
      if (port != settings.eventsPort) await settings.setEventsPort(port);
      final token = settings.eventsToken;
      // Обновление лаунчера с новыми событиями тоже переустановит хуки.
      if (!await hooks.isInstalled(port: port, token: token)) {
        await hooks.install(port: port, token: token);
      }
      error = null;
    } catch (e) {
      await _server?.stop();
      _server = null;
      error = 'Не удалось подключить события Claude Code: $e';
    }
    _notify();
  }

  Future<void> _disconnect() async {
    await _server?.stop();
    _server = null;
    _ticker?.cancel();
    _ticker = null;
    sessions.clear();
    _shown.clear();
    try {
      await hooks.uninstall();
      error = null;
    } catch (e) {
      error = 'Не удалось убрать хуки из ~/.claude/settings.json: $e';
    }
    _notify();
  }

  /// Одновременно открыт один профиль — событие относится к нему.
  /// Состояние (и точка на свёрнутой карточке) меняется сразу, а переписку
  /// дочитываем, только если время и токены сейчас видны. Уведомляем и без
  /// открытого профиля: сессия может идти в терминале.
  Future<void> _onEvent(ClaudeCodeEvent event) async {
    final running = launcher.runningProfiles;
    final profile = running.length == 1 ? running.single : null;
    final before = sessions.byId(event.sessionId)?.state;
    if (profile != null) {
      sessions.handle(event, profile.id);
      _notify();
    }
    await _showNotification(event, before, profile);
    if (profile != null) await _refresh();
  }

  Future<void> _showNotification(
    ClaudeCodeEvent event,
    CodeSessionState? before,
    Profile? profile,
  ) async {
    final notifier = this.notifier;
    if (notifier == null || !_notifying || event.sessionId.isEmpty) return;
    final id = notificationIdOf(event.sessionId);
    final session = sessions.byId(event.sessionId);
    try {
      if (clearsNotification(event, after: session?.state)) {
        if (_shown.remove(event.sessionId)) await notifier.cancel(id);
        return;
      }
      final body = notificationBody(
        event,
        before: before,
        elapsed: session == null
            ? null
            : event.time.difference(session.startedAt),
      );
      if (body == null) return;
      // Пользователь и так смотрит в Claude — приложение в этом случае тоже молчит.
      if (event.hostSessionId.isNotEmpty &&
          profile != null &&
          await _claudeInFront(profile)) {
        return;
      }
      final title =
          await ClaudeCodeSessions.titleOf(event.transcriptPath) ??
          session?.name ??
          (event.cwd.isEmpty ? 'Claude Code' : p.basename(event.cwd));
      await notifier.show(
        id: id,
        title: title,
        body: body,
        payload: event.hostSessionId,
      );
      _shown.add(event.sessionId);
    } catch (e) {
      debugPrint('Не удалось показать уведомление: $e');
    }
  }

  Future<bool> _claudeInFront(Profile profile) async {
    for (final instance in launcher.instances) {
      if (launcher.profileOf(instance)?.id != profile.id) continue;
      try {
        if (await launcher.host.isFrontmost(instance)) return true;
      } catch (e) {
        debugPrint('Не удалось узнать активное окно: $e');
      }
    }
    return false;
  }

  /// Сессию приложения открываем в Claude, остальное — окно лаунчера.
  void _onNotificationTap(String hostSessionId) {
    final link = CodeSession.linkFor(hostSessionId);
    final running = launcher.runningProfiles;
    if (link != null && running.length == 1) {
      launcher.openLink(running.single, link);
    } else {
      onOpenWindow?.call();
    }
  }

  /// Время и токены видны, только когда окно открыто, а карточка профиля
  /// развёрнута. Переписку остальных сессий не читаем вовсе.
  bool _watched(CodeSession session) {
    if (!windowVisible.value) return false;
    for (final profile in launcher.profiles) {
      if (profile.id == session.profileId) return !profile.sessionsCollapsed;
    }
    return false;
  }

  void _onLauncherChanged() {
    _prune();
    _updateWatching();
    // Claude открыли или закрыли, профиль добавили или убрали — сверяем,
    // у кого выключены уведомления.
    final key = [..._profileDirs, '|', ..._runningDirs].join('\n');
    if (key == _dirsKey) return;
    _dirsKey = key;
    _syncNotifications();
  }

  /// Окно открыли или карточку развернули — сразу догоняем переписку;
  /// закрыли или свернули — перестаём обновлять.
  void _updateWatching() {
    final key = [
      windowVisible.value,
      for (final profile in launcher.profiles)
        if (!profile.sessionsCollapsed) profile.id,
    ].join(',');
    if (key == _watchKey) return;
    _watchKey = key;
    _refresh();
  }

  Future<void> _refresh() async {
    await _readWatched();
    _syncTicker();
    _notify();
  }

  /// По очереди: два чтения одного файла начали бы с одного места.
  Future<void> _readWatched() => _reading = _reading.then((_) async {
    try {
      await sessions.readTranscripts(where: _watched);
    } on FileSystemException catch (error) {
      debugPrint('Не удалось прочитать переписку Claude Code: $error');
    }
  });

  /// Тикаем раз в [tickInterval], пока есть видимая работающая сессия.
  void _syncTicker() {
    final needed =
        !_disposed &&
        sessions.all.any(
          (session) =>
              session.state == CodeSessionState.working && _watched(session),
        );
    if (!needed) {
      _ticker?.cancel();
      _ticker = null;
    } else {
      _ticker ??= Timer.periodic(tickInterval, (_) => _refresh());
    }
  }

  /// Сессии закрытого профиля и давно выполненные задачи убираем.
  void _prune() {
    final changed = sessions.prune(
      runningProfileIds: {
        for (final profile in launcher.runningProfiles) profile.id,
      },
      now: DateTime.now(),
    );
    if (changed) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    launcher.removeListener(_onLauncherChanged);
    windowVisible.removeListener(_updateWatching);
    _ticker?.cancel();
    _server?.stop();
    super.dispose();
  }
}
