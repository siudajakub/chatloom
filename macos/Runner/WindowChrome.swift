import Cocoa
import FlutterMacOS

/// Telegram-style window chrome: the app draws under transparent traffic
/// lights. Flutter learns the title-bar height (0 in full screen) and raises
/// its top padding by it; it tells the window its theme, so the traffic
/// lights, menus and the resize background follow the app, not the system.
/// It also answers whether the pasteboard holds media ahead of text.
/// Channel: `pl.personal.chat/window` (see `lib/utils/macos_desktop.dart`).
final class WindowChrome {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var observers: [NSObjectProtocol] = []
  /// The windowed title-bar height; macOS draws 28 pt without a toolbar.
  private var windowedInset: CGFloat = 28
  private var fullScreen = false

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "pl.personal.chat/window", binaryMessenger: messenger)

    // One window: no automatic tabs ("Show Tab Bar", "Show All Tabs").
    NSWindow.allowsAutomaticWindowTabbing = false
    window.tabbingMode = .disallowed
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    // The app's default (Notion dark) until Flutter reports its theme: no
    // light flash at launch or while resizing.
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = WindowChrome.color(argb: 0xFF191919)
    fullScreen = window.styleMask.contains(.fullScreen)
    measure()

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }

    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.fullScreen = true
        self?.send()
      },
      center.addObserver(
        forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        // Lay out for the windowed title bar while the exit animates.
        self?.fullScreen = false
        self?.send()
      },
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.fullScreen = false
        self?.measure()
        self?.send()
      },
    ]
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private var inset: CGFloat { fullScreen ? 0 : windowedInset }

  /// The title bar's height over the content (full-size content view).
  private func measure() {
    guard let window = window, !window.styleMask.contains(.fullScreen) else { return }
    let height = window.frame.height - window.contentLayoutRect.height
    if height > 0 && height < 100 {
      windowedInset = height
    }
  }

  private func send() {
    channel.invokeMethod("titlebarInset", arguments: Double(inset))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "titlebarInset":
      result(Double(inset))
    case "appearance":
      guard let window = window,
        let arguments = call.arguments as? [String: Any],
        let dark = arguments["dark"] as? Bool
      else {
        result(FlutterError(code: "arguments", message: "Expected dark", details: nil))
        return
      }
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      if let argb = arguments["background"] as? Int {
        window.backgroundColor = WindowChrome.color(argb: argb)
      }
      result(nil)
    case "pasteboardPrefersMedia":
      result(WindowChrome.pasteboardPrefersMedia(NSPasteboard.general))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func color(argb: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: 1)
  }

  /// Files (copied in Finder), or an image type listed ahead of every text
  /// type. Apps list their richest type first: a screenshot or "Copy Image"
  /// starts with the image, while Numbers, Excel and Word put text and RTF
  /// ahead of the picture rendering they add, so those paste as text.
  private static func pasteboardPrefersMedia(_ board: NSPasteboard) -> Bool {
    if board.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    {
      return true
    }
    let types = board.types ?? []
    let images: Set<NSPasteboard.PasteboardType> = [
      .tiff, .png, .pdf,
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("public.heic"),
      NSPasteboard.PasteboardType("com.compuserve.gif"),
    ]
    let texts: Set<NSPasteboard.PasteboardType> = [.string, .rtf, .rtfd, .html]
    guard let image = types.firstIndex(where: { images.contains($0) }) else {
      return false
    }
    guard let text = types.firstIndex(where: { texts.contains($0) }) else {
      return true
    }
    return image < text
  }
}
