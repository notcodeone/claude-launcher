import 'dart:io';

import 'package:claude_launcher/src/claude/windows_window_activation.dart';

/// Run only on Windows: `dart run tool/window_activation_probe.dart <test PID>`.
/// Uses exactly the production window selector and focus path; creates no process.
void main(List<String> args) {
  final pid = args.length == 1 ? int.tryParse(args.single) : null;
  if (!Platform.isWindows || pid == null || pid <= 0) {
    stderr.writeln(
      'Run on Windows with one disposable test Claude process PID.',
    );
    exitCode = 2;
    return;
  }
  try {
    WindowsWindowActivator(NativeWindowsWindowApi()).activate(pid);
    stdout.writeln(
      'PASS: selected process window activated; verify its profile visually.',
    );
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
