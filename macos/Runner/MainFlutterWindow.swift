import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?
  private var wakeObserver: NSObjectProtocol?
  private var occlusionObserver: NSObjectProtocol?
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
    if !setFrameUsingName("ChatLoomMainWindow") {
      let available = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
      setContentSize(NSSize(width: min(1120, available.width - 80),
                            height: min(780, available.height - 80)))
      center()
    }
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
    // Decorative animation stops while the window is not on screen
    // (covered, minimised or closed); see NotionActivity.
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.desktopChannel?.invokeMethod(
        "visibility", arguments: self.occlusionState.contains(.visible) && !self.isMiniaturized)
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
    if let observer = occlusionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
