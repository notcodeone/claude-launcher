/// Разбор командных строк процессов Claude. Чистые функции — покрыты тестами.
library;

const _userDataDirFlag = '--user-data-dir=';

/// Строка `ps -axww -o pid=,command=` → (pid, команда).
({int pid, String command})? parsePsLine(String line) {
  final match = RegExp(r'^\s*(\d+)\s+(.*)$').firstMatch(line);
  if (match == null) return null;
  return (pid: int.parse(match.group(1)!), command: match.group(2)!);
}

/// Главный процесс Claude на macOS (не Helper-процессы Electron и не Claude Code CLI).
bool isMacClaudeMainProcess(String command) =>
    RegExp(r'^\S*/Claude\.app/Contents/MacOS/Claude(\s|$)').hasMatch(command);

/// Папка данных из команды macOS. `ps` склеивает аргументы пробелами без кавычек,
/// поэтому значение тянется до следующего флага ` --` или до конца строки.
String? macUserDataDir(String command) {
  final start = command.indexOf(_userDataDirFlag);
  if (start < 0) return null;
  final rest = command.substring(start + _userDataDirFlag.length);
  final end = rest.indexOf(' --');
  final value = (end < 0 ? rest : rest.substring(0, end)).trim();
  return value.isEmpty ? null : value;
}

/// Вспомогательные процессы Electron (renderer, gpu и т.п.) запускаются с `--type=`.
bool isWindowsChildProcess(String commandLine) => commandLine.contains('--type=');

/// Папка данных из командной строки Windows. Встречаются три формы:
/// `"--user-data-dir=C:\a b"`, `--user-data-dir="C:\a b"` и `--user-data-dir=C:\ab`.
String? windowsUserDataDir(String commandLine) {
  final start = commandLine.indexOf(_userDataDirFlag);
  if (start < 0) return null;
  var rest = commandLine.substring(start + _userDataDirFlag.length);

  String? upToQuote(String s) {
    final end = s.indexOf('"');
    final value = end < 0 ? s : s.substring(0, end);
    return value.isEmpty ? null : value;
  }

  if (start > 0 && commandLine[start - 1] == '"') return upToQuote(rest);
  if (rest.startsWith('"')) return upToQuote(rest.substring(1));
  rest = rest.split(RegExp(r'\s')).first;
  return rest.isEmpty ? null : rest;
}
