import 'package:claude_launcher/src/claude/windows_claude_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('журнал Claude', () {
    const appData = '/u/AppData/Roaming';
    const local = '/u/AppData/Local';

    test('папка в %APPDATA% — журнал в %LOCALAPPDATA% и в копии пакета', () {
      final files = WindowsClaudeHost.logFiles(
        dataDirs: {p.join(appData, 'Claude-Work')},
        appData: appData,
        localAppData: local,
        packageFamily: 'Claude_pzs8sxrjxfjjc',
      );
      expect(files, [
        '$local/Claude-Work/logs/main.log',
        '$local/Packages/Claude_pzs8sxrjxfjjc/LocalCache/Local/Claude-Work/logs/main.log',
        '$appData/Claude-Work/logs/main.log',
      ]);
    });

    test('папка вне %APPDATA% — только в ней самой', () {
      expect(
        WindowsClaudeHost.logFiles(
          dataDirs: {'$local/Claude-Data'},
          appData: appData,
          localAppData: local,
        ),
        ['$local/Claude-Data/logs/main.log'],
      );
    });
  });

  group('конец загрузки', () {
    final started = DateTime(2026, 10, 3, 14, 0, 5, 700);

    test('строка этого запуска — загружен, даже в ту же секунду', () {
      const log =
          '2026-10-03 14:00:01 [info] boot: done\n'
          '2026-10-03 14:00:05 [info] mainView restored (boot: done, x)\n';
      expect(WindowsClaudeHost.bootedSince(log, started), isTrue);
    });

    test('строка прошлого запуска не считается', () {
      const log =
          '2026-10-03 13:59:59 [info] boot: done\n'
          '2026-10-03 14:00:06 [info] Starting app\n';
      expect(WindowsClaudeHost.bootedSince(log, started), isFalse);
    });

    test('без времени в начале строки не считается', () {
      const log = '  boot: done\n';
      expect(WindowsClaudeHost.bootedSince(log, started), isFalse);
    });
  });
}
