// SPDX-License-Identifier: AGPL-3.0-or-later

/// A composer host that can schedule the typed message and set a reminder
/// for the conversation. The send button's long press offers both
/// (Telegram's `onSendLongClick`); the same flows stay in the header menu.
abstract interface class ComposerSendLaterHost {
  /// Opens Send later for the typed message (or an attachment).
  Future<void> composerSendLater();

  /// Opens Remind me for this conversation.
  Future<void> composerRemindMe();
}
