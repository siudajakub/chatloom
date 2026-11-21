// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// What a bridge's own notice in a chat means, in ChatLoom's words (BR-08).
/// mautrix bridges post these as `m.notice` messages from the contact or
/// the bot; drawn as bubbles they read like the contact wrote them.
@immutable
class BridgeServiceNotice {
  final String text;
  final IconData icon;
  final bool isCall;
  const BridgeServiceNotice(this.text, this.icon, {this.isCall = false});

  @override
  bool operator ==(Object other) =>
      other is BridgeServiceNotice &&
      other.runtimeType == runtimeType &&
      other.text == text &&
      other.icon == icon &&
      other.isCall == isCall;
  @override
  int get hashCode => Object.hash(text, icon, isCall);
  @override
  String toString() => 'BridgeServiceNotice(redacted)';
}

enum BridgeCallKind { unknown, voice, video }

enum BridgeCallOutcome {
  unknown,
  incoming,
  outgoing,
  started,
  missed,
  answered,
  rejected,
  failed,
  silenced,
  ended,
  disconnected,
  canceled,
}

enum BridgeCallDirection { incoming, outgoing }

class BridgeCallNotice extends BridgeServiceNotice {
  BridgeCallNotice(
    String text, {
    required this.network,
    required this.kind,
    required this.outcome,
    this.direction,
    this.duration,
  }) : super(text, _callIcon(kind, outcome), isCall: true);

  final String? network;
  final BridgeCallKind kind;
  final BridgeCallOutcome outcome;
  final BridgeCallDirection? direction;
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is BridgeCallNotice &&
      super == other &&
      other.network == network &&
      other.kind == kind &&
      other.outcome == outcome &&
      other.direction == direction &&
      other.duration == duration;

  @override
  int get hashCode =>
      Object.hash(super.hashCode, network, kind, outcome, direction, duration);
}

IconData _callIcon(BridgeCallKind kind, BridgeCallOutcome outcome) =>
    switch ((kind, outcome)) {
      (BridgeCallKind.video, _) => Icons.videocam_outlined,
      (_, BridgeCallOutcome.missed) => Icons.phone_missed_outlined,
      (_, BridgeCallOutcome.ended) => Icons.call_end_outlined,
      _ => Icons.call_outlined,
    };

final _timerSet = RegExp(r'^Set the disappearing message timer to (.+)$');
final _timerAuto = RegExp(
  r'^Automatically enabled disappearing message timer \((.+)\) because',
);
final _timerOff = RegExp(
  r'^(Automatically turned off|Turned off) disappearing messages',
);
final _oldMedia = RegExp(r'^Old ([a-zA-Z ]{1,30})\.');
final _failedMedia = RegExp(
  r'^Failed to bridge ([a-zA-Z ]{1,30}), please view it on the ([a-zA-Z]+) app',
);
final _remoteError = RegExp(
  r'^An error occurred while processing an incoming [a-z ]+$',
);
final _historyNotice = RegExp(
  r'^[^\r\n]+ sent message history(?: to [^\r\n]+)?(?: \(\d+ messages?\))?(?:, starting [^\r\n]+)?\.$',
);
final _lineBreak = RegExp(r'[\r\n]+');
const _actionKey = 'com.beeper.action_message';
const _callDetailsKey = 'com.chatloom.call';
const _whatsAppAnswerHint = '. Use the WhatsApp app to answer.';

/// A call entry already delivered to the room. Some bridge outcomes use
/// fixed notice text instead of a Beeper action.
BridgeCallNotice? bridgeCallNotice(Event event) {
  if (event.type != EventTypes.Message || event.stateKey != null) return null;
  final msgtype = event.messageType;
  if (msgtype != MessageTypes.Text && msgtype != MessageTypes.Notice) {
    return null;
  }
  final action = event.content[_actionKey];
  final tagged = action is Map && action['type'] == 'call';
  if (!tagged && (action != null || msgtype != MessageTypes.Notice)) {
    return null;
  }
  final raw = event.content['body'];
  if (raw is! String ||
      !event.status.isSent ||
      isDeletedForDisplay(event) ||
      !isBridgedRoom(event.room)) {
    return null;
  }
  final body = raw.trim();
  if (body.isEmpty) return null;
  final network = bridgedNetworkLabel(event.room);
  if (tagged) {
    final label = network == 'WhatsApp' && body.endsWith(_whatsAppAnswerHint)
        ? body.substring(0, body.length - _whatsAppAnswerHint.length)
        : body;
    if (label.isEmpty) return null;
    final rawDetails = event.content[_callDetailsKey];
    final details = rawDetails is Map ? rawDetails : const {};
    final legacy = _callFromBody(label, network);
    final kind =
        _callKind(details['call_type']) ??
        _callKind(action['call_type']) ??
        legacy?.kind ??
        BridgeCallKind.unknown;
    final outcome =
        _callOutcome(details['status']) ??
        _callOutcome(action['status']) ??
        legacy?.outcome ??
        BridgeCallOutcome.unknown;
    return BridgeCallNotice(
      label.replaceAll(_lineBreak, ' '),
      network: network,
      kind: kind,
      outcome: outcome,
      direction:
          _callDirection(details['direction']) ??
          _callDirection(action['direction']) ??
          legacy?.direction ??
          _callDirection(outcome.name),
      duration:
          _durationFromSeconds(details['duration_seconds']) ??
          _durationFromSeconds(action['duration_seconds']) ??
          legacy?.duration,
    );
  }
  if (event.isRichMessage) return null;
  if (network == 'Slack' && body == 'Huddle ended') {
    return BridgeCallNotice(
      body,
      network: network,
      kind: BridgeCallKind.unknown,
      outcome: BridgeCallOutcome.ended,
    );
  }
  if (network != 'Telegram') return null;
  final result = _legacyTelegramResult(body);
  if (result == null) return null;
  return BridgeCallNotice(
    body,
    network: network,
    kind: result.kind,
    outcome: result.outcome,
    duration: result.duration,
  );
}

BridgeCallKind? _callKind(Object? value) => switch (value) {
  'voice' || 'audio' => BridgeCallKind.voice,
  'video' => BridgeCallKind.video,
  'unknown' => BridgeCallKind.unknown,
  _ => null,
};

BridgeCallOutcome? _callOutcome(Object? value) => switch (value) {
  'incoming' => BridgeCallOutcome.incoming,
  'outgoing' => BridgeCallOutcome.outgoing,
  'started' => BridgeCallOutcome.started,
  'missed' => BridgeCallOutcome.missed,
  'answered' => BridgeCallOutcome.answered,
  'rejected' || 'declined' => BridgeCallOutcome.rejected,
  'failed' => BridgeCallOutcome.failed,
  'silenced' => BridgeCallOutcome.silenced,
  'ended' => BridgeCallOutcome.ended,
  'disconnected' => BridgeCallOutcome.disconnected,
  'canceled' || 'cancelled' => BridgeCallOutcome.canceled,
  'unknown' => BridgeCallOutcome.unknown,
  _ => null,
};

BridgeCallDirection? _callDirection(Object? value) => switch (value) {
  'incoming' => BridgeCallDirection.incoming,
  'outgoing' => BridgeCallDirection.outgoing,
  _ => null,
};

// Sources that carry an integer duration use seconds. Allow an explicit zero.
const _maxDurationSeconds = 0x7fffffff;
Duration? _durationFromSeconds(Object? value) =>
    value is int && value >= 0 && value <= _maxDurationSeconds
    ? Duration(seconds: value)
    : null;

final _telegramCallResult = RegExp(
  r'^(Video call|Call) (missed|disconnected|ended|rejected)'
  r'(?: \(([^()]+)\))?$',
);
final _telegramGroupEnded = RegExp(r'^Ended the video chat \(([^()]+)\)$');
final _markedCall = RegExp(
  r'^(?:(Incoming|Outgoing|Missed) )?(?:(voice|audio|video) )?call'
  r'(?: (started|missed|answered|rejected|declined|ended|disconnected|canceled|cancelled))?'
  r'(?: \(([^()]+)\)|[\r\n]+([^\r\n]+))?$',
  caseSensitive: false,
);
final _clockDuration = RegExp(r'^(?:(\d{1,7}):)?(\d{1,7}):([0-5]\d)$');
final _durationWords = RegExp(
  r'^\d{1,10} (?:weeks?|days?|hours?|minutes?|seconds?)'
  r'(?:(?:, | and )\d{1,10} (?:weeks?|days?|hours?|minutes?|seconds?)){0,4}$',
);
final _durationPart = RegExp(r'(\d+) (week|day|hour|minute|second)s?');

Duration? _bridgeDuration(String? raw) {
  if (raw == null) return null;
  final clock = _clockDuration.firstMatch(raw);
  if (clock != null) {
    final hours = int.parse(clock.group(1) ?? '0');
    final minutes = int.parse(clock.group(2)!);
    if (clock.group(1) != null && minutes >= 60) return null;
    return _durationFromSeconds(
      hours * 3600 + minutes * 60 + int.parse(clock.group(3)!),
    );
  }
  if (!_durationWords.hasMatch(raw)) return null;
  var seconds = 0;
  for (final part in _durationPart.allMatches(raw)) {
    final factor = switch (part.group(2)) {
      'week' => Duration.secondsPerDay * 7,
      'day' => Duration.secondsPerDay,
      'hour' => Duration.secondsPerHour,
      'minute' => Duration.secondsPerMinute,
      _ => 1,
    };
    seconds += int.parse(part.group(1)!) * factor;
    if (seconds > _maxDurationSeconds) return null;
  }
  return _durationFromSeconds(seconds);
}

typedef _CallBody = ({
  BridgeCallKind kind,
  BridgeCallOutcome outcome,
  BridgeCallDirection? direction,
  Duration? duration,
});

_CallBody? _legacyTelegramResult(String body) {
  final result = _telegramCallResult.firstMatch(body);
  if (result == null) return null;
  final rawDuration = result.group(3);
  if (rawDuration != null && !_durationWords.hasMatch(rawDuration)) return null;
  final duration = _bridgeDuration(rawDuration);
  if (rawDuration != null && duration == null) return null;
  return (
    kind: result.group(1) == 'Video call'
        ? BridgeCallKind.video
        : BridgeCallKind.voice,
    outcome: _callOutcome(result.group(2))!,
    direction: null,
    duration: duration,
  );
}

_CallBody? _callFromBody(String body, String? network) {
  if (network == 'Telegram') {
    final result = _legacyTelegramResult(body);
    if (result != null) return result;
    final groupEnded = _telegramGroupEnded.firstMatch(body);
    if (groupEnded != null) {
      return (
        kind: BridgeCallKind.video,
        outcome: BridgeCallOutcome.ended,
        direction: null,
        duration: _bridgeDuration(groupEnded.group(1)),
      );
    }
    if (const {
      'Started a call',
      'Started a video call',
      'Started a video chat',
    }.contains(body)) {
      return (
        kind: body == 'Started a call'
            ? BridgeCallKind.voice
            : BridgeCallKind.video,
        outcome: BridgeCallOutcome.started,
        direction: body == 'Started a video chat'
            ? null
            : BridgeCallDirection.incoming,
        duration: null,
      );
    }
  }
  final call = _markedCall.firstMatch(body);
  if (call == null) return null;
  final prefix = call.group(1)?.toLowerCase();
  final duration = _bridgeDuration(call.group(4) ?? call.group(5));
  return (
    kind: _callKind(call.group(2)?.toLowerCase()) ?? BridgeCallKind.unknown,
    outcome:
        _callOutcome(call.group(3)?.toLowerCase()) ??
        _callOutcome(prefix) ??
        (network == 'Messenger' &&
                _clockDuration.hasMatch(call.group(4) ?? '') &&
                duration != null
            ? BridgeCallOutcome.ended
            : BridgeCallOutcome.unknown),
    direction: _callDirection(prefix),
    duration: duration,
  );
}

/// The service line for [event] (pass the display event, so a placeholder
/// that the network later replaced with the real message is a message
/// again), or null for an ordinary message. Call entries may also use
/// `m.text` with an explicit call marker.
BridgeServiceNotice? bridgeServiceNotice(Event event) {
  final call = bridgeCallNotice(event);
  if (call != null) return call;
  if (event.type != EventTypes.Message ||
      event.messageType != MessageTypes.Notice ||
      event.redacted ||
      !isBridgedRoom(event.room)) {
    return null;
  }
  final content = event.content;
  final body = event.body.trim();
  final network = bridgedNetworkLabel(event.room) ?? 'the network';
  final action = content[_actionKey];
  if ((action is Map && action['type'] == 'message_history_notice') ||
      (event.senderId != event.room.client.userID &&
          network == 'WhatsApp' &&
          _historyNotice.hasMatch(body))) {
    return BridgeServiceNotice(
      'Earlier messages were shared in $network.',
      Icons.history,
    );
  }
  if (event.senderId == event.room.client.userID) return null;
  if (content['fi.mau.whatsapp.undecryptable'] == true) {
    return const BridgeServiceNotice(
      'Waiting for this message. This can take a while.',
      Icons.schedule,
    );
  }
  if (body.contains('\n')) return null;
  if (content.containsKey('fi.mau.bridge.internal_error') ||
      _remoteError.hasMatch(body)) {
    return BridgeServiceNotice(
      'A message from $network couldn’t be shown. Open $network to see it.',
      Icons.error_outline,
    );
  }
  final old = _oldMedia.firstMatch(body);
  if (content.containsKey('fi.mau.whatsapp.failed_media') && old != null) {
    return BridgeServiceNotice(
      'Old ${old.group(1)!.toLowerCase()} isn’t available here.',
      Icons.image_not_supported_outlined,
    );
  }
  final failed = _failedMedia.firstMatch(body);
  if (failed != null) {
    final app = failed.group(2)!;
    return BridgeServiceNotice(
      'This ${failed.group(1)!.toLowerCase()} couldn’t be shown here. Open '
      '$app to see it.',
      Icons.image_not_supported_outlined,
    );
  }
  final set = _timerSet.firstMatch(body) ?? _timerAuto.firstMatch(body);
  if (set != null) {
    return BridgeServiceNotice(
      'Disappearing messages: ${set.group(1)}',
      Icons.timer_outlined,
    );
  }
  if (_timerOff.hasMatch(body)) {
    return const BridgeServiceNotice(
      'Disappearing messages turned off',
      Icons.timer_off_outlined,
    );
  }
  if (body.startsWith('You received a view once ') ||
      body == 'Unsupported photo message. Check Telegram app.') {
    return BridgeServiceNotice(body, Icons.visibility_off_outlined);
  }
  return null;
}
