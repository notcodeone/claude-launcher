import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';
import 'package:win32/win32.dart';

/// Вход Claude Desktop в профиле — только чтобы запросить лимиты тем же
/// запросом, что и сам Claude (решение автора 2026-10-05, «вариант Б»).
///
/// Claude хранит токены в `config.json` → `oauth:tokenCacheV2`: base64 от
/// `safeStorage.encryptString(JSON)`. Ключ — macOS: пароль «Claude Safe
/// Storage» в Связке ключей (общий для всех профилей одной установки);
/// Windows: `os_crypt.encrypted_key` из `Local State` профиля под DPAPI.
///
/// Секреты не пишутся на диск и в журнал, ключ живёт в памяти лаунчера до
/// выхода. Токены лаунчер не обновляет — это делает только Claude.
class ClaudeCredentials {
  ClaudeCredentials({SafeStorageKey? key, bool Function()? mayAsk})
    : _key = key ?? SafeStorageKey.forCurrentPlatform(mayAsk: mayAsk);

  final SafeStorageKey? _key;

  /// Спросить ключ сейчас — по явному согласию пользователя (окно перед
  /// вопросом macOS). true — ключ получен.
  Future<bool> unlock() async => await _key?.unlock() ?? false;

  static const _cacheKey = 'oauth:tokenCacheV2';

  /// Клиент OAuth самого Claude Desktop — им Claude запрашивает лимиты.
  static const desktopClient = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const apiHost = 'https://api.anthropic.com';

  /// Действующий токен аккаунта [account] в организации [org] из папки
  /// профиля [dataDir]; `null` — нет входа, токен истёк или ключ недоступен.
  Future<String?> accessToken({
    required String dataDir,
    required String account,
    required String org,
    DateTime? now,
  }) async {
    final key = _key;
    if (key == null) return null;
    final Object? config;
    try {
      config = jsonDecode(
        await File(p.join(dataDir, 'config.json')).readAsString(),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (config is! Map || config[_cacheKey] is! String) return null;
    final secret = await key.read(dataDir);
    if (secret == null) return null;
    final plain = decrypt(base64Decode(config[_cacheKey] as String), secret);
    if (plain == null) return null;
    final Object? entries;
    try {
      entries = jsonDecode(utf8.decode(plain));
    } on FormatException {
      return null;
    }
    if (entries is! Map) return null;
    return pickToken(
      entries.cast<String, Object?>(),
      account: account,
      org: org,
      now: now ?? DateTime.now(),
    );
  }

  /// Записи кэша: `acct:<аккаунт>|<клиент>:<организация>:<хост API>:<права>` →
  /// `{token, refreshToken, expiresAt}`. Берём действующую запись этого
  /// аккаунта и организации с правом `user:profile`; клиент Claude Desktop —
  /// в первую очередь.
  static String? pickToken(
    Map<String, Object?> entries, {
    required String account,
    required String org,
    required DateTime now,
  }) {
    final prefix = 'acct:${account.toLowerCase()}|';
    final marker = ':${org.toLowerCase()}:$apiHost:';
    String? best;
    var bestRank = -1;
    for (final MapEntry(:key, :value) in entries.entries) {
      final lower = key.toLowerCase();
      if (!lower.startsWith(prefix) || value is! Map) continue;
      final rest = lower.substring(prefix.length);
      final at = rest.indexOf(marker);
      if (at < 0) continue;
      final client = rest.substring(0, at);
      final scopes = rest.substring(at + marker.length).split(' ');
      if (!scopes.contains('user:profile')) continue;
      final token = value['token'];
      final expires = value['expiresAt'];
      if (token is! String || expires is! num) continue;
      // Последние две минуты — как истёкший: Claude вот-вот его заменит.
      final until = DateTime.fromMillisecondsSinceEpoch(expires.toInt());
      if (!until.isAfter(now.add(const Duration(minutes: 2)))) continue;
      final rank = client == desktopClient ? 1 : 0;
      if (rank > bestRank) {
        best = token;
        bestRank = rank;
      }
    }
    return best;
  }

  /// `v10` + шифротекст. macOS — AES-128-CBC (ключ — PBKDF2-SHA1 от пароля,
  /// соль `saltysalt`, 1003 итерации, IV — 16 пробелов); Windows — AES-256-GCM
  /// (12 байт nonce, в конце 16 байт тега). `null` — не тот формат или ключ.
  static Uint8List? decrypt(Uint8List data, SafeStorageSecret secret) {
    if (data.length < 3 ||
        ascii.decode(data.sublist(0, 3), allowInvalid: true) != 'v10') {
      return null;
    }
    final body = data.sublist(3);
    try {
      switch (secret) {
        case MacSecret(:final password):
          final cipher =
              PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
                ..init(
                  false,
                  PaddedBlockCipherParameters(
                    ParametersWithIV(
                      KeyParameter(macKey(password)),
                      Uint8List(16)..fillRange(0, 16, 0x20),
                    ),
                    null,
                  ),
                );
          return cipher.process(body);
        case WindowsSecret(:final key):
          if (body.length < 12 + 16) return null;
          final cipher = GCMBlockCipher(AESEngine())
            ..init(
              false,
              AEADParameters(
                KeyParameter(key),
                128,
                body.sublist(0, 12),
                Uint8List(0),
              ),
            );
          return cipher.process(body.sublist(12));
      }
    } on ArgumentError {
      return null; // Неверный ключ или повреждённые данные.
    } on InvalidCipherTextException {
      return null;
    } on StateError {
      return null;
    }
  }

  /// Ключ AES из пароля Связки ключей (как в Chromium OSCrypt на macOS).
  static Uint8List macKey(String password) =>
      (PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
            ..init(Pbkdf2Parameters(utf8.encode('saltysalt'), 1003, 16)))
          .process(utf8.encode(password));
}

/// Ключ расшифровки safeStorage.
sealed class SafeStorageSecret {
  const SafeStorageSecret();
}

class MacSecret extends SafeStorageSecret {
  const MacSecret(this.password);
  final String password;
}

class WindowsSecret extends SafeStorageSecret {
  const WindowsSecret(this.key);
  final Uint8List key;
}

abstract class SafeStorageKey {
  /// Ключ для профиля в [dataDir]; `null` — недоступен (отказали в доступе,
  /// Claude в профиле ещё не открывали).
  Future<SafeStorageSecret?> read(String dataDir);

  /// Получить ключ, даже если раньше отказали; true — получен.
  Future<bool> unlock() async => true;

  static SafeStorageKey? forCurrentPlatform({bool Function()? mayAsk}) {
    if (Platform.isMacOS) return MacSafeStorageKey(mayAsk: mayAsk);
    if (Platform.isWindows) return WindowsSafeStorageKey();
    return null;
  }
}

/// macOS: пароль «Claude Safe Storage» из Связки ключей — нативно, от имени
/// лаунчера (MainFlutterWindow.swift). В первый раз macOS спросит пароль
/// пользователя; «Всегда разрешать» снимает вопрос до смены подписи лаунчера.
class MacSafeStorageKey implements SafeStorageKey {
  MacSafeStorageKey({this.mayAsk});

  /// Можно ли обращаться к Связке ключей без нашего окна: пользователь уже
  /// разрешил этой версии лаунчера — тогда macOS ответит без вопроса. Иначе
  /// вопрос macOS выскочил бы без объяснения — ждём [unlock].
  final bool Function()? mayAsk;

  static const _channel = MethodChannel('claude_launcher/native');
  MacSecret? _cached;
  bool _denied = false;

  @override
  Future<bool> unlock() async {
    _denied = false;
    return await _ask() != null;
  }

  @override
  Future<SafeStorageSecret?> read(String dataDir) async {
    if (_cached case final cached?) return cached;
    // Отказали — не спрашиваем снова до перезапуска лаунчера.
    if (_denied || !(mayAsk?.call() ?? true)) return null;
    return _ask();
  }

  Future<MacSecret?> _ask() async {
    if (_cached case final cached?) return cached;
    final password = await _channel.invokeMethod<String>('safeStorageKey');
    if (password == null) {
      _denied = true;
      return null;
    }
    return _cached = MacSecret(password);
  }
}

/// Windows: `Local State` → `os_crypt.encrypted_key` (base64, префикс `DPAPI`)
/// → `CryptUnprotectData` без интерфейса. У каждой папки профиля — свой ключ.
class WindowsSafeStorageKey implements SafeStorageKey {
  final _cache = <String, WindowsSecret>{};

  /// DPAPI ничего не спрашивает — доступ есть всегда.
  @override
  Future<bool> unlock() async => true;

  /// `CRYPTPROTECT_UI_FORBIDDEN`: не показывать никаких окон.
  static const _uiForbidden = 0x1;

  @override
  Future<SafeStorageSecret?> read(String dataDir) async {
    if (_cache[dataDir] case final cached?) return cached;
    try {
      final state = jsonDecode(
        await File(p.join(dataDir, 'Local State')).readAsString(),
      );
      if (state is! Map) return null;
      final crypt = state['os_crypt'];
      final encoded = crypt is Map ? crypt['encrypted_key'] : null;
      if (encoded is! String) return null;
      final blob = base64Decode(encoded);
      if (blob.length < 5 || ascii.decode(blob.sublist(0, 5)) != 'DPAPI') {
        return null;
      }
      final key = _unprotect(blob.sublist(5));
      if (key == null) return null;
      return _cache[dataDir] = WindowsSecret(key);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List? _unprotect(Uint8List data) => using((arena) {
    final bytes = arena<Uint8>(data.length);
    bytes.asTypedList(data.length).setAll(0, data);
    final input = arena<CRYPT_INTEGER_BLOB>();
    input.ref
      ..cbData = data.length
      ..pbData = bytes;
    final output = arena<CRYPT_INTEGER_BLOB>();
    final ok = CryptUnprotectData(
      input,
      null,
      null,
      null,
      _uiForbidden,
      output,
    );
    if (!ok.value) return null;
    try {
      return Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData),
      );
    } finally {
      LocalFree(HLOCAL(output.ref.pbData));
    }
  });
}
