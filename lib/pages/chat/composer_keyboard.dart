// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pasteboard/pasteboard.dart';

/// Enter commits an IME candidate before it can ever submit a message.
/// ⌘↩ ([metaPressed]) always sends (Telegram, Slack), also with "Send on
/// enter" off. With [onEditLast] (desktop, no reply or edit open), a bare ↑
/// in the empty composer edits the last own message, as in ordinary chats.
KeyEventResult conversationComposerKeyResult(
  KeyEvent event, {
  required TextEditingValue value,
  required bool sendOnEnter,
  required bool shiftPressed,
  required VoidCallback onSend,
  bool metaPressed = false,
  VoidCallback? onEditLast,
}) {
  if (onEditLast != null &&
      event is KeyDownEvent &&
      event.logicalKey == LogicalKeyboardKey.arrowUp &&
      value.text.isEmpty &&
      !shiftPressed &&
      !metaPressed &&
      !HardwareKeyboard.instance.isAltPressed &&
      !HardwareKeyboard.instance.isControlPressed) {
    onEditLast();
    return KeyEventResult.handled;
  }
  final enter =
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!enter ||
      !(sendOnEnter || metaPressed) ||
      shiftPressed ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) onSend();
  // A held key must not repeat a send or insert a newline on key-up.
  return KeyEventResult.handled;
}

/// Replaces the selection of [controller] (or appends) with [text], caret
/// after it; returns the new text.
String insertComposerText(TextEditingController controller, String text) {
  final value = controller.value;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  final next = value.text.replaceRange(selection.start, selection.end, text);
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: selection.start + text.length),
  );
  return next;
}

/// Type-to-focus (Telegram, WhatsApp, Messenger desktop): a character typed
/// while focus is elsewhere in the conversation (a clicked message, the
/// inbox) goes to the composer, which takes focus. False when the composer
/// cannot take it (not mounted, sending, no source).
bool typeIntoComposer(ConversationComposerHost host, String text) {
  final focus = host.inputFocus;
  if (!host.composerEnabled || focus.context == null) return false;
  final next = insertComposerText(host.sendController, text);
  focus.requestFocus();
  host.onInputBarChanged(next);
  return true;
}

/// Esc in the composer with nothing left to cancel (Mac, Telegram Desktop):
/// Back, which closes the chat. A text field turns Esc into a
/// [DismissIntent] (on the Mac through AppKit's `cancelOperation:` once the
/// input method has no candidates) and hands it to the nearest ancestor
/// action after its own toolbar and the mention list declined it; this is
/// that action. Enabled only while the composer itself has focus, so other
/// fields in the chat (search) keep Esc.
class ComposerBackAction extends Action<DismissIntent> {
  ComposerBackAction({
    required this.composer,
    required this.onBack,
    required this.enabled,
  });

  final FocusNode composer;
  final VoidCallback onBack;
  final bool enabled;

  @override
  bool isEnabled(DismissIntent intent) {
    if (!enabled || !composer.hasPrimaryFocus) return false;
    if (!PersonalPrivacy.surfaceUnlocked) return false;
    // An input method composing keeps Esc to cancel its candidate.
    final composing = composer.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.textEditingValue
        .composing;
    return composing == null || !composing.isValid || composing.isCollapsed;
  }

  @override
  Object? invoke(DismissIntent intent) {
    onBack();
    return null;
  }
}

/// Media that ⌘V attaches, or null to paste text: files first, then an
/// image. On the Mac a copy that is text first pastes its text: Numbers,
/// Excel and Word put a picture rendering beside the copied text.
Future<List<XFile>?> readClipboardMedia() async {
  if (PlatformInfos.isMacOS &&
      !await MacDesktopWindow.pasteboardPrefersMedia()) {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (text?.text?.isNotEmpty == true) return null;
  }
  final files = await Pasteboard.files();
  if (files.isNotEmpty) return files.map(XFile.new).toList();
  final image = await Pasteboard.image;
  if (image == null) return null;
  return [
    XFile.fromData(
      image,
      name: 'pasted-image.png',
      path: 'pasted-image.png',
      mimeType: 'image/png',
    ),
  ];
}
