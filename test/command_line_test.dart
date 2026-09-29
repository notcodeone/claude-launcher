import 'package:claude_launcher/src/claude/command_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS', () {
    test('parsePsLine', () {
      final parsed = parsePsLine('  4321 /Applications/Claude.app/Contents/MacOS/Claude');
      expect(parsed?.pid, 4321);
      expect(parsed?.command, '/Applications/Claude.app/Contents/MacOS/Claude');
      expect(parsePsLine(''), isNull);
    });

    test('главный процесс отличается от helper-процессов и CLI', () {
      expect(isMacClaudeMainProcess('/Applications/Claude.app/Contents/MacOS/Claude'), isTrue);
      expect(
        isMacClaudeMainProcess(
            '/Users/me/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/x'),
        isTrue,
      );
      expect(
        isMacClaudeMainProcess('/Applications/Claude.app/Contents/Frameworks/'
            'Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer'),
        isFalse,
      );
      expect(isMacClaudeMainProcess('/Users/me/.local/bin/claude --resume'), isFalse);
    });

    test('папка данных с пробелами и следующими флагами', () {
      const dir = '/Users/me/Library/Application Support/Claude-Work';
      expect(macUserDataDir('/A/Claude --user-data-dir=$dir'), dir);
      expect(macUserDataDir('/A/Claude --user-data-dir=$dir --inspect'), dir);
      expect(macUserDataDir('/A/Claude'), isNull);
    });
  });

  group('Windows', () {
    const exe = r'"C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__pzs8sxrjxfjjc\app\Claude.exe"';

    test('три формы --user-data-dir', () {
      expect(
        windowsUserDataDir('$exe "--user-data-dir=C:\\Users\\Иван Петров\\AppData\\Roaming\\Claude-Work"'),
        r'C:\Users\Иван Петров\AppData\Roaming\Claude-Work',
      );
      expect(
        windowsUserDataDir('$exe --user-data-dir="C:\\Users\\a b\\Claude-Work" --flag'),
        r'C:\Users\a b\Claude-Work',
      );
      expect(
        windowsUserDataDir('$exe --user-data-dir=C:\\Users\\ab\\Claude-Work --flag'),
        r'C:\Users\ab\Claude-Work',
      );
      expect(windowsUserDataDir(exe), isNull);
    });

    test('вспомогательные процессы Electron', () {
      expect(isWindowsChildProcess('$exe --type=renderer --user-data-dir=C:\\x'), isTrue);
      expect(isWindowsChildProcess(exe), isFalse);
    });
  });
}
