// SPDX-License-Identifier: AGPL-3.0-or-later
import Cocoa

enum SyntheticPaste {
  /// Some dictation/clipboard tools post ⌘V with only the generic Command
  /// flag. Flutter reads the left/right device bits, so it misses that ⌘.
  /// Preserve physical events and all unrelated shortcuts. This only fills
  /// in missing Command information; it never reads or writes the clipboard.
  static func normalize(_ event: NSEvent) -> NSEvent {
    let flags = event.modifierFlags
    let commandSides: UInt = 0x8 | 0x10
    guard flags.contains(.command), flags.rawValue & commandSides == 0 else {
      return event
    }
    let pasteKey = (event.type == .keyDown || event.type == .keyUp) && event.keyCode == 9
    let commandKey = event.type == .flagsChanged && (event.keyCode == 55 || event.keyCode == 54)
    guard pasteKey || commandKey, let copy = event.cgEvent?.copy() else { return event }
    let side: UInt64 = commandKey && event.keyCode == 54 ? 0x10 : 0x8
    copy.flags = CGEventFlags(rawValue: UInt64(flags.rawValue) | side)
    return NSEvent(cgEvent: copy) ?? event
  }
}
