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

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
