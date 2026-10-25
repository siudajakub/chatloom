// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';

import 'round_video/messenger_round_gate.dart';
import 'round_video/round_availability.dart';
import 'round_video/telegram_room_binding.dart';

export 'package:personal_core/bridge_capabilities.dart';

/// Separates bridge declarations from local Matrix encryption/power/ownership.
/// No hardcoded native Matrix defaults or network-name-based inferred support.
abstract final class RoomCapabilities {
  static const _bridgeStateTypes = [
    'm.bridge',
    'uk.half-shot.bridge',
    'com.beeper.bridge',
  ];

  /// Parsed declarations per room and state key. Every message row asks
  /// several times per build; the bridge features are re-parsed only when
  /// one of the state events they are derived from changes.
  static final _declaredCache = Expando<Map<String?, _DeclaredEntry>>();

  static BridgeRoomCapabilities declared(Room room, {String? stateKey}) {
    final states = room.states[bridgeFeaturesEventType];
    if (states == null || states.isEmpty) {
      return BridgeRoomCapabilities.fromState(null);
    }
    final sources = _declarationSources(room, states);
    final cache = _declaredCache[room] ??= {};
    final cached = cache[stateKey];
    if (cached != null && cached.matches(sources)) return cached.value;
    final value = _parseDeclared(room, states, stateKey);
    cache[stateKey] = _DeclaredEntry(sources, value);
    return value;
  }

  /// The state events a declaration is derived from, as they are now. The
  /// SDK replaces a state event object on every change; a redaction rewrites
  /// the event in place but always replaces its `unsigned` map.
  static List<Object?> _declarationSources(
    Room room,
    Map<String, StrippedStateEvent> features,
  ) {
    final sources = <Object?>[];
    void add(String type, Map<String, StrippedStateEvent>? events) {
      sources.add(type);
      if (events == null) return;
      for (final entry in events.entries) {
        final event = entry.value;
        sources
          ..add(entry.key)
          ..add(event)
          ..add(event is Event ? event.unsigned : null);
      }
    }

    add(bridgeFeaturesEventType, features);
    for (final type in _bridgeStateTypes) {
      add(type, room.states[type]);
    }
    return sources;
  }

  static BridgeRoomCapabilities _parseDeclared(
    Room room,
    Map<String, StrippedStateEvent> states,
    String? stateKey,
  ) {
    final bridgeKeys = <String>{};
    for (final type in _bridgeStateTypes) {
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
    String? disappearingType,
    int? disappearingTimerMs,
    int? pollOptions,
    int? longestPollOption,
  }) {
    final messenger = feature == BridgeFeature.roundVideo
        ? MessengerRoundGate.of(room, stateKey: stateKey)
        : null;
    if (messenger != null) {
      // Messenger has no round type: the round is an ordinary MP4 video,
      // checked against the stock bridge's `m.video` declaration below.
      final gate = MessengerRoundGate.diagnose(room, stateKey: stateKey);
      if (gate.terminal) {
        return BridgeCapabilityEvidence(
          CapabilityResult(
            CapabilityStatus.unavailable,
            roundGateMessage(gate.code),
          ),
          source: 'messenger.round',
          reasonCode: 'round:${gate.code.name}',
        );
      }
      feature = BridgeFeature.video;
      stateKey ??= messenger.identity.stateKey;
    } else if (feature == BridgeFeature.roundVideo) {
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
      return _denied('You can’t send messages in this chat.');
    }
    if (feature == BridgeFeature.reaction &&
        !room.canSendEvent(EventTypes.Reaction)) {
      return _denied('You can’t react in this chat.');
    }
    if (feature == BridgeFeature.sticker &&
        !room.canSendEvent(EventTypes.Sticker)) {
      return _denied('You can’t send stickers in this chat.');
    }
    if (feature == BridgeFeature.edit &&
        event != null &&
        event.senderId != room.client.userID) {
      return _denied('You can only edit your own messages.');
    }
    return declaration;
  }

  /// Whether the composer offers [feature] (an attach-menu entry) in
  /// [room]: everything the room's bridge does not refuse. A complete
  /// declaration refuses what it omits (BR-02); rooms without one (native
  /// Matrix) keep every entry.
  static bool composerOffers(Room room, BridgeFeature feature) =>
      declared(room).evidence(feature).result.status !=
      CapabilityStatus.unavailable;

  /// The longest text message [room]'s network takes, or null (no limit
  /// declared).
  static int? maxTextLength(Room room) => declared(room).maxTextLength;

  /// Whether a change of the room state [eventType] (name, topic, avatar)
  /// reaches [room]'s network, or the bridge does not say it doesn't. The
  /// Matrix power level is the caller's check.
  static bool stateAllowed(Room room, String eventType) =>
      declared(room).stateEvidence(eventType).result.status !=
      CapabilityStatus.unavailable;

  /// Whether the member action [action] (`invite`, `kick`, `ban`) reaches
  /// [room]'s network, or the bridge does not say it doesn't. The Matrix
  /// power level is the caller's check.
  static bool memberActionAllowed(Room room, String action) =>
      declared(room).memberActionEvidence(action).result.status !=
      CapabilityStatus.unavailable;

  static BridgeCapabilityEvidence _denied(String reason) =>
      BridgeCapabilityEvidence(
        CapabilityResult(CapabilityStatus.unavailable, reason),
        source: 'matrix.permission',
      );
}

class _DeclaredEntry {
  final List<Object?> sources;
  final BridgeRoomCapabilities value;
  const _DeclaredEntry(this.sources, this.value);

  bool matches(List<Object?> current) {
    if (current.length != sources.length) return false;
    for (var i = 0; i < current.length; i++) {
      final a = current[i], b = sources[i];
      if (!(identical(a, b) || (a is String && a == b))) return false;
    }
    return true;
  }
}

/// Safe product reason from the capability adapter, never raw transport error.
class PersonalCapabilityUnavailable implements Exception {
  final String reason;
  const PersonalCapabilityUnavailable(this.reason);
  @override
  String toString() => 'PersonalCapabilityUnavailable';
}
