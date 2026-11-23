import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// --background runs unattended: no Dock icon and never activated, set
  /// before launch finishes so that it never takes focus or switches the
  /// Space of the user. The smoke test and the performance run use it.
  static var show: Bool { !CommandLine.arguments.contains("--background") }

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
