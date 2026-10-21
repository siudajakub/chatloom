// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart (no Flutter) so capability tests can use it on the worker config.
import 'dart:io';

import 'package:matrix/matrix.dart';

import '../media/immediate_media_outbox.dart';
import '../media/pending_media_store.dart';
import '../storage/storage_failure.dart';
import 'round_media_preparer.dart';
import 'telegram_room_binding.dart';

enum RoundAvailabilityKind { available, needsTrust, unavailable }

/// What the composer may offer for round video in one room. Never authorizes
/// a send: `TelegramRoundService.captureAndSend` repeats every check.
class RoundAvailability {
  final RoundGateCode code;
  const RoundAvailability._(this.code);
  factory RoundAvailability.fromReport(RoundGateReport report) =>
      RoundAvailability._(report.code);

  static const available = RoundAvailability._(RoundGateCode.available);

  RoundAvailabilityKind get kind => switch (code) {
    RoundGateCode.available ||
    // The upload limit is re-measured right before capture.
    RoundGateCode.uploadLimitUnknown => RoundAvailabilityKind.available,
    RoundGateCode.needsTrust => RoundAvailabilityKind.needsTrust,
    _ => RoundAvailabilityKind.unavailable,
  };

  /// Whether a round button may replace or join the voice controls.
  bool get canRecord => kind != RoundAvailabilityKind.unavailable;

  /// Short user-facing reason; null while recording is possible.
  String? get reason =>
      kind == RoundAvailabilityKind.available ? null : roundGateTitle(code);

  /// Secondary hint (for tooltips or a second line), when there is one.
  String? get hint => roundGateHint(code);

  /// Reason and hint as one sentence pair, for snackbars and tooltips.
  String get message => roundGateMessage(code);

  static final _cache = Expando<(String, RoundAvailability)>(
    'roundAvailability',
  );

  /// Cheap per-build lookup: re-diagnoses only after a sync, a trust change or
  /// an encryption change for this room.
  static RoundAvailability of(Room room) {
    final client = room.client;
    final key = [
      client.userID,
      client.deviceID,
      client.prevBatch,
      TelegramRoomBinding.trustRevision,
      room.membership.name,
      room.encrypted,
      client.encryptionEnabled,
      client.fileEncryptionEnabled,
    ].join('|');
    final cached = _cache[room];
    if (cached != null && cached.$1 == key) return cached.$2;
    final value = RoundAvailability.fromReport(
      TelegramRoomBinding.diagnose(room),
    );
    _cache[room] = (key, value);
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is RoundAvailability && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => 'RoundAvailability(${code.name})';
}

String roundGateTitle(RoundGateCode code) => switch (code) {
  RoundGateCode.available => 'Round video is available.',
  RoundGateCode.needsTrust =>
    'Confirm your Telegram bridge before sending the first round video.',
  RoundGateCode.notJoined => 'Join this chat to send round videos.',
  RoundGateCode.noBridgeInfo =>
    "This chat isn't connected through a Telegram bridge.",
  RoundGateCode.notTelegram =>
    'Round videos are only available in Telegram chats.',
  RoundGateCode.missingLegacyBridgeInfo || RoundGateCode.missingRoomFeatures =>
    "The Telegram bridge hasn't published its features for this chat yet.",
  RoundGateCode.bridgeLacksRoundSupport =>
    "This Telegram bridge doesn't support round video messages yet.",
  RoundGateCode.extensionVersion =>
    'This Telegram bridge uses an unsupported round video version.',
  RoundGateCode.foreignOwner =>
    "This chat's Telegram bridge belongs to a different account.",
  RoundGateCode.roomMismatch =>
    "The bridge's round video support doesn't match this chat.",
  RoundGateCode.senderMismatch =>
    "The bridge's round video support couldn't be verified.",
  RoundGateCode.botNotJoined => "The Telegram bridge isn't in this chat.",
  RoundGateCode.receiverMismatch =>
    'This chat is bridged through a different Telegram login.',
  RoundGateCode.ambiguousBridges =>
    'Several bridges serve this chat, so round videos are turned off.',
  RoundGateCode.roundDenied => "Round videos aren't allowed in this chat.",
  RoundGateCode.roundNotDeclared =>
    "The bridge hasn't enabled round videos for this chat.",
  RoundGateCode.uploadLimitUnknown =>
    "Couldn't confirm the server's upload limit.",
  RoundGateCode.profileIncomplete =>
    "The bridge's round video format couldn't be confirmed.",
  RoundGateCode.notEncrypted =>
    'Round videos are only sent in encrypted chats.',
  RoundGateCode.fileEncryptionOff =>
    "File encryption is off on this device, so round videos can't be sent.",
  RoundGateCode.silentUnsupported =>
    "This bridge can't send round videos without a notification.",
};

String? roundGateHint(RoundGateCode code) => switch (code) {
  RoundGateCode.bridgeLacksRoundSupport =>
    'It needs the ChatLoom round bridge.',
  RoundGateCode.extensionVersion ||
  RoundGateCode.profileIncomplete => 'Update the ChatLoom round bridge.',
  RoundGateCode.missingLegacyBridgeInfo ||
  RoundGateCode.missingRoomFeatures => 'Try again after the chat syncs.',
  RoundGateCode.uploadLimitUnknown => 'Check your connection and try again.',
  RoundGateCode.needsTrust => 'You will be asked once per bridge.',
  _ => null,
};

String roundGateMessage(RoundGateCode code) {
  final hint = roundGateHint(code);
  final title = roundGateTitle(code);
  return hint == null ? title : '$title $hint';
}

const roundFailureFallback =
    'Round video failed before recording. Nothing was sent.';

/// User-facing text for an error thrown by `captureAndSend` before anything
/// was sent. Never includes error details, IDs or contents.
String roundFailureMessage(Object error) {
  if (error is ImmediateMediaRejected) {
    final code = error.code;
    if (code.startsWith('round:')) {
      final gate = RoundGateCode.tryParse(code.substring(6));
      return gate == null ? roundFailureFallback : roundGateMessage(gate);
    }
    return switch (code) {
      'trustedRoundBridgeRequired' => roundGateMessage(
        RoundGateCode.bridgeLacksRoundSupport,
      ),
      'saveExistingDraftFirst' =>
        'The previous round video in this chat was not sent. Retry or delete it first.',
      'pendingMediaQuota' =>
        'Not enough room for another round video. Retry or delete unsent round videos first.',
      'sessionClosed' || 'sessionUnavailable' =>
        "Your session isn't ready. Try again in a moment.",
      'roundCapabilityUnavailable' =>
        'The bridge no longer confirms round video support. Nothing was sent.',
      'frozenRelationUnavailable' =>
        "The message you're replying to is no longer available. Nothing was sent.",
      _ => roundFailureFallback,
    };
  }
  if (error is RoundCaptureException) {
    return switch (error.code) {
      'permission_denied' =>
        'Allow camera and microphone access to record round videos.',
      'unsupported_android' || 'unsupported_platform' =>
        'Round video recording requires Android 7 or later, or macOS.',
      'interrupted' || 'busy' || 'stale_camera' =>
        'The camera was interrupted. Nothing was sent. Try again.',
      _ => roundFailureFallback,
    };
  }
  if (error is PendingMediaFailure) {
    return switch (error.code) {
      'storeQuota' || 'fileQuota' =>
        'Not enough room for another round video. Retry or delete unsent round videos first.',
      _ => "Couldn't save the round video on this device. Nothing was sent.",
    };
  }
  if (error is StorageFailure) {
    return "Encrypted storage isn't available, so round videos can't be recorded. Nothing was sent.";
  }
  if (error is FileSystemException) {
    return "Couldn't write the recording to storage. Free up space and try again.";
  }
  return roundFailureFallback;
}
