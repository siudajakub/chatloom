// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'round_video/round_availability.dart';
import 'round_video/telegram_room_binding.dart';

export 'package:personal_core/bridge_capabilities.dart';

/// Separates bridge declarations from local Matrix encryption/power/ownership.
/// No hardcoded native Matrix defaults or network-name-based inferred support.
abstract final class RoomCapabilities {
  static BridgeRoomCapabilities declared(Room room, {String? stateKey}) {
    final states = room.states[bridgeFeaturesEventType];
    if (states == null || states.isEmpty) {
      return BridgeRoomCapabilities.fromState(null);
    }
    final bridgeKeys = <String>{};
    for (final type in [
      'm.bridge',
      'uk.half-shot.bridge',
      'com.beeper.bridge',
    ]) {
      bridgeKeys.addAll(room.states[type]?.keys ?? []);
    }
    // Multiple advertised sources need a caller-selected state key. Never
    // combine one bridge's permission with another bridge's MIME/limits.
    return BridgeRoomCapabilities.fromStateEvents(
      {for (final entry in states.entries) entry.key: entry.value.content},
      bridgeStateKeys: bridgeKeys,
      stateKey: stateKey,
    );
  }

  static CapabilityResult forFeature(
    BridgeFeature feature,
    Room room, {
    Event? event,
    String? stateKey,
    BridgeMediaRequest? media,
    int? editCount,
    String? reaction,
    int? reactionCount,
    String? disappearingType,
    int? disappearingTimerMs,
    int? pollOptions,
    int? longestPollOption,
  }) => evidenceForFeature(
    feature,
    room,
    event: event,
    stateKey: stateKey,
    media: media,
    editCount: editCount,
    reaction: reaction,
    reactionCount: reactionCount,
    disappearingType: disappearingType,
    disappearingTimerMs: disappearingTimerMs,
    pollOptions: pollOptions,
    longestPollOption: longestPollOption,
  ).result;

  static BridgeCapabilityEvidence evidenceForFeature(
    BridgeFeature feature,
    Room room, {
    Event? event,
    String? stateKey,
    BridgeMediaRequest? media,
    int? editCount,
    String? reaction,
    int? reactionCount,
    String? disappearingType,
    int? disappearingTimerMs,
    int? pollOptions,
    int? longestPollOption,
  }) {
    if (feature == BridgeFeature.roundVideo) {
      final binding = TelegramRoomBinding.of(room, stateKey: stateKey);
      if (binding == null) {
        final gate = TelegramRoomBinding.diagnose(room, stateKey: stateKey);
        return BridgeCapabilityEvidence(
          CapabilityResult(
            gate.terminal
                ? CapabilityStatus.unavailable
                : CapabilityStatus.unverified,
            gate.terminal || gate.code == RoundGateCode.needsTrust
                ? roundGateMessage(gate.code)
                : 'Your Telegram login and bridge capabilities have not been verified.',
          ),
          source: 'telegram.identity',
          reasonCode: 'round:${gate.code.name}',
        );
      }
      final round = binding.capabilities(room);
      if (!round.result.allowed || round.profile == null) {
        return BridgeCapabilityEvidence(
          round.result,
          source: 'telegram.round.v1',
        );
      }
      if (media != null) {
        final measured = BridgeRoomCapabilities.fromState(
          binding.features.content,
        ).evidence(feature, media: media);
        if (!measured.result.allowed) return measured;
      }
    }
    final declaration = declared(room, stateKey: stateKey).evidence(
      feature,
      media: media,
      messageAge: event == null
          ? null
          : DateTime.now().difference(event.originServerTs),
      editCount: editCount,
      reaction: reaction,
      reactionCount: reactionCount,
      disappearingType: disappearingType,
      disappearingTimerMs: disappearingTimerMs,
      pollOptions: pollOptions,
      longestPollOption: longestPollOption,
    );
    if (!declaration.result.allowed) return declaration;
    if (room.membership != Membership.join) {
      return _denied('You are not a member of this conversation.');
    }
    if (event != null &&
        (event.room.id != room.id ||
            event.redacted ||
            !event.eventId.startsWith(r'$'))) {
      return _denied('The source message is unavailable.');
    }
    if (feature == BridgeFeature.disappearing) {
      if (!room.canChangeStateEvent('com.beeper.disappearing_timer')) {
        return _denied(
          'You do not have permission to change this conversation.',
        );
      }
    } else if (feature == BridgeFeature.delete) {
      if (event != null && !event.canRedact) {
        return _denied('You do not have permission to delete this message.');
      }
    } else if (!room.canSendDefaultMessages) {
      return _denied(
        'Sending is blocked by Matrix permissions or encryption keys.',
      );
    }
    if (feature == BridgeFeature.reaction &&
        !room.canSendEvent(EventTypes.Reaction)) {
      return _denied('You do not have permission to send a Matrix reaction.');
    }
    if (feature == BridgeFeature.sticker &&
        !room.canSendEvent(EventTypes.Sticker)) {
      return _denied('You do not have permission to send a Matrix sticker.');
    }
    if (feature == BridgeFeature.edit &&
        event != null &&
        event.senderId != room.client.userID) {
      return _denied('You can only edit your own messages.');
    }
    return declaration;
  }

  static BridgeCapabilityEvidence _denied(String reason) =>
      BridgeCapabilityEvidence(
        CapabilityResult(CapabilityStatus.unavailable, reason),
        source: 'matrix.permission',
      );
}

/// Safe product reason from the capability adapter, never raw transport error.
class PersonalCapabilityUnavailable implements Exception {
  final String reason;
  const PersonalCapabilityUnavailable(this.reason);
  @override
  String toString() => 'PersonalCapabilityUnavailable';
}
