import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_launcher/src/location/egress_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ServerSocket echo;
  late EgressGate gate;
  var allowed = true;

  setUp(() async {
    echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((socket) => socket.listen(socket.add, onDone: socket.destroy));
    allowed = true;
    gate = EgressGate(allow: () async => allowed);
    await gate.start(0);
  });

  tearDown(() async {
    await gate.stop();
    await echo.close();
  });

  Future<(Socket, Stream<String>)> connect() async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      gate.port!,
    );
    final text = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .asBroadcastStream();
    socket.add(
      utf8.encode(
        'CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\nHost: x\r\n\r\nhello',
      ),
    );
    return (socket, text);
  }

  test('пропускает туннель, пока можно', () async {
    final (socket, text) = await connect();
    final received = StringBuffer();
    final sub = text.listen(received.write);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received.toString(), contains('200 Connection Established'));
    expect(received.toString(), endsWith('hello'));
    await sub.cancel();
    socket.destroy();
  });

  test('нельзя — отказ, соединение не открывается', () async {
    allowed = false;
    final (socket, text) = await connect();
    final reply = await text.join();
    expect(reply, contains('403'));
    socket.destroy();
  });

  test('cutAll рвёт открытые туннели', () async {
    final (socket, text) = await connect();
    final closed = Completer<void>();
    text.listen((_) {}, onDone: closed.complete);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    gate.cutAll();
    await closed.future.timeout(const Duration(seconds: 2));
    socket.destroy();
  });
}
