// SPDX-License-Identifier: AGPL-3.0-or-later
// Standalone actual-source regression; use worker's pure-Dart package config.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:personal_core/personal_core.dart';

import '../../../lib/personal/scheduled_composer.dart';

const _owner = '@synthetic-owner:example.invalid';
const _peer = '@synthetic-peer:example.invalid';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Composer preparation must never read history or send');
}

class _Client extends Client {
  _Client() : super('synthetic scheduled composer', database: _Database());
  String owner = _owner, device = 'synthetic-device';
  @override
  String? get userID => owner;
  @override
  String? get deviceID => device;
}

class _Room extends Room {
  _Room(_Client client, {String id = '!synthetic:example.invalid'})
    : super(id: id, client: client, membership: Membership.join);
  bool allowed = true;
  @override
  bool get canSendDefaultMessages => allowed;
}

void _check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

void _reject(void Function() action, String description) {
  var failed = false;
  try {
    action();
  } on StateError {
    failed = true;
  }
  _check(failed, description);
}

Event _event(Room room, {String sender = _peer}) => Event(
  room: room,
  type: EventTypes.Message,
  eventId: r'$synthetic-reply',
  senderId: sender,
  originServerTs: DateTime.utc(2026, 10, 13),
  content: {'msgtype': 'm.text', 'body': 'Synthetic fixture'},
);

void _capabilities(Room room, {int reply = 2, int thread = 2}) {
  room.setState(
    Event(
      room: room,
      type: bridgeFeaturesEventType,
      stateKey: '',
      eventId: r'$synthetic-capabilities',
      senderId: _peer,
      originServerTs: DateTime.utc(2026, 10, 13),
      content: {'reply': reply, 'thread': thread},
    ),
  );
}

void main() {
  final client = _Client();
  final room = _Room(client);
  client.rooms.add(room);
  _capabilities(room);
  const target = SendTarget(
    conversation: ConversationRef(
      accountId: _owner,
      roomId: '!synthetic:example.invalid',
      network: 'fixture',
    ),
    readUpToEventId: r'$viewed-cutoff',
  );
  final plain = FrozenScheduledComposer.capture(room: room, target: target);
  _check(
    !plain
        .content({'msgtype': 'm.text', 'body': 'Synthetic'})
        .containsKey('m.relates_to'),
    'Ordinary text acquired a reply',
  );
  final parent = _event(room);
  final reply = FrozenScheduledComposer.capture(
    room: room,
    target: target,
    reply: parent,
  );
  final content = reply.content({'msgtype': 'm.text', 'body': 'Synthetic'});
  _check(
    content['m.relates_to']['m.in_reply_to']['event_id'] == parent.eventId,
    'Scheduled reply lost the original source',
  );
  _check(
    content['m.mentions']['user_ids'].single == _peer,
    'Scheduled reply lost its explicit recipient mention',
  );
  _check(
    reply.target.readUpToEventId == r'$viewed-cutoff',
    'Scheduling expanded the accepted-send read cutoff',
  );
  final own = FrozenScheduledComposer.capture(
    room: room,
    target: target,
    reply: _event(room, sender: _owner),
  );
  _check(
    !own
        .content({'msgtype': 'm.text', 'body': 'Synthetic'})
        .containsKey('m.mentions'),
    'Reply mentioned our own account',
  );

  final thread = FrozenScheduledComposer.capture(
    room: room,
    target: target,
    reply: parent,
    threadRootEventId: r'$synthetic-root',
    threadLastEventId: r'$last-before-picker',
  );
  final threadContent = thread.content({
    'msgtype': 'm.text',
    'body': 'Synthetic',
  });
  final relation = threadContent['m.relates_to'];
  _check(
    relation['rel_type'] == RelationshipTypes.thread &&
        relation['event_id'] == r'$synthetic-root' &&
        relation['m.in_reply_to']['event_id'] == parent.eventId &&
        relation['is_falling_back'] == false,
    'Thread reply context was flattened',
  );
  final fallback = FrozenScheduledComposer.capture(
    room: room,
    target: target,
    threadRootEventId: r'$synthetic-root',
    threadLastEventId: r'$last-before-picker',
  );
  final originalMedia = <String, dynamic>{
    'msgtype': 'm.file',
    'body': 'synthetic.bin',
    'file': {
      'url': 'mxc://example.invalid/synthetic',
      'key': {'k': 'synthetic'},
    },
  };
  final media = fallback.content(originalMedia);
  originalMedia['file']['key']['k'] = 'later-edit';
  _check(
    media['file']['key']['k'] == 'synthetic',
    'Scheduled media was mutable',
  );
  _check(
    media['m.relates_to']['m.in_reply_to']['event_id'] ==
            r'$last-before-picker' &&
        media['m.relates_to']['is_falling_back'] == true,
    'Media schedule lost the frozen thread fallback',
  );
  final job = ScheduledSend(
    id: 'synthetic-job',
    target: target,
    dueAt: DateTime.utc(2026, 11),
    content: media,
    transactionId: 'synthetic-stable-transaction',
  );
  final restored = ScheduledSend.fromJson(
    Map<String, dynamic>.from(jsonDecode(jsonEncode(job.toJson())) as Map),
  );
  _check(
    restored.content['m.relates_to']['event_id'] == r'$synthetic-root' &&
        restored.transactionId == job.transactionId &&
        restored.target.conversation == target.conversation,
    'Restart changed relation, source or transaction',
  );
  _check(
    !thread.matchesContext(
      reply: _event(room),
      threadRootEventId: r'$synthetic-root',
      threadLastEventId: r'$last-before-picker',
    ),
    'Cleanup consumed a new reply selected during the picker',
  );
  _check(
    !thread.matchesContext(
      reply: parent,
      threadRootEventId: r'$different-thread',
      threadLastEventId: r'$last-before-picker',
    ),
    'Cleanup consumed another thread',
  );
  _reject(
    () => FrozenScheduledComposer.capture(
      room: room,
      target: target,
      editing: true,
    ),
    'Editing created a scheduled new message',
  );
  final foreign = _Room(client, id: '!foreign:example.invalid');
  _reject(
    () => FrozenScheduledComposer.capture(
      room: room,
      target: target,
      reply: _event(foreign),
    ),
    'Cross-room reply was scheduled',
  );
  _reject(
    () => FrozenScheduledComposer.capture(
      room: room,
      target: const SendTarget(
        conversation: ConversationRef(
          accountId: '@foreign:example.invalid',
          roomId: '!synthetic:example.invalid',
          network: 'fixture',
        ),
      ),
    ),
    'Cross-account target was scheduled',
  );
  _capabilities(room, reply: -2);
  _reject(
    () => reply.validateCurrent(),
    'Capability loss during picker was ignored',
  );
  _capabilities(room, thread: -2);
  _reject(() => thread.validateCurrent(), 'Thread capability loss was ignored');
  _capabilities(room);
  client.device = 'replacement-device';
  _reject(
    () => plain.validateCurrent(),
    'Device replacement retained schedule intent',
  );
  client.device = 'synthetic-device';
  client.owner = '@replacement-owner:example.invalid';
  _reject(
    () => plain.validateCurrent(),
    'Account replacement retained schedule intent',
  );
  client.owner = _owner;
  var active = true;
  final guarded = FrozenScheduledComposer.capture(
    room: room,
    target: target,
    isCurrent: () => active,
  );
  active = false;
  _reject(
    () => guarded.validateCurrent(),
    'Active account switch retained intent',
  );
  room.allowed = false;
  _reject(() => plain.validateCurrent(), 'Source permission loss was ignored');
  room.allowed = true;
  client.rooms.clear();
  client.rooms.add(_Room(client));
  _reject(
    () => plain.validateCurrent(),
    'Replacement room inherited frozen intent',
  );
  print(
    'PASS scheduled composer: source/account/device/capability guards, edit '
    'blocking, reply/thread text+media, immutable restart+txid and cleanup context',
  );
}
