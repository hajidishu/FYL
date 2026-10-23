import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let environment = ProcessInfo.processInfo.environment
    if !(environment["FYL_APPLY_UPDATE"] ?? "").isEmpty ||
        !(environment["FYL_RECOVER_UPDATE"] ?? "").isEmpty {
      NSApp.setActivationPolicy(.accessory)
      NSApp.hide(nil)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
