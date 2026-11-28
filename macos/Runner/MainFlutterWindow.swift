import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "GOTTA.BIKE: BLE Watts"

    // The UI is a phone-shaped column (centred and capped at 720 pt wide in
    // Dart), so open a portrait window and don't let it get narrower or
    // shorter than a small phone.
    self.contentMinSize = NSSize(width: 360, height: 600)
    self.setContentSize(NSSize(width: 520, height: 860))
    self.center()
    // Remember the user's size and position after the first launch.
    self.setFrameAutosaveName("MainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
