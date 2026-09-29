import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'claude/claude_host.dart';
import 'profile.dart';
import 'profile_store.dart';

enum SwitchPhase {
  /// Попросили открытые экземпляры закрыться, ждём.
  closing,

  /// Сами не закрылись — нужен пользователь (см. [ClaudeHost.manualQuitHint]).
  waitingForUser,

  /// Запускаем нужный профиль.
  launching,
}

class SwitchStatus {
  const SwitchStatus(this.target, this.phase, {this.closing = const []});

  final Profile target;
  final SwitchPhase phase;

  /// Названия профилей, которые закрываются.
  final List<String> closing;
}

/// Профили, состояние запущенных экземпляров Claude и переключение между ними.
class LauncherController extends ChangeNotifier {
  LauncherController({required this.host, required this.store});

  final ClaudeHost host;
  final ProfileStore store;

  List<Profile> profiles = [];
  List<ClaudeInstance> instances = [];

  /// Путь к Claude; `null` — не найден (или ещё не искали).
  String? claudePath;
  bool located = false;

  SwitchStatus? switchStatus;
  String? lastError;

  /// Лаунчер запущен впервые (профилей ещё не было).
  bool firstRun = false;

  /// Вызывается, когда нужно внимание пользователя: ошибка или ручное закрытие Claude.
  VoidCallback? onNeedsAttention;

  Timer? _pollTimer;
  bool _cancelRequested = false;
  bool _disposed = false;

  Future<void> init() async {
    profiles = await store.load();
    if (profiles.isEmpty) {
      firstRun = true;
      profiles = [const Profile(id: 'default', name: 'Основной')];
      await store.save(profiles);
    }
    claudePath = await host.locate();
    located = true;
    await refresh();
    _pollTimer = Timer.periodic(host.pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------- состояние

  String dataDirOf(Profile profile) => switch (profile.folderName) {
        final folder? => p.join(host.profilesBaseDir, folder),
        null => host.defaultDataDir,
      };

  Profile? profileOf(ClaudeInstance instance) {
    final dir = host.dataDirOf(instance);
    for (final profile in profiles) {
      if (host.samePath(dataDirOf(profile), dir)) return profile;
    }
    return null;
  }

  bool isRunning(Profile profile) =>
      instances.any((instance) => profileOf(instance)?.id == profile.id);

  /// Запущенные экземпляры, которые не относятся ни к одному профилю.
  List<ClaudeInstance> get unknownInstances =>
      [for (final instance in instances) if (profileOf(instance) == null) instance];

  List<Profile> get runningProfiles =>
      [for (final profile in profiles) if (isRunning(profile)) profile];

  Future<void> refresh() async {
    try {
      instances = await host.running();
    } catch (error) {
      debugPrint('Не удалось получить список процессов Claude: $error');
    }
    _notify();
  }

  // ------------------------------------------------------------ переключение

  /// Закрывает все остальные экземпляры Claude и открывает [target].
  /// Одновременно открыт только один: так ссылка входа из браузера всегда
  /// попадает в нужный экземпляр, и не конфликтуют виртуальные машины Cowork.
  Future<void> switchTo(Profile target) async {
    if (switchStatus != null) return;
    lastError = null;
    _cancelRequested = false;

    try {
      claudePath ??= await host.locate();
      if (claudePath == null) {
        throw StateError('Claude не найден. Установите приложение Claude и попробуйте снова.');
      }

      await refresh();
      final targetDir = dataDirOf(target);
      ClaudeInstance? targetInstance;
      final others = <ClaudeInstance>[];
      for (final instance in instances) {
        if (host.samePath(host.dataDirOf(instance), targetDir)) {
          targetInstance = instance;
        } else {
          others.add(instance);
        }
      }

      if (others.isNotEmpty) {
        final closed = await _closeAll(target, others);
        if (!closed) return;
      }

      if (targetInstance != null) {
        await host.activate(targetInstance);
        return;
      }

      _setStatus(SwitchStatus(target, SwitchPhase.launching));
      await host.launch(target.usesDefaultFolder ? null : targetDir);
      await _replace(target.copyWith(lastLaunchedAt: DateTime.now()));
      await _waitForLaunch(targetDir);
    } catch (error) {
      lastError = '$error';
      onNeedsAttention?.call();
    } finally {
      switchStatus = null;
      _notify();
    }
  }

  /// Отменяет ожидание закрытия. Уже отправленные просьбы закрыться не отзываются.
  void cancelSwitch() {
    _cancelRequested = true;
  }

  Future<bool> _closeAll(Profile target, List<ClaudeInstance> others) async {
    final names = [
      for (final instance in others) profileOf(instance)?.title ?? 'неизвестный профиль',
    ];
    _setStatus(SwitchStatus(target, SwitchPhase.closing, closing: names));
    for (final instance in others) {
      await host.requestQuit(instance);
    }

    final started = DateTime.now();
    final pids = {for (final instance in others) instance.pid};
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_cancelRequested || _disposed) return false;
      await refresh();
      if (!instances.any((instance) => pids.contains(instance.pid))) return true;

      final waitingLong = DateTime.now().difference(started) > host.manualQuitHintAfter;
      if (waitingLong && switchStatus?.phase == SwitchPhase.closing) {
        _setStatus(SwitchStatus(target, SwitchPhase.waitingForUser, closing: names));
        onNeedsAttention?.call();
      }
    }
  }

  Future<void> _waitForLaunch(String targetDir) async {
    for (var i = 0; i < 40 && !_disposed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      if (instances.any((instance) => host.samePath(host.dataDirOf(instance), targetDir))) {
        return;
      }
    }
  }

  void _setStatus(SwitchStatus status) {
    switchStatus = status;
    _notify();
  }

  // ---------------------------------------------------------------- профили

  Future<Profile> addProfile({
    required String name,
    String email = '',
    String note = '',
    String marker = Profile.defaultMarker,
  }) async {
    final profile = Profile(
      id: _newId(),
      name: name,
      email: email,
      note: note,
      marker: marker,
      folderName: folderNameFor(name, [
        for (final existing in profiles) ?existing.folderName,
      ]),
    );
    profiles = [...profiles, profile];
    await store.save(profiles);
    _notify();
    return profile;
  }

  Future<void> updateProfile(Profile profile) => _replace(profile);

  /// Убирает профиль из списка. Папку данных не трогает: её можно удалить вручную.
  Future<void> removeProfile(Profile profile) async {
    profiles = [for (final existing in profiles) if (existing.id != profile.id) existing];
    await store.save(profiles);
    _notify();
  }

  Future<void> _replace(Profile profile) async {
    profiles = [
      for (final existing in profiles) existing.id == profile.id ? profile : existing,
    ];
    await store.save(profiles);
    _notify();
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
