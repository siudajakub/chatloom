// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Enter commits an IME candidate before it can ever submit a message.
KeyEventResult conversationComposerKeyResult(
  KeyEvent event, {
  required TextEditingValue value,
  required bool sendOnEnter,
  required bool shiftPressed,
  required VoidCallback onSend,
}) {
  final enter =
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!enter ||
      !sendOnEnter ||
      shiftPressed ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) onSend();
  // A held key must not repeat a send or insert a newline on key-up.
  return KeyEventResult.handled;
}
