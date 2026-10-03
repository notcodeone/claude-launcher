import 'dart:typed_data';

import 'package:claude_launcher/src/claude/windows_link_probe_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProbe extends WindowsLinkProbeApi {
  static const original = LinkProbeProcess(
    20,
    r'C:\Apps\Claude.exe',
    r'C:\Profiles\B',
    'first',
  );
  LinkProbeProcess? process = original;
  LinkProbeProcess? second = original;
  final handles = <int>[100];
  bool owner = true;
  bool ack = true;
  int inspections = 0;
  int sends = 0;
  Duration? timeout;
  Uint16List? payload;
  @override
  Future<LinkProbeProcess?> inspect(int pid) async =>
      inspections++ == 0 ? process : second;
  @override
  List<int> receivers(String dataDir) => handles;
  @override
  bool ownsReceiver(int handle, int pid, String dataDir) => owner;
  @override
  bool send(int handle, Uint16List payload, Duration timeout) {
    sends++;
    this.timeout = timeout;
    this.payload = payload;
    return ack;
  }
}

void main() {
  final link = Uri.parse('claude://claude.ai/epitaxy/local_test');
  Future<void> deliver(FakeProbe api, {Uri? url, String? dir}) =>
      WindowsLinkProbeTransport(
        api,
      ).deliver(20, dir ?? FakeProbe.original.dataDir, url ?? link);

  test('frame preserves UTF-16 paths and uses one bounded send', () async {
    final api = FakeProbe();
    await deliver(api);
    expect(api.sends, 1);
    expect(api.timeout, const Duration(seconds: 2));
    final text = String.fromCharCodes(api.payload!);
    final fields = text.split('\u0000');
    expect(fields, [
      'START',
      r'C:\Apps',
      '"C:\\Apps\\Claude.exe" "--user-data-dir=C:\\Profiles\\B" "$link"',
      '',
    ]);
    final unicode = codeLinkProbePayload(
      const LinkProbeProcess(
        20,
        r'C:\Программы\Claude.exe',
        r'C:\Профили\🐈',
        '1',
      ),
      link,
    );
    expect(String.fromCharCodes(unicode), contains('Профили\\🐈'));
  });

  test('argument quoting escapes quotes and trailing backslashes', () {
    expect(quoteWindowsArgument('a"b'), '"a\\"b"');
    expect(quoteWindowsArgument('C:\\a b\\'), '"C:\\a b\\\\"');
    expect(() => quoteWindowsArgument('a\u0000b'), throwsArgumentError);
  });

  test('foreign path and unverified process are never sent', () async {
    for (final api in [
      FakeProbe()..process = null,
      FakeProbe()
        ..process = const LinkProbeProcess(
          20,
          r'C:\Apps\Claude.exe',
          r'C:\Profiles\A',
          'first',
        ),
    ]) {
      await expectLater(deliver(api), throwsStateError);
      expect(api.sends, 0);
    }
  });

  test('missing, duplicate and foreign receiver fail closed', () async {
    for (final api in [
      FakeProbe()..handles.clear(),
      FakeProbe()..handles.add(200),
      FakeProbe()..owner = false,
    ]) {
      await expectLater(deliver(api), throwsStateError);
      expect(api.sends, 0);
    }
  });

  test(
    'reused PID, changed executable, changed directory and closure rejected',
    () async {
      for (final second in [
        null,
        const LinkProbeProcess(
          20,
          r'C:\Apps\Claude.exe',
          r'C:\Profiles\B',
          'new',
        ),
        const LinkProbeProcess(
          20,
          r'C:\Other\Claude.exe',
          r'C:\Profiles\B',
          'first',
        ),
        const LinkProbeProcess(
          20,
          r'C:\Apps\Claude.exe',
          r'C:\Profiles\A',
          'first',
        ),
      ]) {
        final api = FakeProbe()..second = second;
        await expectLater(deliver(api), throwsStateError);
        expect(api.sends, 0);
      }
    },
  );

  test('invalid paths and oversized frames are rejected before sending', () {
    for (final process in [
      const LinkProbeProcess(20, 'Claude.exe', r'C:\Profiles\B', '1'),
      const LinkProbeProcess(20, r'C:\Apps\Claude.exe', 'relative', '1'),
      const LinkProbeProcess(
        20,
        r'C:\Apps\Claude.exe',
        'C:\\bad\u0000path',
        '1',
      ),
      LinkProbeProcess(20, r'C:\Apps\Claude.exe', 'C:\\${'a' * 32768}', '1'),
    ]) {
      expect(() => codeLinkProbePayload(process, link), throwsArgumentError);
    }
  });

  test('timeout/refusal is not retried', () async {
    final api = FakeProbe()..ack = false;
    await expectLater(deliver(api), throwsStateError);
    expect(api.sends, 1);
  });

  test(
    'auth, foreign URL, encoded separator, switches and query rejected',
    () async {
      for (final value in [
        'claude://claude.ai/login?code=secret',
        'https://claude.ai/epitaxy/test',
        'claude://other/epitaxy/test',
        'claude://claude.ai/epitaxy/a%2Fb',
        'claude://claude.ai/epitaxy/test?code=secret',
        'claude://claude.ai/epitaxy/--flag%20x',
      ]) {
        final api = FakeProbe();
        await expectLater(
          deliver(api, url: Uri.parse(value)),
          throwsArgumentError,
        );
        expect(api.sends, 0);
      }
    },
  );
}
