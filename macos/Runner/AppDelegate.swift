import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Лаунчер живёт в строке меню: окно настроек обычно скрыто, и закрытие меню
  // иначе считалось бы закрытием последнего окна — приложение завершалось.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Лаунчер запустили ещё раз (Finder, Launchpad, «Объекты входа»): второй
  // экземпляр система не запускает, а сообщает первому — пусть покажет окно.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    (mainFlutterWindow as? MainFlutterWindow)?.nativeChannel?.invokeMethod("reopen", arguments: nil)
    return false
  }

  // Выход из Dock, ⌘Q или «quit app» — тем же путём, что из меню значка:
  // лаунчер возвращает Claude уведомления и завершается сам (exit). Если Dart
  // не ответил за 5 секунд — завершаемся как обычно.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let channel = (mainFlutterWindow as? MainFlutterWindow)?.nativeChannel else {
      return .terminateNow
    }
    channel.invokeMethod("quit", arguments: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Ссылки `claude://`, которые macOS отдала лаунчеру как обработчику. Копятся,
  /// пока Dart их не заберёт (`takeLinks`): при запуске ссылкой событие приходит
  /// раньше, чем Dart готов.
  var pendingLinks: [String] = []

  override func application(_ application: NSApplication, open urls: [URL]) {
    pendingLinks += urls.filter { $0.scheme == "claude" }.map(\.absoluteString)
    (mainFlutterWindow as? MainFlutterWindow)?.nativeChannel?.invokeMethod("linksArrived", arguments: nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
