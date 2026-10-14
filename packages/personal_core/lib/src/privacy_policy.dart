// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

/// Per-device emission policy. This does not hide activity from other clients.
class PrivacyPolicy {
  final bool incognito;
  final bool typingEnabled;
  final bool presenceEnabled;

  const PrivacyPolicy({
    this.incognito = false,
    this.typingEnabled = true,
    this.presenceEnabled = true,
  });

  bool get allowAutomaticRead => !incognito;
  bool get allowPrivateFullyRead => !incognito;
  bool get allowTyping => !incognito && typingEnabled;
  bool get allowOnlinePresence => !incognito && presenceEnabled;

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
