import 'dart:io';

/// Прокси для запросов самого лаунчера — из окружения, как у обычного
/// `HttpClient`, но без прокси на этом же компьютере. Такой прокси — затвор
/// Kill Switch: Claude задаёт его своим процессам (`HTTPS_PROXY`), и лаунчер,
/// запущенный из них (например, из терминала Claude Code), унаследовал бы его.
/// Пока страна не проверена, затвор закрыт — через него лаунчер не проверил бы
/// страну и не скачал бы обновление.
String launcherProxy(Uri url, {Map<String, String>? environment}) {
  final proxy = HttpClient.findProxyFromEnvironment(
    url,
    environment: environment,
  );
  final loopback = RegExp(
    r'PROXY (127\.\d+\.\d+\.\d+|localhost|\[::1\]|::1):',
    caseSensitive: false,
  );
  return loopback.hasMatch(proxy) ? 'DIRECT' : proxy;
}
