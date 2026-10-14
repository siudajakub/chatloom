// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/reminder_reply.dart';
import 'package:test/test.dart';

const own = '@self:example.invalid';
final since = DateTime.utc(2026, 10, 4, 12);

class NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Predicate fixture must not access storage');
}

final room = Room(
  id: '!fixture:example.invalid',
  client: Client('fixture-predicate', database: NoDatabase()),
);
int sequence = 0;
Event event({
  String sender = '@recipient:example.invalid',
  String type = EventTypes.Message,
  DateTime? at,
  bool edit = false,
  bool redacted = false,
}) => Event(
  eventId: '\$fixture-${sequence++}',
  room: room,
  senderId: sender,
  originServerTs: at ?? since.add(const Duration(seconds: 1)),
  type: type,
  content: {
    'msgtype': 'm.text',
    'body': 'fixture',
    if (edit) 'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$old'},
  },
  unsigned: redacted
      ? {
          'redacted_because': {
            'event_id': r'$redaction',
            'type': 'm.room.redaction',
            'sender': own,
            'origin_server_ts': since.millisecondsSinceEpoch,
            'content': {},
          },
        }
      : null,
);

class History implements ReminderReplyHistory {
  final List<List<Event>> pages;
  int page = 0;
  int keyRequests = 0;
  bool gaps = false;
  bool stuck = false;
  bool databaseBoundary = false;
  History(this.pages);
  @override
  List<Event> get events =>
      pages.take(page + 1).expand((events) => events).toList();
  @override
  bool get canRequestHistory => page < pages.length - 1;
  @override
  bool get hasGaps => gaps;
  @override
  String get progressToken => '$page';
  @override
  Future<void> requestHistory() async {
    if (databaseBoundary) {
      databaseBoundary = false;
      return;
    }
    if (!stuck) page++;
  }

  @override
  void requestKeys() {
    keyRequests++;
  }
}

void main() {
  test(
    'received message and sticker count, own/edit/redaction/reaction/journal do not',
    () {
      expect(isRecipientReply(event(), own, since), isTrue);
      expect(
        isRecipientReply(event(type: EventTypes.Sticker), own, since),
        isTrue,
      );
      for (final excluded in [
        event(sender: own),
        event(edit: true),
        event(redacted: true),
        event(type: EventTypes.Reaction),
        event(type: personalEventType),
        event(at: since),
      ]) {
        expect(isRecipientReply(excluded, own, since), isFalse);
      }
    },
  );
  test(
    'pagination finds received response concealed by newer own burst',
    () async {
      final history = History([
        List.generate(
          30,
          (_) => event(sender: own, at: since.add(const Duration(minutes: 2))),
        ),
        [event(at: since.add(const Duration(minutes: 1)))],
        [event(sender: own, at: since)],
      ]);
      expect(await receivedReplySince(history, own, since), isTrue);
      expect(history.page, 1);
    },
  );
  test(
    'database exhaustion transition can be followed by server history',
    () async {
      final history = History([
        [event(sender: own)],
        [event()],
      ])..databaseBoundary = true;
      expect(await receivedReplySince(history, own, since), isTrue);
      expect(history.page, 1);
    },
  );
  test(
    'no reply only after continuous <=createdAt frontier, including equal timestamp',
    () async {
      final history = History([
        [event(sender: own)],
        [event(edit: true), event(redacted: true)],
        [event(at: since)],
      ]);
      expect(await receivedReplySince(history, own, since), isFalse);
      expect(history.page, 2);
    },
  );
  test(
    'missing recipient keys stay unresolved and request keys without false absence',
    () async {
      final history = History([
        [event(type: EventTypes.Encrypted), event(at: since)],
      ]);
      await expectLater(
        receivedReplySince(history, own, since),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'waiting_keys',
          ),
        ),
      );
      expect(history.keyRequests, 1);
    },
  );
  test(
    'unavailable history and unresolved gaps do not mean no response',
    () async {
      final unavailable = History([
        [event(sender: own)],
      ]);
      await expectLater(
        receivedReplySince(unavailable, own, since),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'history_unavailable',
          ),
        ),
      );
      final gap = History([
        [event(sender: own, at: since)],
      ])..gaps = true;
      await expectLater(
        receivedReplySince(gap, own, since),
        throwsA(isA<WorkerFailure>()),
      );
    },
  );
  test(
    'no pagination progress stays unresolved instead of infinite loop or false reminder',
    () async {
      final stuck = History([
        [event(sender: own)],
        [event(at: since)],
      ])..stuck = true;
      await expectLater(
        receivedReplySince(stuck, own, since),
        throwsA(isA<WorkerFailure>()),
      );
    },
  );
}
