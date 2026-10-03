import 'package:claude_launcher/src/http_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Uri.parse('https://api.github.com/');

  test('затвор Kill Switch из окружения — мимо', () {
    expect(
      launcherProxy(
        url,
        environment: {'https_proxy': 'http://127.0.0.1:47821'},
      ),
      'DIRECT',
    );
    expect(
      launcherProxy(url, environment: {'HTTPS_PROXY': 'localhost:3128'}),
      'DIRECT',
    );
  });

  test('настоящий прокси пользователя остаётся', () {
    expect(
      launcherProxy(url, environment: {'https_proxy': 'proxy.corp:3128'}),
      'PROXY proxy.corp:3128',
    );
    expect(launcherProxy(url, environment: const {}), 'DIRECT');
  });
}
