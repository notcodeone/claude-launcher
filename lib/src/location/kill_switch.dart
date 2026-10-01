import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../launcher_controller.dart';
import '../notifications.dart';
import 'countries.dart';
import 'egress_config.dart';
import 'egress_gate.dart';
import 'location_guard.dart';

/// Сетевые адреса компьютера — меняются, когда включается или отключается VPN,
/// меняется Wi-Fi или кабель. Сравнить их дёшево и без запросов в интернет.
///
/// Только IPv4: временные IPv6-адреса система меняет сама каждые несколько
/// часов — из-за них затвор закрывался бы без причины. VPN, смена Wi-Fi или
/// кабеля меняют IPv4-адреса и набор интерфейсов.
///
/// Без адаптеров виртуальных машин: они появляются, когда стартует машина
/// Cowork, WSL или Hyper-V, и это не смена сети — иначе затвор рвал бы
/// соединения, а строгий режим закрывал бы Claude на запуске задачи Cowork.
/// Адаптеры VPN (utun, Wintun, WireGuard, TAP) остаются.
Future<String> networkFingerprint() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  return ([
    for (final interface in interfaces)
      if (!isVirtualMachineAdapter(interface.name))
        for (final address in interface.addresses)
          '${interface.name}=${address.address}',
  ]..sort()).join(',');
}

/// Адаптер для виртуальных машин, а не выход в сеть: `bridge100` на macOS,
/// `vEthernet (Default Switch)` и `vEthernet (WSL)` на Windows.
bool isVirtualMachineAdapter(String name) => RegExp(
  r'^(bridge\d+|vmenet\d+|vEthernet \((Default Switch|WSL.*|.*cowork.*)\))$',
  caseSensitive: false,
).hasMatch(name);

/// Kill Switch сработал: Claude закрыт, потому что сменилась страна.
class KillSwitchEvent {
  const KillSwitchEvent({
    required this.from,
    required this.to,
    required this.at,
    this.network = false,
  });

  /// Страна, в которой Claude работал.
  final String from;

  /// Новая страна; null — неизвестна.
  final String? to;
  final DateTime at;

  /// Сработал строгий режим: сменилась сеть.
  final bool network;
}

/// Kill Switch (эксперимент) — защита аккаунта, когда Claude открыт через VPN.
///
/// Весь трафик Claude — приложения, его Claude Code и машины Cowork — идёт
/// через прокси-затвор лаунчера ([EgressGate]): лаунчер закрепляет его в
/// конфигурации Claude ([EgressConfig]). Затвор выпускает соединение, только
/// пока сеть та же, при которой лаунчер проверил страну, и Claude в ней
/// доступен; сверяет сеть перед каждым новым соединением.
///
/// О смене сети лаунчер узнаёт сразу: на macOS и Windows сообщает система
/// ([networkChanged]), а раз в 250 мс он ещё и сверяет адреса
/// ([networkFingerprint]). Тогда затвор мгновенно рвёт открытые соединения, а
/// лаунчер проверяет страну по IP. Новые соединения тем временем ждут ответа,
/// а не получают отказ — иначе Claude решил бы, что сети нет, и застрял бы на
/// своём экране ошибки. Та же страна — соединения идут дальше; другая или
/// Claude там недоступен — получают отказ, а Claude закрывается. Раз в 30
/// секунд, пока Claude открыт, страна проверяется и так: VPN может сменить
/// сервер, не меняя адресов.
///
/// Claude, открытый до включения, закреплён за прокси только после
/// перезапуска; до тех пор его прикрывает лишь закрытие при смене страны.
/// Выключили Kill Switch, а Claude, открытый через затвор, ещё работает, —
/// затвор пропускает всё ([passthrough]), пока этот Claude не закроют: без
/// затвора он остался бы без сети.
class KillSwitch extends ChangeNotifier {
  KillSwitch({
    required this.settings,
    required this.location,
    required this.launcher,
    this.notifier,
    this.onFired,
    this.fingerprint = networkFingerprint,
    this.config = const EgressConfig(),
    this.pollEvery = const Duration(milliseconds: 250),
    this.recheckEvery = const Duration(seconds: 30),
    this.retryAfter = const Duration(seconds: 3),
    this.holdFor = const Duration(seconds: 20),
    this.blockedFor = const Duration(seconds: 5),
    this.useGate = true,
    this.exactPort = false,
    this._passthrough = false,
  }) {
    gate = EgressGate(allow: _allows);
  }

  final AppSettings settings;
  final LocationGuard location;
  final LauncherController launcher;
  final Notifier? notifier;

  /// Сработал — например, показать окно лаунчера.
  final VoidCallback? onFired;

  final Future<String> Function() fingerprint;
  final EgressConfig config;
  final Duration pollEvery;
  final Duration recheckEvery;

  /// Страну узнать не удалось — повтор через столько.
  final Duration retryAfter;

  /// Сколько новое соединение ждёт проверки сети, прежде чем получить отказ.
  final Duration holdFor;

  /// Сколько после окончательного отказа соединения получают отказ сразу,
  /// без новой проверки страны.
  final Duration blockedFor;

  /// Поднимать затвор и писать конфигурацию Claude (в тестах — нет).
  final bool useGate;

  /// Охранник после выхода лаунчера: открытый Claude ждёт затвор именно на
  /// этом порту, поэтому другой не подойдёт — ждём, пока порт освободится.
  final bool exactPort;

  late final EgressGate gate;

  /// Страна, в которой проверена нынешняя сеть.
  String? baseline;

  /// Затвор пропускает трафик.
  bool open = false;

  /// Последнее срабатывание — для плашки в окне.
  KillSwitchEvent? lastFired;

  /// Claude был открыт до включения — закреплён за прокси только после
  /// перезапуска.
  bool needsRestart = false;

  /// Открытый Claude запущен через затвор, хотя конфигурации уже нет: её
  /// снял закрытый охранник (см. записку в main.dart). Затвор нужен этому
  /// Claude на прежнем порту, пока его не закроют.
  bool handover = false;

  /// Конфигурацию Claude записать не удалось (чужая или нет доступа): Claude
  /// пошёл бы мимо затвора. Такой профиль лаунчер не запускает.
  bool unprotected = false;

  bool get enabled => settings.killSwitch;

  /// Вдобавок закрывать Claude при любой смене сети.
  bool get strict => settings.killSwitchStrict;

  bool get armed => _poll != null;

  /// Kill Switch выключен, но Claude, открытый через затвор, ещё работает:
  /// затвор пропускает всё без проверок, пока его не закроют.
  bool get passthrough => _passthrough;

  /// Затвор нужен открытому Claude — после выхода лаунчера его держит охранник.
  bool get serving => armed || _passthrough;

  bool get _claudeRunning => launcher.instances.isNotEmpty;

  bool _passthrough;
  Timer? _poll;
  Timer? _recheck;
  Timer? _retry;
  String? _fingerprint;

  /// Адреса, при которых проверена страна; затвор открыт только при них.
  String? _verified;
  bool _verifying = false;
  bool _again = false;
  bool _wasRunning = false;

  /// Решение для ждущих соединений: true — пропустить, false — отказ.
  var _verdict = Completer<bool>();

  /// Когда затвор отказал окончательно (другая страна) — чтобы повторные
  /// попытки Claude не устраивали проверку страны на каждое соединение.
  DateTime? _blockedAt;

  /// Затвор слушает порт, конфигурация записана.
  Completer<void>? _ready;

  void start() {
    settings.addListener(_sync);
    launcher.addListener(_sync);
    if (_passthrough) unawaited(_startPassthrough());
    // Сначала _sync: он сбросит записку, если Claude уже закрыт.
    _sync();
    if (!enabled && !_passthrough && useGate) unawaited(_cleanStale());
  }

  @override
  void dispose() {
    settings.removeListener(_sync);
    launcher.removeListener(_sync);
    _disarm();
    super.dispose();
  }

  /// Пользователь прочитал плашку о срабатывании.
  void dismiss() {
    lastFired = null;
    notifyListeners();
  }

  /// Перед запуском профиля — закрепить его за прокси: Claude читает
  /// конфигурацию только при запуске. Ждём, пока затвор поднят и сеть
  /// проверена, — иначе первые запросы Claude получили бы отказ.
  Future<void> beforeLaunch(String dataDir) async {
    if (!enabled || !useGate) return;
    if (!armed) _sync();
    await _ready?.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    if (!await config.pin(dataDir, gate.port ?? settings.egressPort)) {
      unprotected = true;
      notifyListeners();
      // Без прокси Claude пошёл бы напрямую — молча так запускать нельзя.
      throw const LaunchBlocked(
        'Kill Switch не смог направить Claude через лаунчер: в папке настроек '
        'Claude чужая конфигурация или её не удалось записать. Профиль не '
        'открыт — выключите Kill Switch, чтобы открыть его без защиты.',
      );
    }
    if (!open) {
      _ensureVerifying(force: true);
      await _verdict.future.timeout(holdFor, onTimeout: () => false);
    }
  }

  /// Останавливает затвор. [keepPinned] — конфигурацию Claude оставить: его
  /// затвор поднимет охранник или новая версия лаунчера. Иначе убрать —
  /// следующий запуск Claude будет обычным.
  Future<void> shutdown({required bool keepPinned}) async {
    settings.removeListener(_sync);
    launcher.removeListener(_sync);
    final wasServing = serving;
    _disarm();
    _passthrough = false;
    await gate.stop();
    if (wasServing && useGate && !keepPinned) await _unpinAll();
  }

  /// Проверить страну сейчас — по кнопке в окне Kill Switch. Открытые
  /// соединения не рвёт: сеть та же. Шапка показывает ход проверки
  /// ([checking]) — не короче [_minShown], чтобы надпись успела прочитаться.
  Future<void> checkNow() async {
    if (!armed || _manual) return;
    _manual = true;
    notifyListeners();
    try {
      if (_verdict.isCompleted && !open) _verdict = Completer<bool>();
      await Future.wait([_verify(), Future<void>.delayed(_minShown)]);
    } finally {
      _manual = false;
      notifyListeners();
    }
  }

  static const _minShown = Duration(milliseconds: 900);

  /// Сеть проверяется, и это стоит показать: по кнопке «Проверить сеть» или
  /// пока затвор закрыт и трафик ждёт. Плановые проверки при открытом
  /// затворе не показываются.
  bool get checking => _manual || (armed && !open && _verifying);

  bool _manual = false;

  /// Система сообщила, что сеть изменилась, — не ждём опроса.
  Future<void> networkChanged() => _checkNetwork();

  void _sync() {
    if (!_claudeRunning) handover = false;
    if (enabled && !armed) {
      _passthrough = false;
      unawaited(_arm());
    } else if (!enabled && armed) {
      // Открытый Claude закреплён за затвором — без него он остался бы без
      // сети. Пропускаем всё, пока его не закроют; новые запуски — обычные.
      // Конфигурацию оставляем до его закрытия: по ней новый лаунчер или
      // охранник узнает, что затвор ещё нужен.
      final keep = useGate && _claudeRunning;
      _disarm(stopGate: !keep);
      _passthrough = keep;
      if (useGate && !keep) unawaited(_unpinAll());
      notifyListeners();
    }
    if (_passthrough && !_claudeRunning) {
      _passthrough = false;
      unawaited(gate.stop());
      if (useGate) unawaited(_unpinAll());
      notifyListeners();
    }
    if (!armed) return;
    final running = _claudeRunning;
    if (running != _wasRunning) {
      _wasRunning = running;
      if (!running) needsRestart = false;
      _recheck?.cancel();
      _recheck = running
          ? Timer.periodic(recheckEvery, (_) => _verify())
          : null;
      notifyListeners();
    }
  }

  Future<void> _arm() async {
    final ready = _ready = Completer<void>();
    _poll = Timer.periodic(pollEvery, (_) => _checkNetwork());
    _wasRunning = _claudeRunning;
    if (_wasRunning) _recheck = Timer.periodic(recheckEvery, (_) => _verify());
    notifyListeners();
    _verifying = true; // Первая проверка — ниже; соединения её дождутся.
    try {
      if (useGate) {
        // Claude, открытый через затвор (лаунчер перезапустили), защищён;
        // открытый без него — только после перезапуска.
        var pinnedBefore = handover;
        for (final profile in launcher.runningProfiles) {
          if (await config.isPinned(launcher.dataDirOf(profile))) {
            pinnedBefore = true;
          }
        }
        needsRestart = _wasRunning && !pinnedBefore;
        // Открытый Claude уже ждёт затвор на своём порту — другой ему не
        // подойдёт.
        await _startGate(keepPort: pinnedBefore && _wasRunning);
        var pinned = true;
        for (final profile in launcher.profiles) {
          if (!await config.pin(launcher.dataDirOf(profile), gate.port!)) {
            pinned = false;
          }
        }
        unprotected = !pinned;
      } else {
        needsRestart = _wasRunning;
      }
    } catch (error) {
      debugPrint('Kill Switch: не удалось поднять затвор: $error');
    } finally {
      if (!ready.isCompleted) ready.complete();
    }
    if (!armed) return;
    _fingerprint = await _safeFingerprint();
    _verifying = false;
    // Страну обычно только что проверили — при запуске лаунчера.
    final checkedAt = location.checkedAt;
    final fresh =
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < const Duration(minutes: 2);
    if (fresh && location.state == LocationState.supported) {
      _accept(location.country);
    } else {
      await _verify();
    }
    notifyListeners();
  }

  /// Порт записан в конфигурацию Claude; если он занят — берём следующий и
  /// перезаписываем конфигурацию. [keepPort] — открытый Claude уже ждёт затвор
  /// на этом порту: ждём его дольше, а если так и не освободился — Claude
  /// придётся перезапустить ([needsRestart]).
  Future<void> _startGate({bool keepPort = false}) async {
    // Порт мог ещё не отпустить охранник после выхода или прежний затвор.
    final attempts = exactPort || keepPort ? 50 : 15;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await gate.start(settings.egressPort);
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (exactPort) {
      throw const SocketException('порт затвора так и не освободился');
    }
    for (
      var port = settings.egressPort + 1;
      port < settings.egressPort + 20;
      port++
    ) {
      try {
        await gate.start(port);
        await settings.setEgressPort(port);
        if (keepPort) needsRestart = true;
        return;
      } on SocketException {
        continue;
      }
    }
    throw const SocketException('не удалось открыть порт затвора');
  }

  /// Лаунчер запущен с выключенным Kill Switch, а конфигурация осталась:
  /// Kill Switch выключили при открытом Claude или прошлый лаунчер завершили
  /// принудительно. Открытому Claude — затвор «пропускать всё», пока его не
  /// закроют; если Claude не открыт — конфигурацию убираем.
  Future<void> _cleanStale() async {
    var pinned = false;
    for (final profile in launcher.profiles) {
      if (await config.isPinned(launcher.dataDirOf(profile))) pinned = true;
    }
    if (!(pinned || handover) || enabled || armed) return;
    if (_claudeRunning) {
      _passthrough = true;
      await _startPassthrough();
    } else {
      await _unpinAll();
    }
  }

  Future<void> _startPassthrough() async {
    try {
      await _startGate(keepPort: true);
    } catch (error) {
      debugPrint('Kill Switch: не удалось поднять затвор: $error');
    }
    notifyListeners();
  }

  void _disarm({bool stopGate = true}) {
    _poll?.cancel();
    _recheck?.cancel();
    _retry?.cancel();
    _poll = _recheck = _retry = null;
    _close();
    if (!_verdict.isCompleted) _verdict.complete(false);
    if (stopGate) unawaited(gate.stop());
    baseline = null;
    _fingerprint = _verified = null;
    _blockedAt = null;
    _verifying = false;
    needsRestart = false;
    unprotected = false;
    _ready = null;
  }

  Future<void> _unpinAll() async {
    for (final profile in launcher.profiles) {
      await config.unpin(launcher.dataDirOf(profile));
    }
  }

  /// Пропускать ли новое соединение: затвор открыт, и сеть та же, при которой
  /// проверена страна. Если сеть ещё проверяется — ждём ответа.
  Future<bool> _allows() async {
    if (_passthrough) return true;
    final deadline = DateTime.now().add(holdFor);
    while (enabled && armed) {
      final current = await _safeFingerprint();
      if (open && current == _verified) return true;
      if (current != null && current != _fingerprint) {
        // Сеть сменилась, а опрос ещё не заметил, — закрываем сами.
        _networkMoved(current);
      } else if (!_ensureVerifying()) {
        return false;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      final ok = await _verdict.future.timeout(left, onTimeout: () => false);
      if (!ok) return false;
      // Пропустили — но сеть могла смениться ещё раз: сверяем на новом круге.
    }
    return false;
  }

  /// Затвор закрыт — запускает проверку, если она ещё не идёт. false — затвор
  /// только что отказал окончательно: повторять проверку пока рано.
  bool _ensureVerifying({bool force = false}) {
    if (_verifying || (_retry?.isActive ?? false)) return true;
    final blockedAt = _blockedAt;
    if (!force &&
        blockedAt != null &&
        DateTime.now().difference(blockedAt) < blockedFor) {
      return false;
    }
    if (_verdict.isCompleted) _verdict = Completer<bool>();
    unawaited(_verify());
    return true;
  }

  void _close() {
    open = false;
    gate.cutAll();
    if (_verdict.isCompleted) _verdict = Completer<bool>();
  }

  /// Страна [country] проверена в нынешней сети — затвор открыт.
  void _accept(String? country) {
    baseline = country;
    _verified = _fingerprint;
    open = true;
    _blockedAt = null;
    if (!_verdict.isCompleted) _verdict.complete(true);
    notifyListeners();
  }

  /// Окончательный отказ: страна не та или Claude в ней недоступен.
  void _block() {
    _close();
    _blockedAt = DateTime.now();
    _verdict.complete(false);
  }

  Future<String?> _safeFingerprint() async {
    try {
      return await fingerprint();
    } catch (error) {
      debugPrint('Kill Switch: не удалось прочитать адреса: $error');
      return null;
    }
  }

  Future<void> _checkNetwork() async {
    if (!armed) return;
    final current = await _safeFingerprint();
    if (!armed || current == null || current == _fingerprint) return;
    await _networkMoved(current);
  }

  /// Сеть сменилась на [current]. Затвор закрывается сразу, синхронно, —
  /// каждая миллисекунда — возможный запрос; потом — проверка страны.
  Future<void> _networkMoved(String current) async {
    final previous = _fingerprint;
    _fingerprint = current;
    // Адреса только что прочитаны впервые — сравнивать не с чем.
    if (previous == null) return;
    _close();
    notifyListeners();
    if (strict && _claudeRunning) {
      await _fire(to: null, network: true);
      return;
    }
    await _verify();
  }

  /// Узнаёт страну в нынешней сети и решает: открыть затвор или закрыть Claude.
  Future<void> _verify() async {
    if (!armed) return;
    if (_verifying) {
      _again = true;
      return;
    }
    _verifying = true;
    _retry?.cancel();
    _retry = null;
    if (!open) notifyListeners();
    final fingerprintAtCheck = _fingerprint;
    try {
      final state = await location.check(force: true, background: true);
      if (!armed) return;
      // Сеть успела смениться ещё раз — этот ответ уже про другую сеть.
      if (_fingerprint != fingerprintAtCheck) {
        _again = true;
        return;
      }
      final country = location.country;
      switch (state) {
        case LocationState.unknown:
          // Нет сети — запросы и так не уходят. Затвор закрыт, соединения
          // ждут; повторим.
          if (open) _close();
          _retry = Timer(retryAfter, _verify);
        case LocationState.unsupported:
          _block();
          if (_claudeRunning) await _fire(to: country);
        case LocationState.supported
            when _claudeRunning && baseline != null && country != baseline:
          _block();
          await _fire(to: country);
        case LocationState.supported:
          _accept(country);
      }
    } finally {
      _verifying = false;
      notifyListeners();
      if (_again && armed) {
        _again = false;
        unawaited(_verify());
      }
    }
  }

  /// [network] — строгий режим: сеть сменилась, страну ещё не знаем.
  Future<void> _fire({required String? to, bool network = false}) async {
    final from = baseline;
    try {
      await launcher.killAll();
    } catch (error) {
      debugPrint('Kill Switch: не удалось закрыть Claude: $error');
    }
    lastFired = KillSwitchEvent(
      from: from ?? '',
      to: to,
      at: DateTime.now(),
      network: network,
    );
    // Claude закрыт — дальше затвор решает только за новый запуск.
    baseline = null;
    notifyListeners();
    onFired?.call();
    if (network) {
      // Для сообщения — какая теперь страна; заодно решаем про затвор.
      _verifying = false;
      if (_verdict.isCompleted) _verdict = Completer<bool>();
      await _verify();
      if (location.state != LocationState.unknown) {
        lastFired = KillSwitchEvent(
          from: from ?? '',
          to: location.country,
          at: lastFired!.at,
          network: true,
        );
        notifyListeners();
      }
    }
    try {
      await notifier?.show(
        id: _notificationId,
        title: 'Kill Switch закрыл Claude',
        body: describe(lastFired!),
      );
    } catch (error) {
      debugPrint('Kill Switch: не удалось уведомить: $error');
    }
  }

  static const _notificationId = 0x6b11;

  /// «Страна сменилась: Германия → Россия. Проверьте VPN, прежде чем снова
  /// открывать Claude.»
  static String describe(KillSwitchEvent event) {
    String name(String? code) => code == null || code.isEmpty
        ? 'неизвестно'
        : countryNames[code] ?? code;
    final change = switch (event) {
      KillSwitchEvent(network: true, to: null) => 'Сменилась сеть',
      KillSwitchEvent(network: true, :final from, :final to?)
          when from.isNotEmpty && from != to =>
        'Сменилась сеть и страна: ${name(from)} → ${name(to)}',
      KillSwitchEvent(network: true, :final to?) =>
        'Сменилась сеть, страна — ${name(to)}',
      KillSwitchEvent(from: '') =>
        'Claude открыт там, где он недоступен: ${name(event.to)}',
      _ => 'Страна сменилась: ${name(event.from)} → ${name(event.to)}',
    };
    return '$change. Проверьте VPN, прежде чем снова открывать Claude.';
  }
}
