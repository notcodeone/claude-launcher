import 'package:claude_launcher/src/claude/windows_package.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('полное имя пакета Магазина', () {
    final package = WindowsPackageName.parse(
      'Claude_1.2.3.0_x64__pzs8sxrjxfjjc',
    );
    expect(package?.name, 'Claude');
    expect(package?.version, [1, 2, 3, 0]);
    expect(package?.familyName, 'Claude_pzs8sxrjxfjjc');
    expect(
      WindowsPackageName.parse(
        'Microsoft.WindowsCalculator_11.2405.2.0_x64__8wekyb3d8bbwe',
      )?.name,
      'Microsoft.WindowsCalculator',
    );
  });

  test('не имя пакета', () {
    expect(WindowsPackageName.parse('Claude'), isNull);
    expect(WindowsPackageName.parse('Claude_x_x64__abc'), isNull);
    expect(WindowsPackageName.parse('Claude_1.0_x64__'), isNull);
  });

  test('Id приложения из манифеста', () {
    const manifest = '''
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Applications>
    <Application Id="Claude" Executable="app\\Claude.exe" EntryPoint="Windows.FullTrustApplication">
    </Application>
  </Applications>
</Package>''';
    expect(manifestApplicationId(manifest), 'Claude');
    expect(manifestApplicationId('<Package/>'), isNull);
  });

  test('сравнение версий', () {
    expect(compareVersions([1, 10, 0], [1, 9, 5]), greaterThan(0));
    expect(compareVersions([1, 2], [1, 2, 0]), lessThan(0));
    expect(compareVersions([2, 0, 0, 0], [2, 0, 0, 0]), 0);
  });

  test('исполняемый файл Claude Desktop, а не Claude Code CLI', () {
    expect(
      isClaudeDesktopExe(
        r'C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__pzs8sxrjxfjjc\app\Claude.exe',
      ),
      isTrue,
    );
    // В реестре значков трея путь бывает с GUID известной папки вместо Program Files.
    expect(
      isClaudeDesktopExe(
        r'{6D809377-6AF0-444B-8957-A3773F02200E}\WindowsApps\Claude_1.2.3.0_x64__pzs8sxrjxfjjc\app\Claude.exe',
      ),
      isTrue,
    );
    expect(
      isClaudeDesktopExe(
        r'C:\Users\me\AppData\Local\AnthropicClaude\app-0.9.0\claude.exe',
      ),
      isTrue,
    );
    expect(isClaudeDesktopExe(r'C:\Users\me\.local\bin\claude.exe'), isFalse);
  });
}
