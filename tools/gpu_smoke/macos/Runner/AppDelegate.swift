import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// A test tool runs unattended (as the player's --background=on): no Dock
  /// icon, never activated (set before launch finishes, so it never takes
  /// focus or switches the user's Space). --show shows a normal window.
  static var show: Bool { CommandLine.arguments.contains("--show") }

  // The delegate is made from the main nib before launch finishes; the
  // policy is set here (FlutterAppDelegate's own
  // applicationWillFinishLaunching isn't visible to Swift to override).
  override init() {
    super.init()
    if !AppDelegate.show {
      NSApplication.shared.setActivationPolicy(.accessory)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
