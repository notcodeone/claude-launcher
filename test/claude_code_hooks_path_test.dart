import 'package:claude_launcher/src/integrations/claude_code_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('настройки Claude Code — в CLAUDE_CONFIG_DIR, если задана', () {
    expect(
      ClaudeCodeHooks.settingsPath({
        'CLAUDE_CONFIG_DIR': '/work/claude',
        'HOME': '/Users/me',
        'USERPROFILE': r'C:\Users\me',
      }),
      p.join('/work/claude', 'settings.json'),
    );
  });

  test('без CLAUDE_CONFIG_DIR — ~/.claude/settings.json', () {
    final path = ClaudeCodeHooks.settingsPath({
      'CLAUDE_CONFIG_DIR': '  ',
      'HOME': '/Users/me',
      'USERPROFILE': r'C:\Users\me',
    });
    expect(path, endsWith(p.join('.claude', 'settings.json')));
  });
}
