// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// What a bridge's own notice in a chat means, in ChatLoom's words (BR-08).
/// mautrix bridges post these as `m.notice` messages from the contact or
/// the bot; drawn as bubbles they read like the contact wrote them.
@immutable
class BridgeServiceNotice {
  final String text;
  final IconData icon;
  const BridgeServiceNotice(this.text, this.icon);

  @override
  bool operator ==(Object other) =>
      other is BridgeServiceNotice && other.text == text && other.icon == icon;
  @override
  int get hashCode => Object.hash(text, icon);
  @override
  String toString() => 'BridgeServiceNotice(redacted)';
}

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

/// The service line for [event] (pass the display event, so a placeholder
/// that the network later replaced with the real message is a message
/// again), or null for an ordinary message. Only `m.notice` in a bridged
/// chat qualifies, and a notice that carries a caption or other text after
/// the bridge's sentence stays a bubble so nothing is lost.
BridgeServiceNotice? bridgeServiceNotice(Event event) {
  if (event.type != EventTypes.Message ||
      event.messageType != MessageTypes.Notice ||
      event.redacted ||
      event.senderId == event.room.client.userID ||
      !isBridgedRoom(event.room)) {
    return null;
  }
  final content = event.content;
  final body = event.body.trim();
  final network = bridgedNetworkLabel(event.room) ?? 'the network';
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
