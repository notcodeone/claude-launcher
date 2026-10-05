import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'claude/claude_host.dart';
import 'integrations/profile_claude_code.dart';
import 'integrations/profile_identity.dart';
import 'integrations/session_transfer.dart';
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

/// Итог операции с профилем. Вызывающий код смотрит сюда, а не на
/// [LauncherController.lastError]: та видна пользователю и может смениться.
class ProfileOperation {
  const ProfileOperation.done() : error = null;
  const ProfileOperation.failed(String this.error);

  static const busy = ProfileOperation.failed(
    'Дождитесь завершения операции с Claude',
  );
  static const cancelled = ProfileOperation.failed('Закрытие Claude отменено');

  /// `null` — профиль в нужном состоянии (открыт или закрыт).
  final String? error;
  bool get succeeded => error == null;
}

/// Capability valid only within [LauncherController.withMaintenance].
class LauncherMaintenance {
  LauncherMaintenance._(this._launcher, this.label);
  final LauncherController _launcher;
  final String label;
  bool _interrupted = false;
  bool get interrupted => _interrupted;

  void _check() {
    if (_launcher._maintenance != this) {
      throw StateError('Операция обслуживания уже завершена');
    }
  }

  Future<ProfileOperation> close(Profile profile) {
    _check();
    return _launcher._close(profile, maintenance: this);
  }

  Future<ProfileOperation> reopen(Profile profile, {bool strict = false}) {
    _check();
    if (interrupted) {
      return Future.value(
        const ProfileOperation.failed(
          'Восстановление отменено аварийным закрытием Claude',
        ),
      );
    }
    return _launcher._switchTo(
      profile,
      strict: strict,
      maintenance: this,
      preserveOthers: true,
    );
  }
}

/// Профили, состояние запущенных экземпляров Claude и переключение между ними.
class LauncherController extends ChangeNotifier {
  LauncherController({
    required this.host,
    required this.store,
    this.launchTimeout = const Duration(seconds: 20),
  });

  final ClaudeHost host;
  final ProfileStore store;

  /// Сколько ждать появления процесса после запуска профиля.
  final Duration launchTimeout;

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

  /// Готовит свою папку Claude Code профиля перед запуском (см.
  /// [claudeConfigDirOf]).
  Future<void> Function(Profile profile, String configDir)? prepareClaudeCode;

  /// Проверка перед запуском профиля — до того, как закрыть открытый: бросает
  /// [LaunchBlocked], если запускать нельзя. [strict] — запуск при старте
  /// лаунчера, без участия пользователя.
  Future<void> Function({required bool strict})? launchGuard;

  Timer? _pollTimer;
  bool _cancelRequested = false;

  /// Экземпляры, которые сейчас закрываются (см. [forceClose]).
  Set<int> _closingPids = {};
  bool _disposed = false;
  bool _operating = false;
  bool _parallelLaunch = false;
  LauncherMaintenance? _maintenance;

  bool get maintaining => _maintenance != null;
  String? get maintenanceLabel => _maintenance?.label;
  bool get busy => _operating || maintaining;

  /// Reserve all profile operations before the first await. Emergency kill,
  /// manual force-close and cancelling a quit wait remain available.
  Future<T> withMaintenance<T>(
    Future<T> Function(LauncherMaintenance operation) action, {
    String label = 'Обновление Claude',
  }) async {
    if (busy) throw StateError('Дождитесь завершения операции с Claude');
    final operation = _maintenance = LauncherMaintenance._(this, label);
    _notify();
    try {
      return await action(operation);
    } finally {
      _maintenance = null;
      _notify();
    }
  }

  bool _allowed(LauncherMaintenance? operation) =>
      !_operating && (_maintenance == null || _maintenance == operation);

  bool get parallelLaunch => _parallelLaunch;

  /// Изменение режима само по себе не закрывает ни одного экземпляра.
  void setParallelLaunch(bool enabled) {
    if (_parallelLaunch == enabled) return;
    _parallelLaunch = host.parallel = enabled;
    _notify();
  }

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

  /// Своя папка Claude Code профиля (`CLAUDE_CONFIG_DIR`); `null` — общая
  /// `~/.claude`, как у «Основного».
  String? claudeConfigDirOf(Profile profile) =>
      profile.usesDefaultFolder || !profile.ownClaudeCode
      ? null
      : ProfileClaudeCode.dirOf(dataDirOf(profile));

  /// Папки, где Claude профиля хранит данные (у пакета MSIX — ещё копия
  /// в папке пакета).
  List<String> readableDataDirsOf(Profile profile) => host.readableDataDirs(
    ClaudeInstance(
      pid: 0,
      dataDir: profile.usesDefaultFolder ? null : dataDirOf(profile),
    ),
  );

  /// Папка, где у профиля лежат настройки Claude (`claude_desktop_config.json`;
  /// на Windows бывает в папке пакета); `null` — Claude в нём ещё не открывали.
  String? settingsDirOf(Profile profile) {
    for (final dir in readableDataDirsOf(profile)) {
      if (File(p.join(dir, 'claude_desktop_config.json')).existsSync()) {
        return dir;
      }
    }
    return null;
  }

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

  Future<void> refresh({bool strict = false}) async {
    try {
      instances = await host.running();
      _clearLateLaunchError();
    } catch (error) {
      if (strict) rethrow;
      debugPrint('Не удалось получить список процессов Claude: $error');
    }
    // Войти в аккаунт можно только в открытом Claude — перечитываем, кто
    // вошёл, когда профиль открыли или закрыли.
    final key = [for (final instance in instances) instance.pid].join(',');
    if (key != _identitiesKey) {
      _identitiesKey = key;
      unawaited(refreshIdentities());
    }
    _notify();
  }

  // --------------------------------------------------------------- аккаунты

  /// Кто вошёл в профили, по id профиля (см. [ProfileIdentity]).
  Map<String, ProfileIdentity> identities = const {};
  String? _identitiesKey;

  /// `.claude.json` Claude Code профиля, где может быть `oauthAccount`: своя
  /// папка — свой файл, у остальных — общий.
  List<String> claudeCodeConfigsOf(Profile profile) {
    if (claudeConfigDirOf(profile) case final own?) {
      return [p.join(own, '.claude.json')];
    }
    final shared = ProfileClaudeCode.sharedDir(Platform.environment);
    return [
      p.join(p.dirname(shared), '.claude.json'),
      p.join(shared, '.claude.json'),
    ];
  }

  Future<void> refreshIdentities() async {
    final next = <String, ProfileIdentity>{
      for (final profile in profiles)
        profile.id: await ProfileIdentity.read(
          dataDirs: readableDataDirsOf(profile),
          claudeCodeConfigs: claudeCodeConfigsOf(profile),
        ),
    };
    if (_disposed) return;
    String fingerprint(Map<String, ProfileIdentity> all) => [
      for (final MapEntry(:key, :value) in all.entries)
        '$key ${value.accountUuid} ${value.orgUuid} ${value.email}',
    ].join('\n');
    if (fingerprint(next) == fingerprint(identities)) return;
    identities = next;
    _notify();
  }

  /// Профиль как сторона переноса сессии: папки, папка Claude Code и аккаунт —
  /// прочитанный заново, а не из [identities]: вход могли сменить только что.
  Future<TransferSide> transferSideOf(Profile profile) async => TransferSide(
    name: profile.name,
    dataDirs: readableDataDirsOf(profile),
    claudeCodeDir:
        claudeConfigDirOf(profile) ??
        ProfileClaudeCode.sharedDir(Platform.environment),
    identity: await ProfileIdentity.read(
      dataDirs: readableDataDirsOf(profile),
      claudeCodeConfigs: claudeCodeConfigsOf(profile),
    ),
  );

  /// Почта аккаунта, под которым вошли в профиль, если она известна и не та,
  /// что указана в профиле; `null` — всё сходится или сравнить не с чем.
  String? unexpectedAccount(Profile profile) {
    final actual = identities[profile.id]?.email;
    final expected = profile.email.trim();
    if (actual == null || expected.isEmpty) return null;
    return actual.toLowerCase() == expected.toLowerCase() ? null : actual;
  }

  /// Папка профиля, который не появился за время ожидания запуска.
  String? _lateLaunchDir;

  /// Claude бывает медленнее ожидания (первый запуск, MSIX): когда профиль
  /// всё же открылся, сообщение о таймауте больше не нужно.
  void _clearLateLaunchError() {
    final dir = _lateLaunchDir;
    if (dir == null) return;
    if (!instances.any((i) => host.samePath(host.dataDirOf(i), dir))) return;
    _lateLaunchDir = null;
    if (lastError == _launchTimeout) lastError = null;
  }

  String get _launchTimeout =>
      'Claude не открыл выбранный профиль за ${launchTimeout.inSeconds} с. '
      'Если окно появится позже, сообщение исчезнет само.';

  // ------------------------------------------------------------ переключение

  /// Закрывает все остальные экземпляры Claude и открывает [target].
  /// В тестовом parallelLaunch остальные экземпляры остаются открытыми.
  /// Обычный режим сохраняет последовательное переключение.
  /// [strict] — см. [launchGuard].
  Future<ProfileOperation> switchTo(Profile target, {bool strict = false}) =>
      _switchTo(target, strict: strict);

  Future<ProfileOperation> _switchTo(
    Profile target, {
    bool strict = false,
    LauncherMaintenance? maintenance,
    bool? preserveOthers,
  }) async {
    if (!_allowed(maintenance)) return ProfileOperation.busy;
    _operating = true;
    lastError = null;
    _lateLaunchDir = null;
    _cancelRequested = false;

    try {
      claudePath ??= await host.locate();
      if (claudePath == null) {
        throw StateError(
          'Claude не найден. Установите приложение Claude и попробуйте снова.',
        );
      }

      // Строгий опрос (сбой — отказ, а не старый список) — в эксперименте и при
      // обслуживании; в обычном режиме разовый сбой не мешает открыть профиль.
      await refresh(strict: (strict && parallelLaunch) || maintenance != null);
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

      if (!(preserveOthers ?? parallelLaunch) && others.isNotEmpty) {
        final closed = await _closeAll(target, others);
        if (!closed) return ProfileOperation.cancelled;
      }

      if (maintenance?.interrupted ?? false) {
        throw const LaunchBlocked(
          'Восстановление отменено аварийным закрытием Claude',
        );
      }
      if (targetInstance != null) {
        await host.activate(targetInstance);
        return const ProfileOperation.done();
      }

      _setStatus(SwitchStatus(target, SwitchPhase.launching));
      await beforeLaunch?.call(targetDir);
      if (maintenance?.interrupted ?? false) {
        throw const LaunchBlocked(
          'Восстановление отменено аварийным закрытием Claude',
        );
      }
      final config = claudeConfigDirOf(target);
      if (config != null) await prepareClaudeCode?.call(target, config);
      await host.launch(
        target.usesDefaultFolder ? null : targetDir,
        environment: {'CLAUDE_CONFIG_DIR': ?config},
      );
      if (maintenance?.interrupted ?? false) {
        await host.killEverything();
        await refresh();
        throw const LaunchBlocked(
          'Восстановление отменено аварийным закрытием Claude',
        );
      }
      await _replace(target.copyWith(lastLaunchedAt: DateTime.now()));
      if (await _waitForLaunch(targetDir)) return const ProfileOperation.done();
      if (_disposed) return ProfileOperation.cancelled;
      // В обычном режиме долгий запуск (первый после обновления, проверка
      // macOS) — не ошибка: Claude откроется сам, как в 1.5.x.
      if (!parallelLaunch) return const ProfileOperation.done();
      _lateLaunchDir = targetDir;
      lastError = _launchTimeout;
      onNeedsAttention?.call();
      return ProfileOperation.failed(_launchTimeout);
    } on LaunchBlocked catch (blocked) {
      lastError = blocked.message;
      onNeedsAttention?.call();
      return ProfileOperation.failed('$blocked');
    } catch (error) {
      lastError = '$error';
      onNeedsAttention?.call();
      return ProfileOperation.failed('$error');
    } finally {
      _operating = false;
      switchStatus = null;
      _notify();
    }
  }

  /// Открывает ссылку `claude://` (например, сессию Claude Code) в окне
  /// открытого профиля [profile].
  Future<void> openLink(Profile profile, Uri link) async {
    if (!_allowed(null)) return;
    _operating = true;
    lastError = null;
    try {
      await refresh(strict: parallelLaunch);
      // Системный обработчик URL пока не адресует конкретный экземпляр.
      if (instances.length > 1 && !host.supportsTargetedLinks) {
        throw StateError(
          'Переход к сессии пока недоступен при нескольких профилях. '
          'Покажите окно нужного профиля и выберите сессию в Claude.',
        );
      }
      final targets = instances
          .where((instance) => profileOf(instance)?.id == profile.id)
          .toList();
      if (targets.isEmpty) return;
      if (targets.length != 1) {
        throw StateError(
          'Для профиля обнаружено несколько процессов Claude. Переход неоднозначен.',
        );
      }
      await host.openLink(targets.single, link);
    } catch (error) {
      lastError = error is StateError
          ? error.message
          : 'Не удалось открыть в Claude: $error';
      onNeedsAttention?.call();
    } finally {
      _operating = false;
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

  /// A selected set starts only when Claude is initially closed. Reserve the
  /// sequence so a tray click cannot interleave another launch. Each launch
  /// still passes the strict location/proxy guard; stop at the first refusal.
  Future<int> openOnStartupProfiles(Iterable<String> profileIds) async {
    if (!parallelLaunch || busy) return 0;
    final ids = profileIds.toSet().toList();
    if (ids.isEmpty) return 0;
    try {
      await refresh(strict: true);
      if (instances.isNotEmpty || busy) return 0;
      return await withMaintenance((operation) async {
        // Another caller could have acted during the initial scan.
        await refresh(strict: true);
        if (instances.isNotEmpty) return 0;
        var opened = 0;
        for (final id in ids) {
          if (operation.interrupted || !parallelLaunch) break;
          final profile = profiles.where((p) => p.id == id).firstOrNull;
          if (profile == null) continue;
          final result = await operation.reopen(profile, strict: true);
          if (!result.succeeded || operation.interrupted) break;
          opened++;
        }
        return opened;
      }, label: 'Автозапуск профилей');
    } catch (error) {
      lastError = 'Не удалось выполнить автозапуск профилей: $error';
      onNeedsAttention?.call();
      _notify();
      return 0;
    }
  }

  /// Пользователь закрыл сообщение об ошибке.
  void clearError() {
    if (lastError == null) return;
    lastError = null;
    _notify();
  }

  /// Kill Switch: немедленно завершает Claude со всем, что он запустил.
  Future<void> killAll() async {
    _maintenance?._interrupted = true;
    await host.killEverything();
    await refresh();
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
  Future<ProfileOperation> close(Profile profile) => _close(profile);

  Future<ProfileOperation> _close(
    Profile profile, {
    LauncherMaintenance? maintenance,
  }) async {
    if (!_allowed(maintenance)) return ProfileOperation.busy;
    _operating = true;
    lastError = null;
    _cancelRequested = false;
    try {
      await refresh(strict: maintenance != null);
      final targets = [
        for (final instance in instances)
          if (profileOf(instance)?.id == profile.id) instance,
      ];
      if (targets.isNotEmpty && !await _closeAll(null, targets)) {
        return ProfileOperation.cancelled;
      }
      return const ProfileOperation.done();
    } catch (error) {
      lastError = '$error';
      onNeedsAttention?.call();
      return ProfileOperation.failed('$error');
    } finally {
      _operating = false;
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
      await refresh(strict: maintaining);
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

  /// true — процесс профиля появился. Иначе вызывающий сообщает о таймауте,
  /// а [refresh] уберёт сообщение, если Claude откроется позже.
  Future<bool> _waitForLaunch(String targetDir) async {
    final deadline = DateTime.now().add(launchTimeout);
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      if (instances.any(
        (instance) => host.samePath(host.dataDirOf(instance), targetDir),
      )) {
        return true;
      }
    }
    return false;
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
    bool ownClaudeCode = true,
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
      ownClaudeCode: ownClaudeCode,
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
