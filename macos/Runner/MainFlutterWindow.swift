import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  /// Канал к Dart: команды экземплярам Claude туда, `reopen` — обратно.
  private(set) var nativeChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Аргументы запуска — в main() на стороне Dart: с флагом запускается
    // наблюдатель, который возвращает Claude уведомления.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nativeChannel = registerNativeChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Окно стартует скрытым: лаунчер живёт в строке меню.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  /// Управление конкретным экземпляром Claude по pid: у нескольких экземпляров
  /// один bundle id, поэтому работаем через NSRunningApplication.
  private func registerNativeChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "claude_launcher/native", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any],
            let pid = args["pid"] as? Int,
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
      else {
        result(false)
        return
      }
      switch call.method {
      case "terminate":
        // То же, что Cmd+Q: приложение может показать своё подтверждение.
        result(app.terminate())
      case "activate":
        app.unhide()
        result(app.activate(options: [.activateAllWindows]))
      case "isFrontmost":
        result(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }
}
