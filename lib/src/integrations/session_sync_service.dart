import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_settings.dart';
import '../launcher_controller.dart';
import 'session_transfer.dart';

/// Когда синхронизировать сессии ([SessionSync]): при запуске лаунчера, когда
/// закрывается профиль из группы (теперь в него можно писать, а его новые
/// сессии — разнести по остальным) и по кнопке. Запуски — строго по одному.
class SessionSyncService extends ChangeNotifier {
  SessionSyncService({
    required this.launcher,
    required this.settings,
    required Directory supportDir,
  }) : _sync = SessionSync(
         transfer: SessionTransfer(
           journalRoot: Directory(p.join(supportDir.path, 'transfers')),
         ),
         stateFile: File(p.join(supportDir.path, 'sync-state.json')),
       );

  final LauncherController launcher;
  final AppSettings settings;
  final SessionSync _sync;

  SyncResult? lastResult;
  DateTime? lastAt;
  String? error;
  bool get syncing => _running != null;

  Future<void>? _running;
  bool _again = false;
  Set<String> _open = {};
  Timer? _debounce;

  void start() {
    _open = _openInGroup();
    launcher.addListener(_onLauncher);
    if (settings.sessionSync) unawaited(syncNow());
  }

  @override
  void dispose() {
    launcher.removeListener(_onLauncher);
    _debounce?.cancel();
    super.dispose();
  }

  Set<String> _openInGroup() => {
    for (final profile in launcher.profiles)
      if (settings.syncProfiles.contains(profile.id) &&
          launcher.isRunning(profile))
        profile.id,
  };

  void _onLauncher() {
    final open = _openInGroup();
    final closed = _open.difference(open);
    _open = open;
    if (closed.isEmpty || !settings.sessionSync) return;
    // Claude только что вышел — дадим ему дописать файлы.
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
  }

  /// Синхронизирует сейчас; если уже идёт — ещё раз после.
  Future<void> syncNow() async {
    if (_running case final running?) {
      _again = true;
      return running;
    }
    final run = _running = _run();
    notifyListeners();
    try {
      await run;
    } finally {
      _running = null;
      notifyListeners();
    }
    if (_again) {
      _again = false;
      await syncNow();
    }
  }

  Future<void> _run() async {
    final group = [
      for (final profile in launcher.profiles)
        if (settings.syncProfiles.contains(profile.id)) profile,
    ];
    if (!settings.sessionSync || group.length < 2) return;
    try {
      final members = [
        for (final profile in group)
          SyncMember(
            id: profile.id,
            side: await launcher.transferSideOf(profile),
            running: launcher.isRunning(profile),
          ),
      ];
      final projects = settings.syncProjects;
      lastResult = await _sync.run(
        members,
        projects: projects == null ? null : {...projects},
      );
      lastAt = DateTime.now();
      error = null;
    } catch (e) {
      debugPrint('Синхронизация сессий: $e');
      error = 'Не удалось синхронизировать сессии';
    }
  }
}
