import Cocoa
import Carbon

final class Receiver: NSObject {
  let path: String
  init(_ path: String) { self.path = path }
  @objc func receive(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
    try! value.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
let args = CommandLine.arguments
if args[1] == "receive" {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  let receiver = Receiver(args[2])
  NSAppleEventManager.shared().setEventHandler(receiver,
    andSelector: #selector(Receiver.receive(_:reply:)),
    forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  try! "ready".write(toFile: args[2] + ".ready", atomically: true, encoding: .utf8)
  withExtendedLifetime(receiver) { app.run() }
} else {
  do {
    try ClaudeLinkDispatcher.send(args[3], to: pid_t(args[2])!)
  } catch {
    fputs("Apple Event failed: \((error as NSError).code)\n", stderr)
    exit(1)
  }
}
