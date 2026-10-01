import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Windows: мгновенное событие о смене сети — для Kill Switch. Система сама
/// сообщает, когда на любом адаптере (Wi-Fi, кабель, VPN) появился или пропал
/// IP-адрес (`NotifyUnicastIpAddressChange`), — не нужно ждать опроса.
///
/// Функций нет в пакете win32 — подключаем из iphlpapi.dll сами. Колбэк
/// система вызывает из своего потока, поэтому он — [NativeCallable.listener]:
/// событие приходит в Dart асинхронно, данные строки не читаем (они живут
/// только во время вызова).
class WindowsNetworkWatch {
  NativeCallable<_ChangeCallback>? _callback;
  Pointer<Pointer<Void>>? _handle;

  /// Начинает следить; [onChange] — при каждой смене адресов.
  void start(void Function() onChange) {
    if (_handle != null) return;
    try {
      final callback = NativeCallable<_ChangeCallback>.listener(
        (Pointer<Void> context, Pointer<Void> row, int type) => onChange(),
      );
      final handle = calloc<Pointer<Void>>();
      final result = _notifyUnicastIpAddressChange(
        _afUnspec,
        callback.nativeFunction,
        nullptr,
        0, // Без первого «уведомления» обо всех адресах сразу.
        handle,
      );
      if (result != 0) {
        callback.close();
        calloc.free(handle);
        debugPrint('Kill Switch: события сети недоступны (код $result)');
        return;
      }
      _callback = callback;
      _handle = handle;
    } catch (error) {
      debugPrint('Kill Switch: события сети недоступны: $error');
    }
  }

  void stop() {
    final handle = _handle;
    if (handle != null) {
      _cancelMibChangeNotify2(handle.value);
      calloc.free(handle);
    }
    _callback?.close();
    _handle = null;
    _callback = null;
  }

  static const _afUnspec = 0;
}

typedef _ChangeCallback =
    Void Function(Pointer<Void> context, Pointer<Void> row, Int32 type);

final _iphlpapi = DynamicLibrary.open('iphlpapi.dll');

final _notifyUnicastIpAddressChange = _iphlpapi
    .lookupFunction<
      Uint32 Function(
        Uint16 family,
        Pointer<NativeFunction<_ChangeCallback>> callback,
        Pointer<Void> context,
        Uint8 initialNotification,
        Pointer<Pointer<Void>> handle,
      ),
      int Function(
        int family,
        Pointer<NativeFunction<_ChangeCallback>> callback,
        Pointer<Void> context,
        int initialNotification,
        Pointer<Pointer<Void>> handle,
      )
    >('NotifyUnicastIpAddressChange');

final _cancelMibChangeNotify2 = _iphlpapi
    .lookupFunction<
      Uint32 Function(Pointer<Void> handle),
      int Function(Pointer<Void> handle)
    >('CancelMibChangeNotify2');
