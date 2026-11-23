import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    if !AppDelegate.show {
      background = true
      // Nearly, not fully, transparent (a 0-alpha window can count as not
      // visible and get its frames throttled), passing clicks through,
      // floating on every Space without switching any.
      self.isRestorable = false
      self.alphaValue = 0.01
      self.hasShadow = false
      self.ignoresMouseEvents = true
      self.level = .floating
      self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    super.awakeFromNib()
    if background {
      // Small, in a corner, after setup (the nib's frame would win).
      let place = { [weak self] in
        guard let self = self, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        self.setFrame(
          NSRect(x: v.maxX - 160 - 12, y: v.minY + 12, width: 160, height: 90),
          display: true)
      }
      place()
      DispatchQueue.main.async(execute: place)
    }
  }

  private var background = false
  override var canBecomeKey: Bool { background ? false : super.canBecomeKey }
  override var canBecomeMain: Bool { background ? false : super.canBecomeMain }
}
