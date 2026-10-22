// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:matrix/matrix.dart';

/// Bridge rejections of the user's reactions, edits and deletions in the
/// open chat (`com.beeper.message_send_status` `FAIL_*` relating to that
/// event, not to the message): mautrix sends them for every bridged Matrix
/// event, and they used to be dropped. A rejected reaction or edit is
/// reverted on Matrix too, so ChatLoom shows what the other person sees; a
/// deletion cannot be undone, so the user is told it is still there. A
/// message's own rejection stays on its bubble ("Not delivered").
///
/// Only live reports (younger than [maxAge]) from the room's bridge bot
/// count; each one is handled once. The text goes to [notify] (a snackbar
/// of the chat), never a dialog.
class NetworkRejectionWatcher {
  NetworkRejectionWatcher(
    this.client, {
    required this.rooms,
    required this.notify,
    this.now = DateTime.now,
  }) {
    _sub = client.onTimelineEvent.stream.listen(
      (event) => unawaited(handle(event).catchError((Object _) {})),
    );
  }

  final Client client;

  /// Rooms of the open chat (a merged person has several).
  final Set<String> Function() rooms;
  final void Function(String text) notify;
  final DateTime Function() now;
  static const maxAge = Duration(minutes: 15);

  StreamSubscription<Event>? _sub;
  final _handled = <String>{};

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// Handles one timeline event (public for tests).
  Future<void> handle(Event report) async {
    if (report.type != beeperMessageSendStatusType) return;
    final room = report.room;
    if (!rooms().contains(room.id) ||
        now().difference(report.originServerTs) > maxAge) {
      return;
    }
    final status = BridgeSendStatus.parse(
      report.content,
      sender: report.senderId,
      bridgeBots: bridgeBotsOf(room),
      at: report.originServerTs,
    );
    if (status == null || !status.failed) return;
    final relation = report.content['m.relates_to'];
    final targetId = relation is Map ? relation['event_id'] : null;
    if (targetId is! String || !targetId.startsWith(r'$')) return;
    if (!_handled.add('${room.id}\u0000$targetId')) return;
    while (_handled.length > 128) {
      _handled.remove(_handled.first);
    }
    if (MessageDeletions.isQuiet(room, targetId)) return;
    final target = await room.getEventById(targetId);
    if (target == null || target.senderId != client.userID) return;
    final network = bridgedNetworkLabel(room) ?? 'The other network';
    if (target.type == EventTypes.Reaction) {
      notify(
        status.retriable
            ? 'Couldn’t send your reaction to $network. Try again.'
            : '$network didn’t accept this reaction.',
      );
      await _revert(target);
      return;
    }
    if (target.type == EventTypes.Redaction) {
      final redacted = target.redacts == null
          ? null
          : await room.getEventById(target.redacts!);
      if (redacted?.type == EventTypes.Reaction) {
        notify('$network didn’t remove your reaction.');
      } else {
        notify('Not deleted on $network. The other person may still see it.');
      }
      return;
    }
    if (target.type == EventTypes.Message &&
        target.relationshipType == RelationshipTypes.edit) {
      notify(
        '$network didn’t accept the edit. The message shows the earlier '
        'text again.',
      );
      await _revert(target);
    }
  }

  /// Redacts a rejected reaction or edit on Matrix; the bridge's report
  /// about that tidy-up redaction is not shown.
  Future<void> _revert(Event target) async {
    if (target.redacted) return;
    final id = await target.redactEvent();
    if (id != null) MessageDeletions.markQuiet(target.room, id);
  }
}
