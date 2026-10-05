import 'dart:convert';

import 'package:claude_launcher/src/claude/windows_claude_host.dart';
import 'package:claude_launcher/src/claude/windows_powershell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const package =
      r"C:\Users\Анна О'Нил\AppData\Local\Temp\ClaudeLauncher\claude-update\Claude.msix";
  const result =
      r"C:\Users\Анна О'Нил\AppData\Local\Temp\ClaudeLauncher\claude-install\result.txt";

  test('сценарий: без прогресса, итог в файл, кавычки экранированы', () {
    final script = WindowsPowerShell.wrap(
      WindowsClaudeHost.installScript(package),
      result: result,
    );
    expect(script, contains(r"$ProgressPreference = 'SilentlyContinue'"));
    expect(script, contains('-ForceApplicationShutdown'));
    // Одинарная кавычка в пути удваивается — строка PowerShell не рвётся.
    expect(script, contains("Анна О''Нил"));
    expect(script, contains("'OK' | Out-File"));
    expect(script, contains(r"('ERROR: ' + $_.Exception.Message)"));
  });

  test('аргументы сценария: в обход запрета, путь в кавычках целиком', () {
    final arguments = WindowsPowerShell.scriptArguments(
      r'C:\Users\Анна Нил\Temp\script.ps1',
    );
    expect(arguments, contains('-ExecutionPolicy Bypass'));
    expect(arguments, contains('-NonInteractive'));
    expect(arguments, endsWith(r'-File "C:\Users\Анна Нил\Temp\script.ps1"'));
  });

  test('файл сценария — UTF-8 с BOM: кириллица в пути не ломается', () {
    final bytes = WindowsPowerShell.scriptBytes(
      WindowsPowerShell.wrap(
        'Get-Date',
        result: r'C:\Users\Дмитрий\result.txt',
      ),
    );
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes.skip(3).toList()), contains(r'C:\Users\Дмитрий'));
  });

  test('итог — последняя строка, без BOM', () {
    expect(WindowsPowerShell.lastLine('\uFEFFOK\r\n'), 'OK');
    expect(
      WindowsPowerShell.lastLine(
        '\uFEFFERROR: Deployment failed 0x80073CF9\r\n\r\n',
      ),
      'ERROR: Deployment failed 0x80073CF9',
    );
    expect(WindowsPowerShell.lastLine(''), '');
  });

  test('сетевой %APPDATA% — по тому же признаку, что у Claude', () {
    expect(
      WindowsClaudeHost.isUnc(r'\\server\profiles\anna\AppData\Roaming'),
      isTrue,
    );
    expect(WindowsClaudeHost.isUnc(r'C:\Users\anna\AppData\Roaming'), isFalse);
  });
}
