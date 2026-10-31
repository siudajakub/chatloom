// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

/// Per-device emission policy. This does not hide activity from other clients.
class PrivacyPolicy {
  final bool incognito;
  final bool typingEnabled;

  const PrivacyPolicy({this.incognito = false, this.typingEnabled = true});

  bool get allowAutomaticRead => !incognito;
  bool get allowPrivateFullyRead => !incognito;
  bool get allowTyping => !incognito && typingEnabled;

  /// Own Matrix presence is never broadcast, incognito or not: the account
  /// always appears offline (`set_presence=offline` on every sync, no
  /// presence other than `offline` is ever set). Reading other people's
  /// presence is a display choice and is not governed here.
  bool get allowOnlinePresence => false;

  /// Explicit exceptions must never be inferred from an attempted send.
  bool allowRead({bool manual = false, bool acceptedReply = false}) =>
      !incognito || manual || acceptedReply;

  /// A reply releases the read marker only for its original source room.
  bool mayMarkAfterReply({
    required SendTarget target,
    required ConversationRef readConversation,
    required bool accepted,
  }) => accepted && target.conversation == readConversation;

  @override
  String toString() => 'PrivacyPolicy(incognito: $incognito)';
}
