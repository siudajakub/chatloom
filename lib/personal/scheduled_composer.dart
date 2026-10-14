// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'capabilities.dart';

/// Displays the frozen schedule source without exposing wire identifiers.
String scheduledSourceSummary(Map<String, dynamic> job) {
  final target = job['target'];
  final conversation = target is Map ? target['conversation'] : null;
  final network = conversation is Map ? conversation['network'] : null;
  final content = job['content'];
  final relation = content is Map ? content['m.relates_to'] : null;
  return [
    network is String && network.isNotEmpty ? network : 'Source unavailable',
    if (relation is Map && relation['rel_type'] == RelationshipTypes.thread)
      'Thread'
    else if (relation is Map && relation['m.in_reply_to'] is Map)
      'Reply',
  ].join(' · ');
}

/// Captures the source and relation before a picker or other asynchronous work.
/// The worker sends this complete content through the SDK with its durable txid;
/// no new schedule schema, crypto, or transport is introduced here.
class FrozenScheduledComposer {
  final Room room;
  final SendTarget target;
  final Event? reply;
  final String? threadRootEventId;
  final String? threadLastEventId;
  final String _account;
  final String? _device;
  final Uri? _server;
  final String? _replyId;
  final String? _replySender;
  final bool Function()? _isCurrent;

  String? get contextLabel => threadRootEventId != null
      ? 'Thread message'
      : reply != null
      ? 'Reply in source conversation'
      : null;

  FrozenScheduledComposer._(
    this.room,
    this.target,
    this.reply,
    this.threadRootEventId,
    this.threadLastEventId,
    this._account,
    this._device,
    this._server,
    this._replyId,
    this._replySender,
    this._isCurrent,
  );

  factory FrozenScheduledComposer.capture({
    required Room room,
    required SendTarget target,
    Event? reply,
    String? threadRootEventId,
    String? threadLastEventId,
    bool editing = false,
    bool Function()? isCurrent,
  }) {
    if (editing) {
      throw StateError('Finish editing before scheduling a new message.');
    }
    final account = room.client.userID;
    if (account == null ||
        target.conversation.accountId != account ||
        target.conversation.roomId != room.id) {
      throw StateError('The scheduled source is unavailable.');
    }
    if (reply != null &&
        (!identical(reply.room, room) ||
            !identical(reply.room.client, room.client) ||
            !reply.eventId.startsWith(r'$') ||
            !reply.status.isSynced ||
            reply.redacted)) {
      throw StateError('The reply source is unavailable.');
    }
    for (final id in [threadRootEventId, threadLastEventId]) {
      if (id != null && !id.startsWith(r'$')) {
        throw StateError('The thread source is unavailable.');
      }
    }
    if (threadRootEventId == null && threadLastEventId != null) {
      throw StateError('The thread source is unavailable.');
    }
    final result = FrozenScheduledComposer._(
      room,
      target,
      reply,
      threadRootEventId,
      threadLastEventId,
      account,
      room.client.deviceID,
      room.client.baseUri,
      reply?.eventId,
      reply?.senderId,
      isCurrent,
    );
    result.validateCurrent();
    return result;
  }

  /// Rechecked after every picker/upload boundary before persisting a job.
  void validateCurrent() {
    if (_isCurrent?.call() == false ||
        room.client.userID != _account ||
        room.client.deviceID != _device ||
        room.client.baseUri != _server ||
        !identical(room.client.getRoomById(room.id), room) ||
        room.membership != Membership.join ||
        !room.canSendDefaultMessages ||
        (reply != null &&
            (reply!.redacted ||
                reply!.eventId != _replyId ||
                reply!.senderId != _replySender))) {
      throw StateError('The selected source changed. Select it again.');
    }
    if (reply != null || threadLastEventId != null) {
      final capability = RoomCapabilities.forFeature(
        BridgeFeature.reply,
        room,
        event: reply,
      );
      if (!capability.allowed) throw StateError(capability.reason);
    }
    if (threadRootEventId != null) {
      final capability = RoomCapabilities.forFeature(
        BridgeFeature.thread,
        room,
      );
      if (!capability.allowed) throw StateError(capability.reason);
    }
  }

  bool matchesContext({
    Event? reply,
    String? threadRootEventId,
    String? threadLastEventId,
    bool editing = false,
  }) =>
      !editing &&
      identical(this.reply, reply) &&
      this.threadRootEventId == threadRootEventId &&
      this.threadLastEventId == threadLastEventId;

  Map<String, dynamic> content(Map<String, dynamic> original) {
    validateCurrent();
    final result = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(original)) as Map,
    );
    if (result.containsKey('m.relates_to')) {
      throw StateError('The scheduled content already has a relation.');
    }
    if (_replyId != null || threadRootEventId != null) {
      result['m.relates_to'] = <String, dynamic>{
        if (threadRootEventId != null) ...{
          'event_id': threadRootEventId,
          'rel_type': RelationshipTypes.thread,
          'is_falling_back': _replyId == null,
        },
        if (_replyId != null)
          'm.in_reply_to': {'event_id': _replyId}
        else if (threadLastEventId != null)
          'm.in_reply_to': {'event_id': threadLastEventId},
      };
    }
    if (_replySender != null && _replySender != _account) {
      final mentions = result['m.mentions'];
      final existing = mentions is Map ? mentions['user_ids'] : null;
      result['m.mentions'] = <String, dynamic>{
        if (mentions is Map && mentions['room'] == true) 'room': true,
        'user_ids': {
          if (existing is List) ...existing.whereType<String>(),
          _replySender,
        }.toList(),
      };
    }
    return result;
  }
}
