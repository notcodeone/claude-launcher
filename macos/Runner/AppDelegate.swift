import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Лаунчер живёт в строке меню: окно настроек обычно скрыто, и закрытие меню
  // иначе считалось бы закрытием последнего окна — приложение завершалось.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
