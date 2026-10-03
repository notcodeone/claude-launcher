import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:claude_launcher/src/claude/command_line.dart';
import 'package:claude_launcher/src/claude/windows_link_probe_transport.dart';
import 'package:claude_launcher/src/claude/windows_package.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

final class ProbeCopyData extends Struct {
  @UintPtr()
  external int tag;
  @Uint32()
  external int length;
  external Pointer<Void> data;
}

class NativeLinkProbeApi extends WindowsLinkProbeApi {
  @override
  Future<LinkProbeProcess?> inspect(int pid) async {
    // Only the numeric PID is interpolated. No URLs, user paths or auth data.
    final script =
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); Get-CimInstance Win32_Process -Filter 'ProcessId = $pid' | "
        'Select-Object ProcessId,ExecutablePath,CommandLine,'
        "@{Name='Started';Expression={\$_.CreationDate.ToUniversalTime().Ticks.ToString()}} | ConvertTo-Json -Compress";
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    int result;
    try {
      result = await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill();
      throw StateError('Process inspection timed out');
    }
    await errors;
    if (result != 0) return null;
    final text = (await output).trim();
    if (text.isEmpty) return null;
    final json = jsonDecode(text) as Map<String, dynamic>;
    final exe = json['ExecutablePath'] as String?;
    final cmd = json['CommandLine'] as String?;
    final started = json['Started'] as String?;
    if (json['ProcessId'] != pid ||
        exe == null ||
        cmd == null ||
        started == null ||
        !isClaudeDesktopExe(exe) ||
        !exe.toLowerCase().endsWith(r'\claude.exe') ||
        isWindowsChildProcess(cmd)) {
      return null;
    }
    // Default MSIX profile path is virtualized: do not infer it from APPDATA.
    final dir = windowsUserDataDir(cmd);
    return dir == null ? null : LinkProbeProcess(pid, exe, dir, started);
  }

  @override
  List<int> receivers(String dataDir) => using((arena) {
    final name = arena.pcwstr('Chrome_MessageWindow');
    final title = arena.pcwstr(dataDir);
    final result = <int>[];
    HWND? after;
    for (var i = 0; i < 16; i++) {
      final next = FindWindowEx(HWND_MESSAGE, after, name, title).value;
      if (next.address == 0) return result;
      if (result.contains(next.address)) {
        throw StateError('Receiver scan repeated');
      }
      result.add(next.address);
      after = next;
    }
    throw StateError('Too many receivers');
  });

  @override
  bool ownsReceiver(int handle, int pid, String dataDir) => using((arena) {
    final window = HWND(Pointer.fromAddress(handle));
    final owner = arena<Uint32>();
    GetWindowThreadProcessId(window, owner);
    if (owner.value != pid) return false;
    final name = arena<Uint16>(256).cast<Utf16>();
    final length = GetClassName(window, PWSTR(name), 256).value;
    if (length <= 0 ||
        name.toDartString(length: length) != 'Chrome_MessageWindow') {
      return false;
    }
    final title = arena<Uint16>(32769).cast<Utf16>();
    final count = GetWindowText(window, PWSTR(title), 32769).value;
    return count > 0 &&
        sameWindowsPath(title.toDartString(length: count), dataDir);
  });

  @override
  bool send(int handle, Uint16List payload, Duration timeout) => using((arena) {
    final data = arena<Uint16>(payload.length);
    data.asTypedList(payload.length).setAll(0, payload);
    final cds = arena<ProbeCopyData>();
    cds.ref
      ..tag = 0
      ..length = payload.lengthInBytes
      ..data = data.cast();
    final response = arena<IntPtr>();
    final sent = SendMessageTimeout(
      HWND(Pointer.fromAddress(handle)),
      0x004A, // WM_COPYDATA
      const WPARAM(0),
      LPARAM(cds.address),
      SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT,
      timeout.inMilliseconds,
      response,
    );
    return sent.value != 0 && response.value != 0;
  });
}

/// Probe only; NOT connected to WindowsClaudeHost or the application UI.
Future<void> main(List<String> args) async {
  final pid = args.isNotEmpty ? int.tryParse(args.first) : null;
  if (!Platform.isWindows || args.length != 3 || pid == null || pid <= 0) {
    stderr.writeln(
      'Windows only: dart run tool/windows_link_probe.dart <test PID> <data dir> <claude Code URL>',
    );
    exitCode = 2;
    return;
  }
  try {
    await WindowsLinkProbeTransport(
      NativeLinkProbeApi(),
    ).deliver(pid, args[1], Uri.parse(args[2]));
    stdout.writeln(
      'Receiver acknowledged. Verify the session in the selected profile visually; this is not proof of navigation.',
    );
  } catch (_) {
    // Do not print input, URL, process command line, or errors containing paths.
    stderr.writeln('Probe failed; no fallback, relaunch or retry performed.');
    exitCode = 1;
  }
}
