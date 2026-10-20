// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline production-adapter fixtures. No HTTP/account storage.
import 'dart:async';

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConversationDatabase implements DatabaseApi {
  @override
  Future<User?> getUser(String id, Room room) async =>
      room.getState(EventTypes.RoomMember, id)?.asUser(room);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class ConversationClient extends Client {
  final String owner;
  ConversationClient([this.owner = '@owner:example.invalid'])
    : super('offline conversation fixture', database: ConversationDatabase());
  @override
  String get userID => owner;
  @override
  Map<String, List<String>> get directChats => {
    '@anna:example.invalid': rooms.map((r) => r.id).toList(),
  };
}

class ConversationRoom extends Room {
  final sourceEvents = <Event>[];
  bool sendingAllowed = true;
  bool reactionsAllowed = true;
  int reactionsSent = 0;
  final sentEmoji = <String>[];
  Completer<String?>? reactionGate;
  Object? reactionFailure;
  ConversationRoom(Client client, String id, {String network = 'whatsapp'})
    : super(id: id, client: client, membership: Membership.join) {
    client.rooms.add(this);
    state(EventTypes.RoomName, {'name': 'Fictional conversation'});
    state('m.bridge', {
      'protocol': {'id': network},
    }, key: 'fixture');
    state(bridgeFeaturesEventType, {
      'reply': 2,
      'reaction': 2,
      'reaction_count': 1,
    }, key: 'fixture');
    state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Anna',
    }, key: '@anna:example.invalid');
    state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'You',
    }, key: client.userID!);
  }
  void state(String type, Map<String, dynamic> content, {String key = ''}) =>
      setState(
        Event(
          room: this,
          type: type,
          stateKey: key,
          eventId: '\$state-$type-$key',
          senderId: client.userID!,
          originServerTs: DateTime.utc(2026),
          content: content,
        ),
      );
  @override
  bool get canSendDefaultMessages => sendingAllowed;
  @override
  bool canSendEvent(String type) =>
      type == EventTypes.Reaction ? reactionsAllowed : sendingAllowed;
  @override
  Future<String?> sendReaction(
    String eventId,
    String key, {
    String? txid,
  }) async {
    reactionsSent++;
    sentEmoji.add(key);
    if (reactionFailure != null) throw reactionFailure!;
    return reactionGate == null
        ? r'$fixture-reaction'
        : await reactionGate!.future;
  }

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async => ConversationTimeline(
    room: this,
    chunk: TimelineChunk(events: sourceEvents),
    onUpdate: onUpdate,
  );
  Event message(
    String id,
    String text, {
    bool outgoing = false,
    int minute = 40,
    EventStatus status = EventStatus.synced,
    Map<String, dynamic>? content,
  }) {
    final event = Event(
      room: this,
      eventId: id,
      type: EventTypes.Message,
      senderId: outgoing ? client.userID! : '@anna:example.invalid',
      originServerTs: DateTime.utc(2026, 10, 16, 16, minute),
      status: status,
      content: content ?? {'msgtype': MessageTypes.Text, 'body': text},
    );
    sourceEvents.insert(0, event);
    return event;
  }
}

class ConversationPersonal extends PersonalClient {
  final drafts = <({SendTarget target, String text})>[];
  final sends = <({Room room, String text, Event? reply, String? edit})>[];
  ImmediateSendState sendState = ImmediateSendState.accepted;
  ConversationPersonal(super.client)
    : super.forTesting(openStore: () => throw StateError('No fixture store'));
  @override
  Future<void> load() async {}
  @override
  Future<void> loadLocal() async {}
  @override
  Future<void> savePersonalDraft(
    String key,
    SendTarget target,
    String text,
  ) async {
    drafts.add((target: target, text: text));
    values[key] = {'text': text, 'target': target.toJson()};
  }

  @override
  Future<ImmediateSendResult> sendImmediate(
    Room room,
    String text, {
    Event? replyTo,
    String? editEventId,
    String? threadId,
  }) async {
    sends.add((room: room, text: text, reply: replyTo, edit: editEventId));
    return ImmediateSendResult(
      state: sendState,
      actionId: 'fixture-action',
      transactionId: 'fixture-txn',
      eventId: r'$accepted',
    );
  }

  @override
  Future<void> completeImmediate(String actionId) async {}
}

class ConversationMatrix extends MatrixState {
  Client active;
  final SharedPreferences preferences;
  ConversationMatrix(this.active, this.preferences);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: preferences);
}

class ConversationTimeline extends Timeline {
  ConversationTimeline({
    required super.room,
    required super.chunk,
    super.onUpdate,
  });
  @override
  bool get canRequestHistory => false;
}
