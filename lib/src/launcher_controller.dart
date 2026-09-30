import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'claude/claude_host.dart';
import 'profile.dart';
import 'profile_store.dart';

enum SwitchPhase {
  /// Проверяем, можно ли запускать (см. [LauncherController.launchGuard]).
  checking,

  /// Попросили открытые экземпляры закрыться, ждём.
  closing,

  /// Сами не закрылись — нужен пользователь (см. [ClaudeHost.manualQuitHint]).
  waitingForUser,

  /// Запускаем нужный профиль.
  launching,
}

class SwitchStatus {
  const SwitchStatus(this.target, this.phase, {this.closing = const []});

  /// Какой профиль открываем; `null` — только закрываем ([LauncherController.close]).
  final Profile? target;
  final SwitchPhase phase;

  /// Названия профилей, которые закрываются.
  final List<String> closing;
}

/// Почему профиль нельзя запустить (см. [LauncherController.launchGuard]).
class LaunchBlocked implements Exception {
  const LaunchBlocked([this.message]);

  /// Что показать пользователю; `null` — причина и так видна в окне.
  final String? message;

  @override
  String toString() => message ?? 'Запуск профиля запрещён';
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

  /// Вызывается, когда нужно внимание пользователя: ошибка или ручное закрытие Claude.
  VoidCallback? onNeedsAttention;

  /// Вызывается перед запуском Claude с папкой профиля — пока он ещё закрыт.
  Future<void> Function(String dataDir)? beforeLaunch;

  /// Проверка перед запуском профиля — до того, как закрыть открытый: бросает
  /// [LaunchBlocked], если запускать нельзя. [strict] — запуск при старте
  /// лаунчера, без участия пользователя.
  Future<void> Function({required bool strict})? launchGuard;

  Timer? _pollTimer;
  bool _cancelRequested = false;

  /// Экземпляры, которые сейчас закрываются (см. [forceClose]).
  Set<int> _closingPids = {};
  bool _disposed = false;

  Future<void> init() async {
    profiles = await store.load();
    if (profiles.isEmpty) {
      profiles = [
        const Profile(id: 'default', name: 'Основной', icon: 'briefcase'),
      ];
      await store.save(profiles);
    }
    // Сбой поиска Claude не должен останавливать запуск: профили, окно
    // приветствия и настройки работают и без него, ошибку покажем плашкой.
    try {
      claudePath = await host.locate();
    } catch (error) {
      lastError = 'Не удалось найти Claude: $error';
    }
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
  List<ClaudeInstance> get unknownInstances => [
    for (final instance in instances)
      if (profileOf(instance) == null) instance,
  ];

  List<Profile> get runningProfiles => [
    for (final profile in profiles)
      if (isRunning(profile)) profile,
  ];

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
  /// [strict] — см. [launchGuard].
  Future<void> switchTo(Profile target, {bool strict = false}) async {
    if (switchStatus != null) return;
    lastError = null;
    _cancelRequested = false;

    try {
      claudePath ??= await host.locate();
      if (claudePath == null) {
        throw StateError(
          'Claude не найден. Установите приложение Claude и попробуйте снова.',
        );
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

      // Уже открытый профиль не запускается — только выводится вперёд.
      if (targetInstance == null && launchGuard != null) {
        _setStatus(SwitchStatus(target, SwitchPhase.checking));
        await launchGuard!(strict: strict);
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
      await beforeLaunch?.call(targetDir);
      await host.launch(target.usesDefaultFolder ? null : targetDir);
      await _replace(target.copyWith(lastLaunchedAt: DateTime.now()));
      await _waitForLaunch(targetDir);
    } on LaunchBlocked catch (blocked) {
      lastError = blocked.message;
      onNeedsAttention?.call();
    } catch (error) {
      lastError = '$error';
      onNeedsAttention?.call();
    } finally {
      switchStatus = null;
      _notify();
    }
  }

  /// Открывает ссылку `claude://` (например, сессию Claude Code) в окне
  /// открытого профиля [profile].
  Future<void> openLink(Profile profile, Uri link) async {
    if (switchStatus != null) return;
    final instance = instances
        .where((instance) => profileOf(instance)?.id == profile.id)
        .firstOrNull;
    if (instance == null) return;
    try {
      await host.openLink(instance, link);
    } catch (error) {
      lastError = 'Не удалось открыть в Claude: $error';
      _notify();
    }
  }

  /// При запуске лаунчера: открывает профиль [profileId], если Claude сейчас
  /// не открыт. Уже открытый Claude не трогаем. true — если открывал.
  Future<bool> openOnStartup(String? profileId) async {
    if (profileId == null || instances.isNotEmpty) return false;
    for (final profile in profiles) {
      if (profile.id == profileId) {
        await switchTo(profile, strict: true);
        return true;
      }
    }
    return false;
  }

  /// Прячет или возвращает значок самого Claude; ошибка не мешает работе лаунчера.
  Future<void> setClaudeIconHidden(bool hidden) async {
    try {
      await host.setClaudeIconHidden(hidden);
    } catch (error) {
      debugPrint('Не удалось изменить значок Claude: $error');
    }
  }

  /// Завершает работу открытого профиля так же, как обычный выход из Claude.
  Future<void> close(Profile profile) async {
    if (switchStatus != null) return;
    lastError = null;
    _cancelRequested = false;
    try {
      await refresh();
      final targets = [
        for (final instance in instances)
          if (profileOf(instance)?.id == profile.id) instance,
      ];
      if (targets.isNotEmpty) await _closeAll(null, targets);
    } catch (error) {
      lastError = '$error';
      onNeedsAttention?.call();
    } finally {
      switchStatus = null;
      _notify();
    }
  }

  /// Когда Claude не закрылся сам: завершает оставшиеся экземпляры принудительно.
  /// Ожидание закрытия увидит, что их нет, и продолжит (переключение — запуском
  /// нужного профиля).
  Future<void> forceClose() async {
    if (switchStatus?.phase != SwitchPhase.waitingForUser) return;
    for (final instance in instances) {
      if (_closingPids.contains(instance.pid)) await host.forceQuit(instance);
    }
  }

  /// Отменяет ожидание закрытия. Уже отправленные просьбы закрыться не отзываются.
  void cancelSwitch() {
    _cancelRequested = true;
  }

  Future<bool> _closeAll(Profile? target, List<ClaudeInstance> others) async {
    final names = [
      for (final instance in others)
        profileOf(instance)?.name ?? 'неизвестный профиль',
    ];
    _setStatus(SwitchStatus(target, SwitchPhase.closing, closing: names));
    for (final instance in others) {
      await host.requestQuit(instance);
    }

    final started = DateTime.now();
    final pids = _closingPids = {for (final instance in others) instance.pid};
    var forced = false;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_cancelRequested || _disposed) return false;
      await refresh();
      if (!instances.any((instance) => pids.contains(instance.pid))) {
        return true;
      }

      final elapsed = DateTime.now().difference(started);
      final autoForce = host.autoForceQuitAfter;
      if (!forced && autoForce != null && elapsed > autoForce) {
        forced = true;
        for (final instance in instances) {
          if (pids.contains(instance.pid)) await host.forceQuit(instance);
        }
        continue;
      }

      final waitingLong = elapsed > host.manualQuitHintAfter;
      if (waitingLong && switchStatus?.phase == SwitchPhase.closing) {
        _setStatus(
          SwitchStatus(target, SwitchPhase.waitingForUser, closing: names),
        );
        onNeedsAttention?.call();
      }
    }
  }

  Future<void> _waitForLaunch(String targetDir) async {
    for (var i = 0; i < 40 && !_disposed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      if (instances.any(
        (instance) => host.samePath(host.dataDirOf(instance), targetDir),
      )) {
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
    String icon = Profile.defaultIcon,
  }) async {
    final profile = Profile(
      id: _newId(),
      name: name,
      email: email,
      note: note,
      marker: marker,
      icon: icon,
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
  /// Профиль со стандартной папкой Claude убрать нельзя.
  Future<void> removeProfile(Profile profile) async {
    if (profile.usesDefaultFolder) return;
    profiles = [
      for (final existing in profiles)
        if (existing.id != profile.id) existing,
    ];
    await store.save(profiles);
    _notify();
  }

  Future<void> _replace(Profile profile) async {
    profiles = [
      for (final existing in profiles)
        existing.id == profile.id ? profile : existing,
    ];
    await store.save(profiles);
    _notify();
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      12,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }
}
