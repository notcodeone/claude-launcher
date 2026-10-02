import 'package:claude_launcher/src/claude/windows_claude_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const package =
      r"C:\Users\Анна О'Нил\AppData\Local\Temp\ClaudeLauncher\claude-update\Claude.msix";
  const result =
      r"C:\Users\Анна О'Нил\AppData\Local\Temp\ClaudeLauncher\claude-install\result.txt";

  test('сценарий: без прогресса, итог в файл, кавычки экранированы', () {
    final script = WindowsClaudeHost.installScript(
      package: package,
      result: result,
    );
    expect(script, contains(r"$ProgressPreference = 'SilentlyContinue'"));
    expect(script, contains('-ForceApplicationShutdown'));
    // Одинарная кавычка в пути удваивается — строка PowerShell не рвётся.
    expect(script, contains("Анна О''Нил"));
    expect(script, contains("'OK' | Out-File"));
    expect(script, contains(r"('ERROR: ' + $_.Exception.Message)"));
  });

  test('с правами администратора — RunAs, путь в кавычках целиком', () {
    final command = WindowsClaudeHost.launchCommand(
      r'C:\Users\Анна Нил\Temp\install.ps1',
      elevated: true,
    );
    expect(command, contains('Start-Process powershell.exe -Verb RunAs -Wait'));
    expect(command, contains(r'-File "C:\Users\Анна Нил\Temp\install.ps1"'));
    expect(command, contains('-ExecutionPolicy Bypass'));
    expect(
      WindowsClaudeHost.launchCommand(r'C:\x\install.ps1', elevated: false),
      r"& 'C:\x\install.ps1'",
    );
  });

  test('итог — последняя строка, без BOM', () {
    expect(WindowsClaudeHost.lastLine('\uFEFFOK\r\n'), 'OK');
    expect(
      WindowsClaudeHost.lastLine(
        '\uFEFFERROR: Deployment failed 0x80073CF9\r\n\r\n',
      ),
      'ERROR: Deployment failed 0x80073CF9',
    );
    expect(WindowsClaudeHost.lastLine(''), '');
  });
}
