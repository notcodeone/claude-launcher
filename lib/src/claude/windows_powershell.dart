import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Сценарий PowerShell из файла — для того, что делается через PowerShell
/// (установка пакета Claude, правило брандмауэра). Итог сценарий пишет в
/// файл: у процесса с правами администратора вывод не прочитать.
///
/// Запуск — напрямую через Windows: обычный — `CreateProcess` без окна
/// (`CREATE_NO_WINDOW`), с правами администратора — `ShellExecuteEx` с
/// `runas`: Windows спросит разрешение и честно скажет, если отказали. Через
/// `Process.start` PowerShell без консоли завершался молча.
abstract final class WindowsPowerShell {
  /// Запускает [body] и ждёт его до [timeout]. В [body] итог — в переменной
  /// `$result`: «OK» или текст ошибки (исключение сценарий ловит сам).
  /// Возвращает `(ok, подробности)`; подробности дописывает и в [log].
  static Future<(bool, String)> run(
    String body, {
    required Directory work,
    required bool elevated,
    File? log,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    await work.create(recursive: true);
    final result = File(p.join(work.path, 'result.txt'));
    final script = File(p.join(work.path, 'script.ps1'));
    if (await result.exists()) await result.delete();
    await script.writeAsBytes(scriptBytes(wrap(body, result: result.path)));
    final (process, error) = elevated
        ? _shellExecuteElevated(_powerShell, scriptArguments(script.path))
        : _createProcess('"$_powerShell" ${scriptArguments(script.path)}');
    var waited = 'не запустился';
    if (process != null) {
      waited = await _waitFor(process, timeout)
          ? 'завершился'
          : 'не закончил за ${timeout.inMinutes} мин';
      CloseHandle(process);
    }
    final written = await result.exists()
        ? lastLine(await result.readAsString())
        : '';
    await log?.writeAsString(
      '--- ${elevated ? 'с правами администратора' : 'обычная'}\n'
      'PowerShell: $waited${error == 0 ? '' : ', ошибка Windows $error'}\n'
      'итог: $written\n',
      mode: FileMode.append,
    );
    if (written == 'OK') return (true, 'OK');
    if (written.isNotEmpty) {
      return (false, written.replaceFirst(RegExp(r'^ERROR:\s*'), ''));
    }
    return (
      false,
      switch (error) {
        _errorCancelled => 'разрешение администратора не получено',
        0 when process != null => 'сценарий завершился без ответа',
        0 => 'PowerShell не запустился',
        _ => 'PowerShell не запустился (ошибка Windows $error)',
      },
    );
  }

  /// Сценарий целиком: без прогресса (без консоли он ломается), ошибки —
  /// исключениями, итог — «OK» или «ERROR: …» в файле [result].
  @visibleForTesting
  static String wrap(String body, {required String result}) => [
    r"$ProgressPreference = 'SilentlyContinue'",
    r"$ErrorActionPreference = 'Stop'",
    'try {',
    for (final line in body.trim().split('\n')) '  ${line.trimRight()}',
    "  'OK' | Out-File -Encoding utf8 ${quote(result)}",
    '} catch {',
    r"  ('ERROR: ' + $_.Exception.Message) | Out-File -Encoding utf8 "
        '${quote(result)}',
    '}',
    '',
  ].join('\r\n');

  /// Файл сценария — UTF-8 с меткой (BOM). Без неё Windows PowerShell 5.1
  /// читает `.ps1` в кодировке системы (cp1251): кириллица в пути к файлу итога
  /// (имя пользователя, временная папка) ломается, и итог пишется не туда —
  /// лаунчер видел «сценарий завершился без ответа».
  @visibleForTesting
  static List<int> scriptBytes(String text) => [
    0xEF,
    0xBB,
    0xBF,
    ...utf8.encode(text),
  ];

  /// Строка в одинарных кавычках PowerShell.
  static String quote(String value) => "'${value.replaceAll("'", "''")}'";

  /// Аргументы PowerShell: без профиля, без вопросов, в обход запрета
  /// сценариев. Путь — в кавычках: в пути к временной папке бывают пробелы.
  @visibleForTesting
  static String scriptArguments(String script) =>
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden '
      '-File "$script"';

  /// Последняя непустая строка, без метки порядка байтов UTF-8.
  @visibleForTesting
  static String lastLine(String text) => text
      .replaceAll('\uFEFF', '')
      .trim()
      .split('\n')
      .map((line) => line.trim())
      .lastWhere((line) => line.isNotEmpty, orElse: () => '');

  static String get _powerShell => p.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );

  static const _errorCancelled = 1223;

  /// `CreateProcess` без окна. Возвращает процесс или код ошибки Windows.
  static (HANDLE?, int) _createProcess(String commandLine) {
    final startup = calloc<STARTUPINFO>()..ref.cb = sizeOf<STARTUPINFO>();
    final info = calloc<PROCESS_INFORMATION>();
    final command = commandLine.toNativeUtf16();
    try {
      final created = CreateProcess(
        null,
        PWSTR(command),
        null,
        null,
        false,
        CREATE_NO_WINDOW,
        null,
        null,
        startup,
        info,
      );
      if (!created.value) return (null, created.error);
      CloseHandle(info.ref.hThread);
      return (info.ref.hProcess, 0);
    } finally {
      calloc.free(startup);
      calloc.free(info);
      calloc.free(command);
    }
  }

  /// `ShellExecuteEx` с `runas`: Windows спросит разрешение администратора.
  /// Возвращает процесс или код ошибки (1223 — пользователь отказал).
  static (HANDLE?, int) _shellExecuteElevated(String file, String arguments) {
    const seeMaskNoCloseProcess = 0x40;
    const seeMaskNoAsync = 0x100;
    final info = calloc<SHELLEXECUTEINFO>();
    final verb = 'runas'.toNativeUtf16();
    final path = file.toNativeUtf16();
    final parameters = arguments.toNativeUtf16();
    try {
      info.ref
        ..cbSize = sizeOf<SHELLEXECUTEINFO>()
        ..fMask = seeMaskNoCloseProcess | seeMaskNoAsync
        ..lpVerb = PWSTR(verb)
        ..lpFile = PWSTR(path)
        ..lpParameters = PWSTR(parameters)
        ..nShow = SW_HIDE;
      final executed = ShellExecuteEx(info);
      if (!executed.value) return (null, executed.error);
      final process = info.ref.hProcess;
      return (process.address == 0 ? null : process, 0);
    } finally {
      calloc.free(info);
      calloc.free(verb);
      calloc.free(path);
      calloc.free(parameters);
    }
  }

  /// Ждёт завершения [process], не останавливая окно: спрашивает раз в
  /// полсекунды. false — не дождались за [timeout].
  static Future<bool> _waitFor(HANDLE process, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (WaitForSingleObject(process, 0).value == WAIT_OBJECT_0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }
}
