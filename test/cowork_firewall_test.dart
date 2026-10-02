import 'package:claude_launcher/src/claude/windows_powershell.dart';
import 'package:claude_launcher/src/location/cowork_firewall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('правило — на службу Cowork по имени, только исходящие', () {
    const script = CoworkFirewall.enableScript;
    expect(script, contains("-Service 'CoworkVMService'"));
    expect(script, contains('-Direction Outbound -Action Block'));
    expect(script, contains("-Name 'ClaudeLauncher-Cowork'"));
    // Сначала убираем прежнее — повторное включение не плодит правила.
    expect(script.indexOf('Remove-NetFirewallRule'), 0);
  });

  test('проверка и снятие — по тому же имени', () {
    expect(CoworkFirewall.checkScript, contains("'ClaudeLauncher-Cowork'"));
    expect(CoworkFirewall.disableScript, contains("'ClaudeLauncher-Cowork'"));
  });

  test('многострочное тело сценария — внутри try', () {
    final script = WindowsPowerShell.wrap(
      CoworkFirewall.enableScript,
      result: r'C:\t\result.txt',
    );
    final tryAt = script.indexOf('try {');
    expect(script.indexOf('Remove-NetFirewallRule'), greaterThan(tryAt));
    expect(script.indexOf('New-NetFirewallRule'), greaterThan(tryAt));
    expect(
      script.indexOf('} catch {'),
      greaterThan(script.indexOf('Out-Null')),
    );
  });
}
