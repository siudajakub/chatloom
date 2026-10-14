// SPDX-License-Identifier: AGPL-3.0-or-later
// Standalone actual-source regression; use worker's pure-Dart package config.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../../../lib/personal/notification_eligibility.dart';

const _owner = '@synthetic-owner:example.invalid';

class _Database implements DatabaseApi {
  Event? parent;
  int reads = 0;
  bool fail = false;
  Future<Event?> Function()? read;
  @override
  Future<Event?> getEventById(String id, Room room) async {
    reads++;
    if (fail) throw StateError('Synthetic storage failure');
    return read == null ? parent : await read!();
  }

  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database/network operation');
}

class _Client extends Client {
  _Client(_Database database)
    : super('synthetic notification', database: database);
  String owner = _owner;
  String device = 'synthetic-device';
  @override
  String? get userID => owner;
  @override
  String? get deviceID => device;
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Event _event(
  Room room, {
  String id = r'$synthetic-reply',
  String sender = '@synthetic-peer:example.invalid',
  String type = EventTypes.Message,
  Object? relation = const {
    'rel_type': 'm.thread',
    'event_id': r'$synthetic-root',
    'm.in_reply_to': {'event_id': r'$synthetic-parent'},
  },
  Object? mentions,
}) => Event(
  room: room,
  type: type,
  eventId: id,
  senderId: sender,
  originServerTs: DateTime.utc(2026, 10, 13),
  content: {
    'msgtype': 'm.text',
    'body': 'Synthetic fixture',
    'm.relates_to': relation,
    if (mentions != null) 'm.mentions': mentions,
  },
);

Future<void> main() async {
  final database = _Database();
  final client = _Client(database);
  final room = Room(id: '!synthetic:example.invalid', client: client);
  client.rooms.add(room);
  final muted = ConversationMetadata(entityId: 'synthetic', muted: true);
  final lowPriority = ConversationMetadata(
    entityId: 'synthetic',
    lowPriority: true,
  );
  final normal = ConversationMetadata(entityId: 'synthetic');
  database.parent = _event(room, id: r'$synthetic-parent', sender: _owner);
  _check(
    await personalNotificationEligible(_event(room), muted),
    'Private mute suppressed a proven thread reply to own message',
  );
  _check(
    await personalNotificationEligible(_event(room), lowPriority),
    'Low priority differs from private mute in the background',
  );
  final before = database.reads;
  _check(
    await personalNotificationEligible(_event(room, relation: null), normal),
    'Ordinary conversation incorrectly filtered',
  );
  _check(
    await personalNotificationEligible(
      _event(
        room,
        mentions: {
          'user_ids': [_owner],
        },
      ),
      muted,
    ),
    'Explicit mention incorrectly filtered',
  );
  _check(
    database.reads == before,
    'Normal conversation or explicit mention performed unnecessary lookup',
  );

  database.parent = _event(room, id: r'$synthetic-parent');
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'Foreign author enabled the own-message exception',
  );
  database.parent = _event(room, id: r'$different-parent', sender: _owner);
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'Wrong event ID enabled the thread exception',
  );
  final foreign = Room(id: '!foreign:example.invalid', client: client);
  database.parent = _event(foreign, id: r'$synthetic-parent', sender: _owner);
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'A parent from another room enabled the exception',
  );
  final otherClient = _Client(_Database());
  final foreignAccount = Room(id: room.id, client: otherClient);
  database.parent = _event(
    foreignAccount,
    id: r'$synthetic-parent',
    sender: _owner,
  );
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'A parent from another Client enabled the exception',
  );
  database.parent = _event(
    room,
    id: r'$synthetic-parent',
    sender: _owner,
    type: EventTypes.Encrypted,
  );
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'Unknown encrypted event was inferred to be a thread parent',
  );

  database.parent = null;
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'Missing local parent inferred an exception',
  );
  database.fail = true;
  _check(
    !await personalNotificationEligible(_event(room), muted),
    'Storage fault escaped safe filtering',
  );
  database.fail = false;
  final noLookup = database.reads;
  for (final relation in [
    null,
    'malformed',
    {
      'm.in_reply_to': {'event_id': r'$synthetic-parent'},
    },
    {
      'rel_type': 'm.thread',
      'event_id': r'$root',
      'm.in_reply_to': 'malformed',
    },
    {
      'rel_type': 'm.thread',
      'event_id': '!wrong',
      'm.in_reply_to': {'event_id': r'$synthetic-parent'},
    },
  ]) {
    _check(
      !await personalNotificationEligible(
        _event(room, relation: relation, mentions: 'malformed'),
        muted,
      ),
      'Malformed relation or ordinary reply enabled thread notification',
    );
  }
  _check(
    database.reads == noLookup,
    'Invalid relation performed local/network work',
  );

  final completed = Completer<Event?>();
  database.read = () => completed.future;
  final delayed = personalNotificationEligible(_event(room), muted);
  client.device = 'replacement-device';
  completed.complete(_event(room, id: r'$synthetic-parent', sender: _owner));
  _check(
    !await delayed,
    'Device replacement retained delayed notification intent',
  );
  database.read = null;
  client.device = 'synthetic-device';
  final accountCompleted = Completer<Event?>();
  database.read = () => accountCompleted.future;
  final changedAccount = personalNotificationEligible(_event(room), muted);
  client.owner = '@replacement-owner:example.invalid';
  accountCompleted.complete(
    _event(room, id: r'$synthetic-parent', sender: _owner),
  );
  _check(!await changedAccount, 'Account replacement retained delayed intent');
  print(
    'PASS notification eligibility: foreground/background parity, local-only '
    'source-bound parent, mentions, malformed/missing keys and account/device races',
  );
}
