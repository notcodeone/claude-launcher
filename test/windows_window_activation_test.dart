import 'package:claude_launcher/src/claude/windows_window_activation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeWindows extends WindowsWindowApi {
  final windows = <ProfileWindow>[];
  final log = <String>[];
  final owners = <int, int>{};
  final minimizedWindows = <int>{};
  bool allowForeground = true;
  int frontOwner = 0;
  void Function()? beforeShow;
  @override
  List<ProfileWindow> windowsOf(int pid) => windows;
  @override
  int ownerOf(int handle) => owners[handle] ?? 0;
  @override
  bool minimized(int handle) {
    beforeShow?.call();
    return minimizedWindows.contains(handle);
  }

  @override
  void show(int handle, {required bool restore}) =>
      log.add('show $handle $restore');
  @override
  bool foreground(int handle) {
    log.add('focus $handle');
    return allowForeground;
  }

  @override
  int foregroundOwner() => frontOwner;

  void add(int handle, int pid, {bool visible = true, bool main = true}) {
    windows.add(
      ProfileWindow(
        handle: handle,
        pid: pid,
        visible: visible,
        mainWindow: main,
      ),
    );
    owners[handle] = pid;
  }
}

void main() {
  test(
    'only selected PID is shown, visible main window preferred over hidden',
    () {
      final api = FakeWindows()
        ..add(1, 10)
        ..add(2, 20, visible: false)
        ..add(3, 20);
      WindowsWindowActivator(api).activate(20);
      expect(api.log, ['show 3 false', 'focus 3']);
    },
  );
  test('minimized window is restored, hidden main window is shown', () {
    final api = FakeWindows()..add(1, 20, visible: false);
    WindowsWindowActivator(api).activate(20);
    expect(api.log, ['show 1 false', 'focus 1']);
    api.log.clear();
    api.minimizedWindows.add(1);
    WindowsWindowActivator(api).activate(20);
    expect(api.log, ['show 1 true', 'focus 1']);
  });
  test(
    'helper window or wrong PID cannot substitute for missing profile window',
    () {
      final api = FakeWindows()
        ..add(1, 20, main: false)
        ..add(2, 10);
      expect(() => WindowsWindowActivator(api).activate(20), throwsStateError);
      expect(api.log, isEmpty);
    },
  );
  test('window ownership is checked again immediately before showing', () {
    final api = FakeWindows()..add(1, 20);
    api.beforeShow = () => api.owners[1] = 10;
    expect(() => WindowsWindowActivator(api).activate(20), throwsStateError);
    expect(api.log, isEmpty);
  });
  test('focus refusal is reported without relaunch or input injection', () {
    final api = FakeWindows()
      ..add(1, 20)
      ..allowForeground = false;
    expect(
      () => WindowsWindowActivator(api).activate(20),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('не разрешила'),
        ),
      ),
    );
    expect(api.log, ['show 1 false', 'focus 1']);
  });
  test(
    'already active selected profile is accepted despite foreground return value',
    () {
      final api = FakeWindows()
        ..add(1, 20)
        ..allowForeground = false
        ..frontOwner = 20;
      WindowsWindowActivator(api).activate(20);
      expect(api.log, ['show 1 false', 'focus 1']);
    },
  );
}
