import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChrome: WindowChrome?
  private var desktopChannel: FlutterMethodChannel?
  private var wakeObserver: NSObjectProtocol?
  private var occlusionObserver: NSObjectProtocol?
  private var roundCapture: RoundCapture?
  // battery-lifecycle (BP-08): Low Power Mode -> lite mode.
  private var powerChannel: FlutterMethodChannel?
  private var powerObserver: NSObjectProtocol?

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
    // Transparent title bar over the app, theme and pasteboard queries.
    windowChrome = WindowChrome(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

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
    configurePowerSaving(messenger: flutterViewController.engine.binaryMessenger)

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
      if item.keyEquivalent == "/" && item.keyEquivalentModifierMask == .command {
        item.target = self
        item.action = #selector(openShortcutsHelp)
      }
      configureMenu(item.submenu)
    }
  }

  // battery-lifecycle (BP-08): reports Low Power Mode to Dart
  // (lib/utils/power_saving.dart): `isPowerSaving` answers the current state,
  // `powerSaving` is sent on every change.
  private func configurePowerSaving(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "pl.personal.chat/power", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "isPowerSaving" {
        result(ProcessInfo.processInfo.isLowPowerModeEnabled)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    powerChannel = channel
    powerObserver = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      self?.powerChannel?.invokeMethod(
        "powerSaving", arguments: ProcessInfo.processInfo.isLowPowerModeEnabled)
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

  @objc private func openShortcutsHelp(_ sender: Any?) {
    makeKeyAndOrderFront(nil)
    desktopChannel?.invokeMethod("help", arguments: nil)
  }

  deinit {
    if let observer = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    if let observer = occlusionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = powerObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
