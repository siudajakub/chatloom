// SPDX-License-Identifier: AGPL-3.0-or-later
// Compile with macos/Runner/SyntheticPaste.swift. No accounts or clipboard IO.
import Cocoa

func event(_ type: CGEventType, _ key: CGKeyCode, _ flags: UInt64) -> NSEvent {
  let value = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type != .keyUp)!
  value.type = type
  value.flags = CGEventFlags(rawValue: flags)
  return NSEvent(cgEvent: value)!
}

let command: UInt64 = 0x100000
for type in [CGEventType.keyDown, .keyUp] {
  let value = event(type, 9, command)
  let normalized = SyntheticPaste.normalize(value)
  precondition(normalized.modifierFlags.rawValue == UInt(command | 0x8))
  precondition(normalized.keyCode == value.keyCode && normalized.type == value.type)
  precondition(value.modifierFlags.rawValue == UInt(command)) // Does not mutate the event.
  precondition(SyntheticPaste.normalize(normalized) === normalized) // No duplicate conversion.
}
let commandKeys: [(CGKeyCode, UInt64)] = [(55, 0x8), (54, 0x10)]
for (key, side) in commandKeys {
  let value = SyntheticPaste.normalize(event(.flagsChanged, key, command))
  precondition(value.modifierFlags.rawValue == UInt(command | side))
}
for value in [
  event(.keyDown, 9, command | 0x8), // Physical left ⌘V.
  event(.keyDown, 9, command | 0x10), // Physical right ⌘V.
  event(.keyDown, 9, 0), // Bare V.
  event(.keyDown, 8, command), // Unrelated synthetic shortcut, ⌘C.
  event(.flagsChanged, 55, 0), // Command released: must not stick.
] {
  precondition(SyntheticPaste.normalize(value) === value)
}
let shifted = SyntheticPaste.normalize(event(.keyDown, 9, command | 0x20000))
precondition(shifted.modifierFlags.rawValue == UInt(command | 0x20000 | 0x8))

// Exercise the production window entry point that AppKit calls before
// sendEvent. This needs no global key posting or Accessibility permission.
class PasteReceiver: NSView {
  var received: NSEvent?
  override var acceptsFirstResponder: Bool { true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    received = event
    return true
  }
}
_ = NSApplication.shared
let window = SyntheticPasteWindow(
  contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
  styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let receiver = PasteReceiver(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
window.contentView = receiver
precondition(window.makeFirstResponder(receiver))
precondition(window.performKeyEquivalent(with: event(.keyDown, 9, command)))
precondition(receiver.received?.modifierFlags.rawValue == UInt(command | 0x8))
window.close()
print("Synthetic paste modifier regressions PASS")
