import 'dart:io';

import 'package:claude_launcher/src/app_settings.dart';
import 'package:claude_launcher/src/launcher_controller.dart';
import 'package:claude_launcher/src/location/kill_switch.dart';
import 'package:claude_launcher/src/location/location_guard.dart';
import 'package:claude_launcher/src/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'launcher_controller_test.dart' show FakeHost;

void main() {
  late Directory dir;
  late AppSettings settings;
  late FakeHost host;
  late LauncherController launcher;
  late LocationGuard location;
  late List<String?> answers;
  late int lookups;
  late String network;
  late int fired;
  late Duration lookupDelay;

  KillSwitch killSwitch({bool useGate = false}) => KillSwitch(
    settings: settings,
    location: location,
    launcher: launcher,
    onFired: () => fired++,
    fingerprint: () async => network,
    pollEvery: const Duration(milliseconds: 10),
    recheckEvery: const Duration(hours: 1),
    retryAfter: const Duration(milliseconds: 20),
    holdFor: const Duration(seconds: 2),
    blockedFor: const Duration(milliseconds: 100),
    useGate: useGate,
  );

  Future<void> wait() => Future<void>.delayed(const Duration(milliseconds: 80));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kill_switch');
    settings = AppSettings(File('${dir.path}/settings.json'));
    await settings.load();
    await settings.setKillSwitch(true);
    host = FakeHost();
    launcher = LauncherController(
      host: host,
      store: ProfileStore(File('${dir.path}/profiles.json')),
    );
    answers = ['DE'];
    lookups = 0;
    network = 'en0=192.168.1.5,utun4=10.8.0.2';
    fired = 0;
    lookupDelay = Duration.zero;
    // Свободный порт: затвор в тестах слушает по-настоящему.
    await settings.setEgressPort(0);
    location = LocationGuard(
      settings: settings,
      lookup: () async {
        lookups++;
        await Future<void>.delayed(lookupDelay);
        final answer = answers.length > 1
            ? answers.removeAt(0)
            : answers.single;
        if (answer == null) throw const CountryLookupException(['нет сети']);
        return (country: answer, source: 'тест');
      },
    );
    // Claude открыт в Германии — как после запуска профиля.
    await location.check();
    host.start(null);
    await launcher.refresh();
  });

  tearDown(() async {
    location.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'смена страны после смены сети — затвор закрыт, Claude закрыт',
    () async {
      final ks = killSwitch()..start();
      addTearDown(ks.dispose);
      await wait();
      expect(ks.armed, isTrue);
      expect(ks.open, isTrue);
      expect(ks.baseline, 'DE');

      answers = ['RU'];
      network = 'en0=192.168.1.5';
      await wait();
      expect(ks.open, isFalse);
      expect(host.instances, isEmpty);
      expect(fired, 1);
      expect(ks.lastFired?.from, 'DE');
      expect(ks.lastFired?.to, 'RU');
      expect(KillSwitch.describe(ks.lastFired!), contains('Германия → Россия'));
    },
  );

  test(
    'та же страна после переподключения VPN — затвор снова открыт',
    () async {
      final ks = killSwitch()..start();
      addTearDown(ks.dispose);
      await wait();
      final before = lookups;
      network = 'en0=192.168.1.5,utun5=10.8.0.9';
      await wait();
      expect(lookups, greaterThan(before));
      expect(ks.open, isTrue);
      expect(host.instances, isNotEmpty);
      expect(fired, 0);
    },
  );

  test('страну узнать не удалось — затвор закрыт, проверяет снова', () async {
    final ks = killSwitch()..start();
    addTearDown(ks.dispose);
    await wait();
    answers = [null, null, 'NL'];
    network = 'en0=10.0.0.7';
    await wait();
    await wait();
    // Германия → Нидерланды: страна другая, хоть и поддерживается.
    expect(fired, 1);
    expect(ks.lastFired?.to, 'NL');
  });

  test('строгий режим — закрывает Claude при смене сети сразу', () async {
    await settings.setKillSwitchStrict(true);
    final ks = killSwitch()..start();
    addTearDown(ks.dispose);
    await wait();
    final before = lookups;
    network = 'en0=192.168.1.5';
    await ks.networkChanged();
    expect(host.instances, isEmpty);
    expect(fired, 1);
    expect(ks.lastFired?.network, isTrue);
    // Страну узнаёт уже после — для сообщения и затвора.
    await wait();
    expect(lookups, greaterThan(before));
    expect(ks.lastFired?.to, 'DE');
  });

  test(
    'выключен — ничего не делает; Claude закрыт — без лишних проверок',
    () async {
      await settings.setKillSwitch(false);
      final ks = killSwitch()..start();
      addTearDown(ks.dispose);
      await wait();
      expect(ks.armed, isFalse);
      expect(ks.open, isFalse);

      await settings.setKillSwitch(true);
      await wait();
      expect(ks.armed, isTrue);
      expect(ks.open, isTrue);

      // Claude закрыт: страна проверяется, только если сменилась сеть.
      host.instances.clear();
      await launcher.refresh();
      await wait();
      final before = lookups;
      await wait();
      expect(lookups, before);
      network = 'en0=172.16.0.2';
      await wait();
      expect(lookups, before + 1);
      expect(ks.open, isTrue);
      expect(fired, 0);
    },
  );

  test('пока сеть проверяется, соединение ждёт, а не получает отказ', () async {
    final ks = killSwitch()..start();
    addTearDown(ks.dispose);
    await wait();
    lookupDelay = const Duration(milliseconds: 300);
    network = 'en0=192.168.1.5,utun5=10.8.0.9';
    final allowed = ks.gate.allow();
    await wait();
    expect(ks.open, isFalse);
    expect(await allowed, isTrue);
    expect(ks.open, isTrue);
    expect(fired, 0);
  });

  test('другая страна — ждущее соединение получает отказ', () async {
    final ks = killSwitch()..start();
    addTearDown(ks.dispose);
    await wait();
    lookupDelay = const Duration(milliseconds: 200);
    answers = ['RU'];
    network = 'en0=192.168.1.5';
    expect(await ks.gate.allow(), isFalse);
    await wait();
    expect(fired, 1);
  });

  test(
    'после срабатывания новый запуск Claude проверяет сеть заново',
    () async {
      final ks = killSwitch()..start();
      addTearDown(ks.dispose);
      await wait();
      answers = ['NL'];
      network = 'en0=10.0.0.7';
      await wait();
      expect(fired, 1);
      expect(await ks.gate.allow(), isFalse);
      // Пользователь проверил VPN и открыл Claude снова — в Нидерландах.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      host.start(null);
      await launcher.refresh();
      expect(await ks.gate.allow(), isTrue);
      expect(ks.baseline, 'NL');
    },
  );

  test(
    'выключили при открытом Claude — затвор пропускает всё, пока он открыт',
    () async {
      final ks = killSwitch(useGate: true)..start();
      addTearDown(() => ks.shutdown(keepPinned: false));
      await wait();
      expect(ks.gate.port, isNotNull);

      await settings.setKillSwitch(false);
      await wait();
      expect(ks.armed, isFalse);
      expect(ks.passthrough, isTrue);
      expect(ks.gate.port, isNotNull);
      answers = ['RU'];
      network = 'en0=192.168.1.5';
      expect(await ks.gate.allow(), isTrue);

      host.instances.clear();
      await launcher.refresh();
      await wait();
      expect(ks.passthrough, isFalse);
      expect(ks.gate.port, isNull);
      expect(await ks.gate.allow(), isFalse);
    },
  );

  test('«Проверить сеть» — шапка видит проверку, затвор не рвётся', () async {
    final ks = killSwitch()..start();
    addTearDown(ks.dispose);
    await wait();
    expect(ks.checking, isFalse);
    final before = lookups;
    final check = ks.checkNow();
    expect(ks.checking, isTrue);
    expect(ks.open, isTrue);
    await check;
    expect(ks.checking, isFalse);
    expect(lookups, before + 1);
    expect(ks.open, isTrue);
  });

  test('адаптеры виртуальных машин — не смена сети, VPN — смена', () {
    expect(isVirtualMachineAdapter('bridge100'), isTrue);
    expect(isVirtualMachineAdapter('vEthernet (Default Switch)'), isTrue);
    expect(
      isVirtualMachineAdapter('vEthernet (WSL (Hyper-V firewall))'),
      isTrue,
    );
    expect(isVirtualMachineAdapter('utun4'), isFalse);
    expect(isVirtualMachineAdapter('en0'), isFalse);
    expect(isVirtualMachineAdapter('Wi-Fi'), isFalse);
    expect(isVirtualMachineAdapter('WireGuard Tunnel'), isFalse);
    expect(isVirtualMachineAdapter('vEthernet (External)'), isFalse);
  });

  test(
    'записка охранника: открытый Claude получает затвор без конфигурации',
    () async {
      await settings.setKillSwitch(false);
      final ks = killSwitch(useGate: true)..handover = true;
      ks.start();
      addTearDown(() => ks.shutdown(keepPinned: false));
      await wait();
      expect(ks.passthrough, isTrue);
      expect(ks.gate.port, isNotNull);
      expect(await ks.gate.allow(), isTrue);
    },
  );

  test('записка, а Claude уже закрыт, — затвор не нужен', () async {
    await settings.setKillSwitch(false);
    host.instances.clear();
    await launcher.refresh();
    final ks = killSwitch(useGate: true)..handover = true;
    ks.start();
    addTearDown(() => ks.shutdown(keepPinned: false));
    await wait();
    expect(ks.handover, isFalse);
    expect(ks.passthrough, isFalse);
    expect(ks.gate.port, isNull);
  });
}
