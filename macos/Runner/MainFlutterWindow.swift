import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?
  private var wakeObserver: NSObjectProtocol?
  private var roundCapture: RoundCapture?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    roundCapture = RoundCapture(registrar: flutterViewController.registrar(forPlugin: "PersonalRoundCapture"))

    title = "ChatLoom"
    minSize = NSSize(width: 720, height: 520)
    setFrameAutosaveName("ChatLoomMainWindow")
    isReleasedWhenClosed = false

    let channel = FlutterMethodChannel(
      name: "pl.personal.chat/desktop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopChannel = channel
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.desktopChannel?.invokeMethod("wake", arguments: nil)
    }
    configureMenu(NSApp.mainMenu)

    super.awakeFromNib()
  }

  private func configureMenu(_ menu: NSMenu?) {
    for item in menu?.items ?? [] {
      if item.title == "Preferences…" {
        item.title = "Settings…"
        item.target = self
        item.action = #selector(openSettings)
      }
      if item.keyEquivalent == "f" && item.keyEquivalentModifierMask == .command {
        item.target = self
        item.action = #selector(openSearch)
      }
      configureMenu(item.submenu)
    }
  }

  @objc private func openSettings(_ sender: Any?) {
    makeKeyAndOrderFront(nil)
    desktopChannel?.invokeMethod("settings", arguments: nil)
  }

  @objc private func openSearch(_ sender: Any?) {
    makeKeyAndOrderFront(nil)
    desktopChannel?.invokeMethod("search", arguments: nil)
  }

  deinit {
    if let observer = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
}
