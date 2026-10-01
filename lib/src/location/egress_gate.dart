import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Прокси-затвор Kill Switch: весь трафик Claude — приложения, его Claude Code
/// и машины Cowork — идёт через него (см. [EgressConfig]), а он пропускает
/// соединение, только пока [allow] разрешает. Трафик не расшифровывает: для
/// HTTPS (`CONNECT`) лишь пересылает байты, для HTTP пересылает запрос.
///
/// Перед каждым новым соединением спрашивает [allow] — там сверяется сеть, —
/// поэтому из сменившейся сети не открывается ни одно соединение. [cutAll]
/// мгновенно рвёт уже открытые.
class EgressGate {
  EgressGate({required this.allow});

  /// Можно ли сейчас выпустить соединение.
  final Future<bool> Function() allow;

  ServerSocket? _server;
  final _tunnels = <Socket>{};

  int? get port => _server?.port;

  /// Слушает только 127.0.0.1: снаружи компьютера затвор недоступен. Машина
  /// Cowork ходит к нему через адрес хоста — так задумано самим Claude.
  Future<void> start(int port) async {
    if (_server != null) return;
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(
      _accept,
      onError: (Object error) {
        debugPrint('Затвор: $error');
      },
    );
  }

  Future<void> stop() async {
    cutAll();
    // Сразу забываем сервер: start() сразу после stop() должен открыть новый,
    // а не принять закрывающийся за работающий.
    final server = _server;
    _server = null;
    await server?.close();
  }

  /// Рвёт все открытые соединения — сеть сменилась.
  void cutAll() {
    for (final socket in _tunnels.toList()) {
      socket.destroy();
    }
    _tunnels.clear();
  }

  Future<void> _accept(Socket client) async {
    _tunnels.add(client);
    Socket? upstream;
    StreamSubscription<Uint8List>? clientSubscription;
    try {
      final head = await _readHead(client);
      if (head == null) return client.destroy();
      final (requestLine, rest, subscription) = head;
      clientSubscription = subscription;
      final parts = requestLine.split(' ');
      if (parts.length < 3) return _refuse(client, 400);

      if (!await allow()) return _refuse(client, 403);

      if (parts[0] == 'CONNECT') {
        final target = _hostPort(parts[1], 443);
        if (target == null) return _refuse(client, 400);
        upstream = await Socket.connect(
          target.$1,
          target.$2,
          timeout: const Duration(seconds: 15),
        );
        _tunnels.add(upstream);
        client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        if (rest.isNotEmpty) upstream.add(rest);
      } else {
        // Обычный HTTP: «GET http://host/path» → «GET /path» к host.
        final uri = Uri.tryParse(parts[1]);
        if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) {
          return _refuse(client, 400);
        }
        upstream = await Socket.connect(
          uri.host,
          uri.hasPort ? uri.port : 80,
          timeout: const Duration(seconds: 15),
        );
        _tunnels.add(upstream);
        final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
        upstream.add(
          ascii.encode(
            '${parts[0]} ${path.isEmpty ? '/' : path} ${parts[2]}\r\n',
          ),
        );
        upstream.add(rest);
      }
      _pipe(client, clientSubscription, upstream);
    } catch (_) {
      await clientSubscription?.cancel();
      if (upstream != null) _tunnels.remove(upstream..destroy());
      _tunnels.remove(client..destroy());
    }
  }

  /// [fromClient] — подписка, которой прочитан заголовок: поток сокета
  /// слушают один раз, дальше она же пересылает данные.
  void _pipe(
    Socket client,
    StreamSubscription<Uint8List> fromClient,
    Socket upstream,
  ) {
    var open = 2;
    void forget() {
      _tunnels
        ..remove(client)
        ..remove(upstream);
    }

    void fail() {
      forget();
      fromClient.cancel();
      client.destroy();
      upstream.destroy();
    }

    // Одна сторона закончила — закрываем запись в другую, дописав всё, что
    // уже пришло: destroy() отбросил бы хвост ответа.
    void finished(Socket other) {
      other.close().catchError((Object _) => other);
      if (--open == 0) forget();
    }

    fromClient
      ..onData(upstream.add)
      ..onDone(() => finished(upstream))
      ..onError((Object _) => fail())
      ..resume();
    upstream.listen(
      client.add,
      onDone: () => finished(client),
      onError: (_) => fail(),
      cancelOnError: true,
    );
  }

  /// Первая строка запроса и всё, что пришло после неё: для CONNECT — после
  /// заголовков (их прокси не пересылает), для HTTP — заголовки и тело.
  Future<(String, Uint8List, StreamSubscription<Uint8List>)?> _readHead(
    Socket client,
  ) async {
    final buffer = BytesBuilder();
    final done = Completer<(String, Uint8List)?>();
    late StreamSubscription<Uint8List> subscription;
    subscription = client.listen(
      (chunk) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final lineEnd = _indexOf(bytes, const [13, 10]);
        if (lineEnd < 0) {
          if (bytes.length > 16384) done.complete(null);
          return;
        }
        final line = latin1.decode(bytes.sublist(0, lineEnd));
        if (line.startsWith('CONNECT ')) {
          final headersEnd = _indexOf(bytes, const [13, 10, 13, 10]);
          if (headersEnd < 0) return;
          done.complete((line, bytes.sublist(headersEnd + 4)));
        } else {
          done.complete((line, bytes.sublist(lineEnd + 2)));
        }
        subscription.pause();
      },
      onDone: () {
        if (!done.isCompleted) done.complete(null);
      },
      onError: (_) {
        if (!done.isCompleted) done.complete(null);
      },
    );
    final head = await done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    if (head == null) {
      await subscription.cancel();
      return null;
    }
    return (head.$1, head.$2, subscription);
  }

  void _refuse(Socket client, int status) {
    try {
      client.add(
        ascii.encode(
          'HTTP/1.1 $status ${status == 403 ? 'Blocked by ClaudeLauncher' : 'Bad Request'}\r\n'
          'Connection: close\r\nContent-Length: 0\r\n\r\n',
        ),
      );
    } catch (_) {}
    _tunnels.remove(client);
    client.destroy();
  }

  static (String, int)? _hostPort(String value, int defaultPort) {
    final match = RegExp(r'^\[?([^\]]+?)\]?(?::(\d+))?$').firstMatch(value);
    if (match == null) return null;
    final port = int.tryParse(match.group(2) ?? '') ?? defaultPort;
    return (match.group(1)!, port);
  }

  static int _indexOf(List<int> bytes, List<int> pattern) {
    outer:
    for (var i = 0; i + pattern.length <= bytes.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
