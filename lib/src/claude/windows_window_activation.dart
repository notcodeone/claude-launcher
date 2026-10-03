import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class ProfileWindow {
  const ProfileWindow({
    required this.handle,
    required this.pid,
    required this.visible,
    required this.mainWindow,
  });
  final int handle;
  final int pid;
  final bool visible;
  final bool mainWindow;
}

abstract class WindowsWindowApi {
  List<ProfileWindow> windowsOf(int pid);
  int ownerOf(int handle);
  bool minimized(int handle);
  void show(int handle, {required bool restore});
  bool foreground(int handle);
  int foregroundOwner();
}

/// Focus exactly one process. Never relaunch an executable or inject input to
/// bypass the OS foreground restrictions.
class WindowsWindowActivator {
  const WindowsWindowActivator(this.api);
  final WindowsWindowApi api;

  void activate(int pid) {
    final candidates = api
        .windowsOf(pid)
        .where((w) => w.pid == pid && w.mainWindow)
        .toList();
    final window =
        candidates.where((w) => w.visible).firstOrNull ??
        candidates.firstOrNull;
    if (window == null) {
      throw StateError(
        'Окно выбранного профиля Claude не найдено. Попробуйте снова или откройте его из значка Claude в трее.',
      );
    }
    void checkOwner() {
      if (api.ownerOf(window.handle) != pid) {
        throw StateError(
          'Окно выбранного профиля Claude уже закрыто или изменилось.',
        );
      }
    }

    checkOwner();
    final restore = api.minimized(window.handle);
    checkOwner();
    api.show(window.handle, restore: restore);
    checkOwner();
    if (!api.foreground(window.handle) && api.foregroundOwner() != pid) {
      throw StateError(
        'Окно профиля показано. Windows не разрешила передать ему фокус — выберите окно на панели задач.',
      );
    }
  }
}

/// Shared by the launcher and the Windows-only verification probe.
class NativeWindowsWindowApi extends WindowsWindowApi {
  @override
  List<ProfileWindow> windowsOf(int pid) {
    final result = <ProfileWindow>[];
    final owner = calloc<Uint32>();
    final name = calloc<Uint16>(256).cast<Utf16>();
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      Pointer handle,
      int _,
    ) {
      final window = HWND(handle);
      GetWindowThreadProcessId(window, owner);
      if (owner.value != pid) return TRUE;
      final length = GetClassName(window, PWSTR(name), 256).value;
      final main =
          length > 0 &&
          name.toDartString(length: length) == 'Chrome_WidgetWin_1' &&
          GetWindow(window, GW_OWNER).value.address == 0 &&
          GetWindowTextLength(window).value > 0;
      result.add(
        ProfileWindow(
          handle: handle.address,
          pid: pid,
          visible: IsWindowVisible(window),
          mainWindow: main,
        ),
      );
      return TRUE;
    }, exceptionalReturn: FALSE);
    try {
      if (!EnumWindows(callback.nativeFunction, const LPARAM(0)).value) {
        throw StateError('Windows не предоставила список окон Claude.');
      }
    } finally {
      callback.close();
      calloc.free(owner);
      calloc.free(name);
    }
    return result;
  }

  HWND _window(int handle) => HWND(Pointer.fromAddress(handle));

  @override
  int ownerOf(int handle) {
    final owner = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(_window(handle), owner);
      return owner.value;
    } finally {
      calloc.free(owner);
    }
  }

  @override
  bool minimized(int handle) => IsIconic(_window(handle));

  @override
  void show(int handle, {required bool restore}) {
    // Queue the change without waiting for another process's UI thread.
    if (!ShowWindowAsync(_window(handle), restore ? SW_RESTORE : SW_SHOW)) {
      throw StateError('Windows не разрешила показать окно профиля Claude.');
    }
  }

  @override
  bool foreground(int handle) => SetForegroundWindow(_window(handle));

  @override
  int foregroundOwner() => ownerOf(GetForegroundWindow().address);
}
