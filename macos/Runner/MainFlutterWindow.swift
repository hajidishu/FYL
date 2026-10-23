import Cocoa
import FlutterMacOS
import CoreGraphics

class MainFlutterWindow: NSWindow {
  private var gameWindowChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    gameWindowChannel = FlutterMethodChannel(name: "fyl/game_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    gameWindowChannel?.setMethodCallHandler { call, result in
      guard call.method == "isVisible" else { result(FlutterMethodNotImplemented); return }
      guard let arguments = call.arguments as? [String: Any],
            let pid = arguments["pid"] as? NSNumber, pid.intValue > 0 else {
        result(FlutterError(code: "invalid_pid", message: "Invalid game PID", details: nil)); return
      }
      guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        result(nil); return
      }
      let visible = windows.contains { window in
        guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
              owner.intValue == pid.intValue,
              let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber else { return false }
        return width.doubleValue >= 64 && height.doubleValue >= 64
      }
      result(visible)
    }

    super.awakeFromNib()
  }
}
