import Cocoa
import Carbon

/// Sends an open-URL event to exactly one running process. Never falls back
/// to LaunchServices, which would choose an arbitrary instance of the bundle.
enum ClaudeLinkDispatcher {
  static func send(_ link: String, to pid: pid_t) throws {
    guard let url = URL(string: link), url.scheme == "claude", pid > 0 else {
      throw NSError(domain: "ClaudeLinkDispatcher", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Некорректная ссылка Claude или процесс."])
    }
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kInternetEventClass),
      eventID: AEEventID(kAEGetURL),
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: link), forKeyword: keyDirectObject)
    _ = try event.sendEvent(options: [.noReply, .neverInteract], timeout: 5)
  }
}
