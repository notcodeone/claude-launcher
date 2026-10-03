import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_settings.dart';
import '../claude/claude_host.dart';
import '../launcher_controller.dart';
import '../notifications.dart';
import '../profile.dart';
import 'claude_code_events.dart';
import 'claude_code_hooks.dart';
import 'claude_code_sessions.dart';
import 'code_notifications.dart';
import 'code_profile_resolver.dart';
import 'code_session_registry.dart';
import 'notification_handoff.dart';
import 'pending_code_events.dart';

/// События Claude Code: подключение хуков, приём событий, сессии открытого
/// профиля (показываются на его карточке) и уведомления о них вместо самих
/// Claude. Задел для уведомлений в Telegram.
class ClaudeCodeIntegration extends ChangeNotifier {
  ClaudeCodeIntegration({
    required this.settings,
    required this.launcher,
    ClaudeCodeHooks? hooks,
    ValueListenable<bool>? windowVisible,
    this.profileResolver = const CodeProfileResolver(),
    this.registry,
    this.handoff,
    this.notifier,
    this.onOpenWindow,
    this.tickInterval = const Duration(seconds: 1),
    this.metadataRetryInterval = const Duration(seconds: 2),
  }) : hooks = hooks ?? ClaudeCodeHooks.forCurrentUser(),
       windowVisible = windowVisible ?? ValueNotifier(true) {
    _previousParallelMode = launcher.parallelLaunch;
    launcher.addListener(_onLauncherChanged);
    this.windowVisible.addListener(_updateWatching);
    notifier?.onTap = _onNotificationTap;
  }

  final AppSettings settings;
  final LauncherController launcher;
  final ClaudeCodeHooks hooks;
  final CodeProfileResolver profileResolver;
  final CodeSessionRegistry? registry;
  String? registryError;

  Future<void> _saveRegistry() async {
    final registry = this.registry;
    if (registry == null) return;
    try {
      await registry.save(
        launcher.parallelLaunch && connected ? sessions.all : [],
      );
      registryError = null;
    } catch (_) {
      registryError = 'Не удалось сохранить список сессий Code';
    }
    _notify();
  }

  Future<void> _restoreRegistry() {
    final generation = _eventGeneration;
    return _handlingEvents = _handlingEvents
        .then((_) async {
          final registry = this.registry;
          if (registry == null || !launcher.parallelLaunch || _disposed) return;
          try {
            final entries = await registry.load();
            for (final entry in entries) {
              if (generation != _eventGeneration || _disposed) return;
              if (!launcher.parallelLaunch || !connected) return;
              final owner = await _resolveProfile(entry.reference);
              if (generation != _eventGeneration || _disposed) return;
              if (owner != entry.profileId ||
                  !launcher.runningProfiles.any((p) => p.id == owner)) {
                continue;
              }
              sessions.restore(
                id: entry.id,
                hostSessionId: entry.hostId,
                profileId: owner!,
                startedAt: entry.startedAt,
                updatedAt: entry.updatedAt,
              );
            }
            registryError = null;
            _notify();
          } catch (_) {
            registryError = 'Не удалось восстановить список сессий Code';
            _notify();
          }
        })
        .catchError((Object _) {
          registryError = 'Не удалось восстановить список сессий Code';
          _notify();
        });
  }

  Future<void> _handlingEvents = Future.value();
  int _eventGeneration = 0;

  @visibleForTesting
  Future<void> get pendingEvents => _handlingEvents;

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
  final Duration metadataRetryInterval;
  final _pending = PendingCodeEvents();
  Timer? _metadataRetry;
  bool? _previousParallelMode;

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

  /// Flush the most recent verified references before an orderly exit.
  Future<void> flushSessions() async {
    await _handlingEvents;
    await _saveRegistry();
  }

  /// Выход из лаунчера: возвращает Claude их уведомления. Возвращает, есть ли
  /// открытые Claude, которым вернуть их можно только после закрытия.
  Future<bool> releaseOnQuit() async {
    await flushSessions();
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
      await _restoreRegistry();
    } catch (e) {
      await _server?.stop();
      _server = null;
      error = 'Не удалось подключить события Claude Code: $e';
    }
    _notify();
  }

  Future<void> _disconnect() async {
    _eventGeneration++;
    _clearPending();
    await _server?.stop();
    _server = null;
    _ticker?.cancel();
    _ticker = null;
    sessions.clear();
    _shown.clear();
    await _saveRegistry();
    try {
      await hooks.uninstall();
      error = null;
    } catch (e) {
      error = 'Не удалось убрать хуки из ~/.claude/settings.json: $e';
    }
    _notify();
  }

  /// Serialize asynchronous metadata reads so Stop cannot overtake a prompt.
  Future<void> _onEvent(ClaudeCodeEvent event) {
    final generation = _eventGeneration;
    return _handlingEvents = _handlingEvents
        .then((_) async {
          if (_disposed || generation != _eventGeneration) return;
          await _handleEvent(event, generation);
        })
        .catchError((Object error) {
          debugPrint(
            'Не удалось обработать событие Claude Code: ${error.runtimeType}',
          );
        });
  }

  Future<void> _handleEvent(ClaudeCodeEvent event, int generation) async {
    Profile? profile;
    if (launcher.parallelLaunch) {
      final id = await _resolveProfile(event);
      if (_disposed || generation != _eventGeneration) return;
      profile = launcher.runningProfiles.where((p) => p.id == id).firstOrNull;
    } else {
      final running = launcher.runningProfiles;
      profile = launcher.instances.length == 1 && running.length == 1
          ? running.single
          : null;
    }
    if (launcher.parallelLaunch) {
      if (profile == null) {
        _pending.add(event, _runningOwners, DateTime.now());
        _scheduleMetadataRetry();
      } else {
        _replay(event, profile.id);
      }
    }
    final before = sessions.byId(event.sessionId)?.state;
    if (profile != null) {
      sessions.handle(event, profile.id);
      _notify();
    }
    await _showNotification(event, before, profile);
    if (profile != null) {
      await _refresh();
      await _saveRegistry();
    }
  }

  Map<String, Set<int>> get _runningOwners => {
    for (final profile in launcher.runningProfiles)
      profile.id: {
        for (final instance in launcher.instances)
          if (launcher.profileOf(instance)?.id == profile.id) instance.pid,
      },
  };

  Future<String?> _resolveProfile(ClaudeCodeEvent event) =>
      profileResolver.resolve(event, {
        for (final candidate in launcher.profiles)
          candidate.id: launcher.host.readableDataDirs(
            ClaudeInstance(
              pid: 0,
              dataDir: candidate.usesDefaultFolder
                  ? null
                  : launcher.dataDirOf(candidate),
            ),
          ),
      });

  void _replay(ClaudeCodeEvent event, String profileId) {
    _pending.expire(DateTime.now());
    final pids = _runningOwners[profileId] ?? <int>{};
    for (final entry in _pending.take(event.sessionId, event.hostSessionId)) {
      if (entry.accepts(profileId, pids)) {
        sessions.handle(entry.event, profileId);
      }
    }
  }

  void _clearPending() {
    _pending.clear();
    _metadataRetry?.cancel();
    _metadataRetry = null;
  }

  void _scheduleMetadataRetry() {
    if (_disposed || !connected || _pending.isEmpty || _metadataRetry != null) {
      return;
    }
    _metadataRetry = Timer(metadataRetryInterval, () {
      retryPendingMetadata().whenComplete(() {
        _metadataRetry = null;
        _scheduleMetadataRetry();
      });
    });
  }

  /// Serialized with incoming hooks; replay changes cards, never notifications.
  @visibleForTesting
  Future<void> retryPendingMetadata() {
    final generation = _eventGeneration;
    return _handlingEvents = _handlingEvents
        .then((_) async {
          if (_disposed || generation != _eventGeneration) return;
          if (!launcher.parallelLaunch) {
            _clearPending();
            return;
          }
          _pending.expire(DateTime.now());
          final visited = <(String, String)>{};
          for (final entry in _pending.entries) {
            final event = entry.event;
            if (!visited.add((event.sessionId, event.hostSessionId))) continue;
            final id = await _resolveProfile(event);
            if (_disposed || generation != _eventGeneration) return;
            if (id != null) _replay(event, id);
          }
          await _refresh();
          await _saveRegistry();
        })
        .catchError((Object error) {
          debugPrint('Не удалось повторить события Code: ${error.runtimeType}');
        });
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
        title: launcher.parallelLaunch && profile != null
            ? '${profile.title} · $title'
            : title,
        body: body,
        payload: event.hostSessionId.isEmpty || profile == null
            ? ''
            : jsonEncode({
                'profileId': profile.id,
                'hostSessionId': event.hostSessionId,
              }),
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
  /// Лаунчер запустили нажатием на его уведомление, пока он был закрыт
  /// (Windows): открываем то же, что и при нажатии на работающем лаунчере.
  Future<void> openLaunchNotification() async {
    try {
      final payload = await notifier?.launchPayload();
      if (payload != null) _onNotificationTap(payload);
    } catch (error) {
      debugPrint(
        'Не удалось узнать, каким уведомлением запущен лаунчер: $error',
      );
    }
  }

  void _onNotificationTap(String payload) {
    // Профиль фиксируется в момент уведомления. После закрытия профиля,
    // перезапуска лаунчера или смены активного аккаунта не открываем чужой.
    try {
      final target = jsonDecode(payload);
      if (target is Map<String, dynamic>) {
        final id = target['profileId'];
        final sessionId = target['hostSessionId'];
        final profile = launcher.runningProfiles
            .where((p) => p.id == id)
            .firstOrNull;
        final link = sessionId is String
            ? CodeSession.linkFor(sessionId)
            : null;
        if (profile != null && link != null) {
          launcher.openLink(profile, link);
          return;
        }
      }
    } on FormatException {
      // Старое уведомление без профиля: безопасно открыть список профилей.
    }
    onOpenWindow?.call();
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
    if (_previousParallelMode != launcher.parallelLaunch) {
      _previousParallelMode = launcher.parallelLaunch;
      _eventGeneration++;
      _clearPending();
      if (!launcher.parallelLaunch) {
        unawaited(_saveRegistry());
      }
    }
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
    if (changed) {
      _notify();
      unawaited(_saveRegistry());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearPending();
    launcher.removeListener(_onLauncherChanged);
    windowVisible.removeListener(_updateWatching);
    _ticker?.cancel();
    _server?.stop();
    super.dispose();
  }
}
