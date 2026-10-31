// SPDX-License-Identifier: AGPL-3.0-or-later
// How deleted messages read: labels, previews, the SDK fallback, timeline
// and merged-chat visibility. Fictional offline fixtures; no account,
// storage or network.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@owner:example.invalid';
const _bot = '@telegrambot:bridge.invalid';
const _anna = '@telegram_200:bridge.invalid';
const _ownGhost = '@telegram_100:bridge.invalid';
const _bob = '@telegram_300:bridge.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('deleted fixture', database: _NoDatabase());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

void _state(Room room, String type, Map<String, dynamic> content, String key) =>
    room.setState(
      Event(
        room: room,
        type: type,
        stateKey: key,
        content: content,
        eventId: '\$state-$type-$key',
        senderId: _bot,
        originServerTs: DateTime.utc(2026),
      ),
    );

Room _room(_Client client, String id, {required bool dm}) {
  final room = Room(id: id, client: client, membership: Membership.join);
  client.rooms.add(room);
  _state(room, 'm.bridge', {
    'bridgebot': _bot,
    'protocol': {'id': 'telegram'},
    'channel': {'id': dm ? '200' : '-1009', if (dm) 'fi.mau.receiver': '100'},
    'com.beeper.room_type.v2': dm ? 'dm' : 'group_dm',
  }, 'fixture');
  for (final entry in {
    _owner: 'Owner',
    _bot: 'Telegram bridge bot',
    _anna: 'Anna',
    _bob: 'Bob',
    _ownGhost: 'excellent P',
  }.entries) {
    if (dm && entry.key == _bob) continue;
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': entry.value,
    }, entry.key);
  }
  if (dm) client.direct[_anna] = [room.id];
  return room;
}

var _sequence = 0;

/// A message by [author], redacted by [redactor] when given.
Event _message(
  Room room,
  String author, {
  String body = 'the old secret text',
  String? redactor,
  Map<String, Object?> redaction = const {},
}) => Event(
  room: room,
  eventId: '\$event-${_sequence++}',
  senderId: author,
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026, 10, 31, 12),
  content: redactor == null ? {'msgtype': 'm.text', 'body': body} : {},
  unsigned: redactor == null
      ? null
      : {
          'redacted_because': {
            'type': EventTypes.Redaction,
            'event_id': '\$redaction-${_sequence++}',
            'sender': redactor,
            'origin_server_ts': DateTime.utc(
              2026,
              10,
              31,
              13,
            ).millisecondsSinceEpoch,
            'content': redaction,
          },
        },
);

void main() {
  late _Client client;
  late Room dm;
  late Room groupRoom;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() async {
    client = _Client();
    dm = _room(client, '!dm:example.invalid', dm: true);
    groupRoom = _room(client, '!group:example.invalid', dm: false);
    OwnSenderResolver.invalidate(client);
    await AppSettings.hideRedactedEvents.setItem(false);
    await AppSettings.hideUnknownEvents.setItem(true);
  });

  tearDown(() => MessageDeletions.debugReset(client));

  group('labels', () {
    test('own deletions, from this account or an own bridge ghost', () {
      expect(
        deletedLabel(_message(dm, _owner, redactor: _owner)),
        'You deleted this message',
      );
      expect(
        deletedLabel(_message(dm, _ownGhost, redactor: _ownGhost)),
        'You deleted this message',
      );
      expect(
        deletedLabel(_message(groupRoom, _ownGhost, redactor: _ownGhost)),
        'You deleted this message',
      );
    });

    test('somebody else deleting their own message names nobody', () {
      // Bridges redact as the author's ghost: never "Redacted by Anna".
      final label = deletedLabel(_message(dm, _anna, redactor: _anna));
      expect(label, 'Message deleted');
      expect(label, isNot(contains('Anna')));
      expect(
        deletedLabel(_message(groupRoom, _anna, redactor: _anna)),
        'Message deleted',
      );
    });

    test('a bridge bot removing a message names nobody', () {
      expect(
        deletedLabel(_message(groupRoom, _anna, redactor: _bot)),
        'Message deleted',
      );
    });

    test('disappearing and view-limited messages disappeared', () {
      expect(
        deletedLabel(
          _message(
            dm,
            _anna,
            redactor: _bot,
            redaction: {'reason': 'Message disappeared'},
          ),
        ),
        'Message disappeared',
      );
      expect(
        deletedLabel(
          _message(
            dm,
            _anna,
            redactor: _bot,
            redaction: {'com.beeper.view_limited': true},
          ),
        ),
        'Message disappeared',
      );
      // Only the bridge bot speaks for view-limited media.
      expect(
        deletedLabel(
          _message(
            dm,
            _anna,
            redactor: _anna,
            redaction: {'com.beeper.view_limited': true},
          ),
        ),
        'Message deleted',
      );
    });

    test('a group admin removing somebody else\'s message is named', () {
      expect(
        deletedLabel(_message(groupRoom, _anna, redactor: _bob)),
        'Deleted by Bob',
      );
      expect(
        deletionOf(_message(groupRoom, _anna, redactor: _bob)).kind,
        DeletedKind.byOther,
      );
    });

    test('a message being deleted here reads as own at once', () {
      final event = _message(dm, _owner, body: 'still here');
      MessageDeletions.debugMarkDeleting(event);
      expect(isDeletedForDisplay(event), isTrue);
      expect(deletedLabel(event), 'You deleted this message');
      final copy = deletedDisplayCopy(event);
      expect(copy.redacted, isTrue);
      expect(copy.content, isEmpty);
      expect(identical(deletedDisplayCopy(event), copy), isTrue);
      // The timeline's own object keeps its content (a failure brings it
      // back as it was).
      expect(event.redacted, isFalse);
      expect(event.body, 'still here');
    });

    test('the SDK fallback (MatrixLocals) uses the same words', () {
      final locals = MatrixLocals(englishL10n);
      final other = _message(dm, _anna, redactor: _anna);
      expect(locals.removedBy(other.redactedBecause!), 'Message deleted');
      final own = _message(dm, _owner, redactor: _owner);
      expect(
        own.calcLocalizedBodyFallback(locals),
        'You deleted this message',
      );
      expect(locals.redactedAnEvent(own.redactedBecause!), isNot(contains('redact')));
    });
  });

  group('previews', () {
    test('never the old text and never a "You: " prefix', () {
      final own = _message(dm, _owner, redactor: _owner);
      expect(personalEventPreview(own), 'You deleted this message');
      final other = _message(groupRoom, _anna, redactor: _anna);
      expect(personalEventPreview(other), 'Message deleted');
      expect(personalPreviewLabel(other), 'Message deleted');
      for (final event in [own, other]) {
        expect(personalEventPreview(event), isNot(contains('secret')));
      }
    });

    test('the inbox preview right after an own delete', () {
      final last = _message(dm, _owner, body: 'meet at 6');
      expect(personalEventPreview(last), 'You: meet at 6');
      MessageDeletions.debugMarkDeleting(last);
      expect(personalEventPreview(last), 'You deleted this message');
      expect(
        personalPreview(last, own: true, group: false),
        'You deleted this message',
      );
    });

    test('with deleted messages hidden, the message before stands in', () {
      final older = _message(dm, _anna, body: 'earlier');
      final reaction = Event(
        room: dm,
        eventId: r'$reaction',
        senderId: _anna,
        type: EventTypes.Reaction,
        originServerTs: DateTime.utc(2026, 10, 31, 12, 30),
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': older.eventId,
            'key': '👍',
          },
        },
      );
      final gone = _message(dm, _anna, redactor: _anna);
      final alsoGone = _message(dm, _owner, redactor: _owner);
      final previous = previousPreviewEvent(
        [gone, reaction, alsoGone, older],
        deletedId: gone.eventId,
        previewTypes: client.roomPreviewLastEvents,
      );
      expect(previous, same(older));
      expect(
        previousPreviewEvent(
          [gone, alsoGone],
          deletedId: gone.eventId,
          previewTypes: client.roomPreviewLastEvents,
        ),
        isNull,
      );
    });
  });

  group('visibility', () {
    test('placeholders show unless "Hide deleted messages" is on', () async {
      final kept = _message(dm, _anna);
      final deleted = _message(dm, _anna, redactor: _anna);
      final deleting = _message(dm, _owner);
      MessageDeletions.debugMarkDeleting(deleting);
      expect([kept, deleted, deleting].filterByVisibleInGui(), [
        kept,
        deleted,
        deleting,
      ]);
      await AppSettings.hideRedactedEvents.setItem(true);
      expect([kept, deleted, deleting].filterByVisibleInGui(), [kept]);
    });

    test('ChatLoom\'s own tidy-up deletions stay hidden', () {
      final undelivered = _message(dm, _owner, redactor: _owner);
      MessageDeletions.markQuietTarget(dm, undelivered.eventId);
      expect(undelivered.isVisibleInGui, isFalse);
      final quiet = _message(dm, _owner, redactor: _owner);
      MessageDeletions.markQuiet(dm, quiet.redactedBecause!.eventId);
      expect(quiet.isVisibleInGui, isFalse);
    });

    test('the merged conversation follows the same settings', () async {
      final message = _message(groupRoom, _anna);
      final deleted = _message(groupRoom, _anna, redactor: _anna);
      expect(mergedChatShowsRow(message), isTrue);
      expect(mergedChatShowsRow(deleted), isTrue);
      await AppSettings.hideRedactedEvents.setItem(true);
      expect(mergedChatShowsRow(deleted), isFalse);
      expect(mergedChatShowsRow(message), isTrue);
      final deleting = _message(groupRoom, _owner);
      MessageDeletions.debugMarkDeleting(deleting);
      expect(mergedChatShowsRow(deleting), isFalse);
      await AppSettings.hideRedactedEvents.setItem(false);
      expect(mergedChatShowsRow(deleting), isTrue);
    });
  });
}
