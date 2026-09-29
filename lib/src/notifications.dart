import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Системные уведомления лаунчера.
abstract class Notifier {
  /// Нажали на уведомление; аргумент — его `payload`.
  void Function(String payload)? onTap;

  /// Разрешены ли уведомления лаунчеру. Если пользователь ещё не отвечал,
  /// спрашивает его (macOS).
  Future<bool> allowed();

  /// Показывает уведомление; с тем же [id] — заменяет прежнее.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String payload = '',
  });

  Future<void> cancel(int id);

  /// Системные настройки уведомлений лаунчера.
  Future<void> openSettings();
}

class SystemNotifier extends Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _initialized;

  Future<void> _init() => _initialized ??= _plugin
      .initialize(
        settings: const InitializationSettings(
          // Разрешение спрашиваем сами — когда лаунчер берёт уведомления на себя.
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          windows: WindowsInitializationSettings(
            appName: 'ClaudeLauncher',
            appUserModelId: 'NotCode.ClaudeLauncher',
            guid: 'd0cc905a-995e-4349-aa39-dc9f260a3fe9',
          ),
        ),
        onDidReceiveNotificationResponse: (response) =>
            onTap?.call(response.payload ?? ''),
      )
      .then((_) {});

  MacOSFlutterLocalNotificationsPlugin? get _mac => _plugin
      .resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool> allowed() async {
    await _init();
    final mac = _mac;
    // На Windows разрешения у приложений не спрашивают.
    if (mac == null) return true;
    if ((await mac.checkPermissions())?.isEnabled ?? false) return true;
    // Если пользователь уже отказал, система не спросит снова — вернёт false.
    return await mac.requestPermissions(alert: true, sound: true) ?? false;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String payload = '',
  }) async {
    await _init();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: const NotificationDetails(
        // Лаунчер почти никогда не бывает активным приложением, но если
        // окно открыто — всё равно показываем баннер.
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
        windows: WindowsNotificationDetails(),
      ),
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _init();
    await _plugin.cancel(id: id);
  }

  @override
  Future<void> openSettings() async {
    if (Platform.isMacOS) {
      await Process.run('open', [
        'x-apple.systempreferences:com.apple.Notifications-Settings.extension'
            '?id=com.notcodeone.claudeLauncher',
      ]);
    } else {
      await Process.start('explorer.exe', [
        'ms-settings:notifications',
      ], mode: ProcessStartMode.detached);
    }
  }
}
