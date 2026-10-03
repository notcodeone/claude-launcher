import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Experimental ProcessSingleton candidate, used only by the standalone probe.
/// The launcher must not enable it until real Windows/MSIX validation succeeds.
class LinkProbeProcess {
  const LinkProbeProcess(this.pid, this.exe, this.dataDir, this.started);
  final int pid;
  final String exe;
  final String dataDir;
  final String started;

  bool sameProcess(LinkProbeProcess other) =>
      pid == other.pid &&
      started.isNotEmpty &&
      started == other.started &&
      sameWindowsPath(exe, other.exe) &&
      sameWindowsPath(dataDir, other.dataDir);
}

bool sameWindowsPath(String a, String b) =>
    p.windows.normalize(a).toLowerCase() ==
    p.windows.normalize(b).toLowerCase();

abstract class WindowsLinkProbeApi {
  Future<LinkProbeProcess?> inspect(int pid);
  List<int> receivers(String dataDir);
  bool ownsReceiver(int handle, int pid, String dataDir);
  bool send(int handle, Uint16List payload, Duration timeout);
}

/// Quote one argv element according to Windows command-line escaping rules.
String quoteWindowsArgument(String value) {
  if (value.contains('\u0000')) throw ArgumentError('Invalid argument');
  final out = StringBuffer('"');
  var slashes = 0;
  for (final unit in value.codeUnits) {
    if (unit == 92) {
      slashes++;
      continue;
    }
    out.write('\\' * (unit == 34 ? slashes * 2 + 1 : slashes));
    out.writeCharCode(unit);
    slashes = 0;
  }
  out.write('\\' * (slashes * 2));
  out.write('"');
  return out.toString();
}

/// Empty additional_data: UTF-16 START, cwd, command line, each NUL terminated.
/// No auth callbacks or arbitrary command-line switches are accepted.
Uint16List codeLinkProbePayload(LinkProbeProcess process, Uri link) {
  if (link.scheme != 'claude' ||
      link.host != 'claude.ai' ||
      link.userInfo.isNotEmpty ||
      link.hasPort ||
      link.hasQuery ||
      link.hasFragment ||
      link.pathSegments.length != 2 ||
      link.pathSegments.first != 'epitaxy' ||
      !RegExp(r'^[a-zA-Z0-9_-]{1,256}$').hasMatch(link.pathSegments.last)) {
    throw ArgumentError('Only a Claude Code session link is supported');
  }
  if (!p.windows.isAbsolute(process.exe) ||
      !p.windows.isAbsolute(process.dataDir) ||
      process.exe.contains('\u0000') ||
      process.dataDir.contains('\u0000')) {
    throw ArgumentError('Absolute process and profile paths are required');
  }
  final cmd = [
    process.exe,
    '--user-data-dir=${process.dataDir}',
    '$link',
  ].map(quoteWindowsArgument).join(' ');
  final text = 'START\u0000${p.windows.dirname(process.exe)}\u0000$cmd\u0000';
  if (text.length > 32768) throw ArgumentError('Probe payload is too large');
  return Uint16List.fromList(text.codeUnits);
}

class WindowsLinkProbeTransport {
  const WindowsLinkProbeTransport(this.api);
  final WindowsLinkProbeApi api;

  Future<void> deliver(int pid, String dataDir, Uri link) async {
    if (pid <= 0) throw ArgumentError('Invalid process');
    final initial = await api.inspect(pid);
    if (initial == null ||
        initial.pid != pid ||
        initial.started.isEmpty ||
        !sameWindowsPath(initial.dataDir, dataDir)) {
      throw StateError('Selected Claude process cannot be verified');
    }
    final payload = codeLinkProbePayload(initial, link);
    final receivers = api.receivers(initial.dataDir);
    // Never choose the first of several windows, including foreign owners.
    if (receivers.length != 1) {
      throw StateError('Receiver is absent or ambiguous');
    }
    final handle = receivers.single;
    final current = await api.inspect(pid);
    if (current == null ||
        !initial.sameProcess(current) ||
        !api.ownsReceiver(handle, pid, initial.dataDir)) {
      throw StateError('Selected process or receiver changed');
    }
    if (!api.send(handle, payload, const Duration(seconds: 2))) {
      // A timeout may follow actual delivery. Do not retry or relaunch Claude.
      throw StateError('No confirmed response; do not retry automatically');
    }
  }
}
