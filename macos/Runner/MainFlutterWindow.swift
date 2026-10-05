import Cocoa
import FlutterMacOS
import Network
import Security
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
    watchNetwork()

    super.awakeFromNib()
  }

  // Окно стартует скрытым: лаунчер живёт в строке меню.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  /// Сеть сменилась (VPN, Wi-Fi, кабель) — сразу сообщаем Dart: Kill Switch
  /// не ждёт своего опроса. Событие приходит за миллисекунды.
  private let networkMonitor = NWPathMonitor()

  private func watchNetwork() {
    networkMonitor.pathUpdateHandler = { [weak self] _ in
      DispatchQueue.main.async {
        self?.nativeChannel?.invokeMethod("networkChanged", arguments: nil)
      }
    }
    networkMonitor.start(queue: DispatchQueue(label: "claude_launcher.network"))
  }

  /// Управление конкретным экземпляром Claude по pid: у нескольких экземпляров
  /// один bundle id, поэтому работаем через NSRunningApplication. И окно самого
  /// лаунчера — для AppWindow.keepInFrontDuring.
  private func registerNativeChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "claude_launcher/native", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      // Секунды с последнего клика или нажатия клавиши (движение мыши не в счёт):
      // так лаунчер отличает переключение пользователя от того, что приложение
      // вышло вперёд само.
      case "secondsSinceInput":
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        result(types.map {
          CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min())
        return
      // Обработчик ссылок `claude://` в системе: чей он сейчас, сменить, наш id.
      case "linkHandler":
        result(LSCopyDefaultHandlerForURLScheme("claude" as CFString)?.takeRetainedValue() as String?)
        return
      case "setLinkHandler":
        guard let bundleId = call.arguments as? String else {
          result(false)
          return
        }
        result(LSSetDefaultHandlerForURLScheme("claude" as CFString, bundleId as CFString) == noErr)
        return
      // Ключ safeStorage Claude — чтобы лаунчер прочитал вход профиля и
      // запросил лимиты тем же запросом, что и Claude. В первый раз macOS
      // спросит пароль; отказ — nil, Dart больше не спрашивает до перезапуска.
      // Не в главном потоке: окно доступа держит вызов, пока пользователь думает.
      case "safeStorageKey":
        DispatchQueue.global(qos: .userInitiated).async {
          let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
          ]
          var item: CFTypeRef?
          let status = SecItemCopyMatching(query as CFDictionary, &item)
          let password = status == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
          DispatchQueue.main.async { result(password) }
        }
        return
      case "ownBundleId":
        result(Bundle.main.bundleIdentifier)
        return
      case "takeLinks":
        let delegate = NSApp.delegate as? AppDelegate
        result(delegate?.pendingLinks ?? [])
        delegate?.pendingLinks = []
        return
      // Окно лаунчера — вперёд. Из фона система может не дать приложению стать
      // активным, а обычный orderFront тогда кладёт окно под активное приложение.
      case "bringToFront":
        self?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self?.makeKeyAndOrderFront(nil)
        result(nil)
        return
      default:
        break
      }
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
      case "reopen":
        do {
          try ClaudeLinkDispatcher.reopen(app.processIdentifier)
          result(true)
        } catch {
          result(false)
        }
      case "openLink":
        guard let link = args["link"] as? String,
              app.bundleIdentifier == "com.anthropic.claudefordesktop" else {
          result(FlutterError(code: "invalid_target", message: "Процесс Claude уже закрыт или изменился.", details: nil))
          return
        }
        do {
          try ClaudeLinkDispatcher.send(link, to: app.processIdentifier)
          app.unhide()
          _ = app.activate(options: [.activateAllWindows])
          result(true)
        } catch {
          // Do not include the URL: it may contain an authorization callback.
          let code = (error as NSError).code
          let message = code == Int(errAEEventNotPermitted)
            ? "macOS не разрешила лаунчеру управлять Claude. Разрешите это в Системных настройках → Конфиденциальность и безопасность → Автоматизация."
            : "macOS не передала ссылку выбранному процессу Claude (код \(code))."
          result(FlutterError(code: "link_delivery_failed", message: message, details: nil))
        }
      case "isFrontmost":
        result(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }
}
