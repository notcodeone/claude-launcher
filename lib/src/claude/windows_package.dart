/// Разбор сведений о пакете MSIX (Microsoft Store). Чистые функции — покрыты тестами.
library;

/// Полное имя пакета: `Имя_Версия_Архитектура_Ресурс_Издатель`,
/// например `Claude_1.2.3.0_x64__pzs8sxrjxfjjc` (ресурс обычно пустой).
class WindowsPackageName {
  const WindowsPackageName({
    required this.name,
    required this.version,
    required this.publisherId,
  });

  static WindowsPackageName? parse(String fullName) {
    final parts = fullName.split('_');
    if (parts.length != 5 || parts[0].isEmpty || parts[4].isEmpty) return null;
    final version = [
      for (final part in parts[1].split('.')) int.tryParse(part),
    ];
    if (version.isEmpty || version.contains(null)) return null;
    return WindowsPackageName(
      name: parts[0],
      version: version.cast<int>(),
      publisherId: parts[4],
    );
  }

  final String name;
  final List<int> version;
  final String publisherId;

  /// Семейство пакета — не меняется между версиями: `Claude_pzs8sxrjxfjjc`.
  String get familyName => '${name}_$publisherId';
}

/// Id приложения из AppxManifest.xml — нужен для AUMID `семейство!Id`.
String? manifestApplicationId(String manifestXml) => RegExp(
  r'<Application\b[^>]*\bId="([^"]+)"',
).firstMatch(manifestXml)?.group(1);

/// Сравнение версий вида [1, 2, 3, 0].
int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// Главный исполняемый файл Claude Desktop: из пакета Магазина или старой
/// установки. Одноимённый `claude.exe` от Claude Code CLI сюда не попадает.
bool isClaudeDesktopExe(String path) {
  final lower = path.toLowerCase();
  return lower.contains(r'\windowsapps\claude_') ||
      lower.contains(r'\anthropicclaude\');
}
