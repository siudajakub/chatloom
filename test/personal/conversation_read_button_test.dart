// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_read_button.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/read_targets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Client extends ConversationClient {
  @override
  Uri get baseUri => Uri.parse('https://fixture.invalid');
}

class _Room extends ConversationRoom {
  Event? latest;
  final receipts = <(String?, String?, bool?)>[];
  Completer<void>? gate;
  bool fail = false;

  _Room(super.client, super.id);

  @override
  Event? get lastEvent => latest;

  void incoming(String id) => latest = Event(
    room: this,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@fixture:example.invalid',
    originServerTs: DateTime.utc(2026, 10, 21),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
  );

  /// The user's own message that failed to send: the preview is a local echo.
  Event echo() => latest = Event(
    room: this,
    eventId: 'fixture-transaction',
    type: EventTypes.Message,
    senderId: client.userID!,
    status: EventStatus.error,
    originServerTs: DateTime.utc(2026, 10, 21, 0, 1),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
  );

  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async {
    receipts.add((eventId, mRead, public));
    if (fail) throw StateError('Offline fixture');
    await gate?.future;
  }
}

Future<void> _mount(
  WidgetTester tester,
  List<Room> rooms, {
  Iterable<Event> Function(Room room)? loaded,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: ConversationReadButton(rooms: rooms, loadedEvents: loaded),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _anna = '@fixture:example.invalid';
const _bot = '@whatsappbot:example.invalid';

Event _event(
  Room room,
  String id, {
  required String sender,
  required int minute,
  String type = EventTypes.Message,
  Map<String, Object?>? content,
  EventStatus status = EventStatus.synced,
}) => Event(
  room: room,
  eventId: id,
  type: type,
  senderId: sender,
  status: status,
  originServerTs: DateTime.utc(2026, 10, 21, 0, minute),
  content:
      content ?? {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
);

/// The bridge's delivery report about [eventId], as Beeper bridges send it.
Event _status(Room room, String id, String eventId, int minute) => _event(
  room,
  id,
  sender: _bot,
  minute: minute,
  type: 'com.beeper.message_send_status',
  content: {
    'status': 'SUCCESS',
    'm.relates_to': {
      'rel_type': RelationshipTypes.reference,
      'event_id': eventId,
    },
  },
);

Event _reaction(
  Room room,
  String id,
  String eventId, {
  required String sender,
  required int minute,
  EventStatus status = EventStatus.synced,
}) => _event(
  room,
  id,
  sender: sender,
  minute: minute,
  type: EventTypes.Reaction,
  status: status,
  content: {
    'm.relates_to': {
      'rel_type': RelationshipTypes.reaction,
      'event_id': eventId,
      'key': '👍',
    },
  },
);

LatestReceiptState _ownPublic(String eventId, int minute) => LatestReceiptState(
  global: LatestReceiptStateForTimeline(
    ownPrivate: null,
    ownPublic: LatestReceiptStateData(
      eventId,
      DateTime.utc(2026, 10, 21, 0, minute).millisecondsSinceEpoch,
    ),
    latestOwnReceipt: null,
    otherUsers: {},
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.personalIncognito.setItem(true);
    await AppSettings.sendPublicReadReceipts.setItem(false);
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });

  testWidgets('one tap sends a public receipt in incognito without a dialog', (
    tester,
  ) async {
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    room.gate = Completer<void>();
    await _mount(tester, [room]);
    final button = find.byType(ConversationReadButton);
    expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(room.receipts, [(r'$one', r'$one', true)]);
    expect(find.byType(Dialog), findsNothing);
    expect(AppSettings.personalIncognito.value, isTrue);
    expect(AppSettings.sendPublicReadReceipts.value, isFalse);
    room.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPill), findsNothing);
    // Automatic reads remain suppressed after the manual action.
    await PersonalPrivacy.markRead(room, r'$two', publicReceipt: true);
    expect(room.receipts, hasLength(1));
  });

  testWidgets('accepted reaction hides read button until another message', (
    tester,
  ) async {
    final client = _Client();
    final room = _Room(client, '!fixture:example.invalid')..incoming(r'$one');
    PersonalPrivacy.bind(client);
    PersonalPrivacy.observe(room, r'$one');
    final cutoff = client.captureOutgoingContext!(room, EventTypes.Reaction);
    await _mount(tester, [room]);
    expect(find.byType(NotionGlassPill), findsOneWidget);
    await client.onOutgoingAccepted!(room, r'$reaction', cutoff);
    await tester.pumpAndSettle();
    expect(room.receipts, [(r'$one', r'$one', false)]);
    expect(find.byType(NotionGlassPill), findsNothing);
    room.incoming(r'$two');
    await _mount(tester, [room]);
    expect(find.byType(NotionGlassPill), findsOneWidget);
    PersonalPrivacy.forget(client);
  });

  test(
    'queued sends keep original cutoff and legacy retries release none',
    () async {
      final client = _Client();
      final room = _Room(client, '!fixture:example.invalid')..incoming(r'$one');
      PersonalPrivacy.bind(client);
      PersonalPrivacy.observe(room, r'$one');
      final original = PersonalPrivacy.frozenReadCutoff(room);
      room.incoming(r'$two');
      PersonalPrivacy.observe(room, r'$two');
      for (final type in [
        EventTypes.Message,
        EventTypes.Sticker,
        EventTypes.Reaction,
      ]) {
        final captured = await PersonalPrivacy.withFrozenRoundReadCutoff(
          room,
          original,
          () async => client.captureOutgoingContext!(room, type),
        );
        await client.onOutgoingAccepted!(room, r'$sent', captured);
        expect(room.receipts.last.$1, r'$one');
        expect(PersonalPrivacy.hasUnread(room), isTrue);
      }
      final legacy = await PersonalPrivacy.withFrozenRoundReadCutoff(
        room,
        null,
        () async => client.captureOutgoingContext!(room, EventTypes.Message),
      );
      final before = room.receipts.length;
      await client.onOutgoingAccepted!(room, r'$legacy', legacy);
      expect(room.receipts, hasLength(before));
      expect(
        client.captureOutgoingContext!(room, EventTypes.Redaction),
        isNull,
      );
      PersonalPrivacy.forget(client);
    },
  );

  test(
    'read and observed cutoffs stay isolated between account clients',
    () async {
      final first = _Room(_Client(), '!shared:example.invalid')
        ..incoming(r'$one');
      final second = _Room(_Client(), '!shared:example.invalid')
        ..incoming(r'$one');
      PersonalPrivacy.observe(first, r'$one');
      expect(PersonalPrivacy.frozenReadCutoff(second), isNull);
      await PersonalPrivacy.markRead(first, r'$one', manual: true);
      expect(PersonalPrivacy.hasUnread(first), isFalse);
      expect(PersonalPrivacy.hasUnread(second), isTrue);
      PersonalPrivacy.forget(first.client);
      PersonalPrivacy.forget(second.client);
    },
  );

  testWidgets('merged sources freeze cutoffs and a partial failure can retry', (
    tester,
  ) async {
    final client = _Client();
    final a = _Room(client, '!a:example.invalid')..incoming(r'$a');
    final b = _Room(client, '!b:example.invalid')..incoming(r'$b');
    a.gate = Completer<void>();
    b.fail = true;
    await _mount(tester, [a, b]);
    await tester.tap(find.byType(ConversationReadButton));
    await tester.pump();
    b.incoming(r'$new');
    expect(b.receipts, [(r'$b', r'$b', true)]);
    a.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t mark as read.'), findsOneWidget);

    // The snackbar's Retry runs the same explicit read (CS-13).
    b.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(b.receipts.last, (r'$new', r'$new', true));
  });

  testWidgets('a pending own message as the preview marks the newest server '
      'event of the loaded timeline; a source with nothing to mark is '
      'skipped, not an error', (tester) async {
    final client = _Client();
    final a = _Room(client, '!a:example.invalid')..incoming(r'$loaded');
    final loaded = a.latest!;
    final echo = a.echo();
    final b = _Room(client, '!b:example.invalid');
    await _mount(tester, [
      a,
      b,
    ], loaded: (room) => room == a ? [echo, loaded] : const []);
    await tester.tap(find.byType(ConversationReadButton));
    await tester.pumpAndSettle();
    expect(a.receipts, [(r'$loaded', r'$loaded', true)]);
    expect(b.receipts, isEmpty);
    expect(
      find.text('Could not mark all messages as read. Tap to retry.'),
      findsNothing,
    );
  });

  test('public override requires an explicit manual action', () async {
    await AppSettings.personalIncognito.setItem(false);
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    await PersonalPrivacy.markRead(room, r'$one', publicReceipt: true);
    expect(room.receipts, [(r'$one', r'$one', false)]);
  });

  testWidgets('locked or background surfaces cannot send receipts', (
    tester,
  ) async {
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    await _mount(tester, [room]);
    PersonalPrivacy.surfaceUnlocked = false;
    await tester.tap(find.byType(ConversationReadButton));
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = false;
    await tester.tap(find.byType(ConversationReadButton));
    expect(room.receipts, isEmpty);
    PersonalPrivacy.surfaceForeground = true;
  });

  group('visibility follows the actual unread state', () {
    test('own message followed by the bridge delivery report is read', () {
      final room = _Room(_Client(), '!fixture:example.invalid');
      final own = room.client.userID!;
      final loaded = [
        _status(room, r'$status', r'$mine', 3),
        _event(room, r'$mine', sender: own, minute: 2),
        _event(room, r'$theirs', sender: _anna, minute: 1),
      ];
      room.latest = loaded[1];
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);
      expect(
        conversationNeedsPublicRead([room], loaded: (_) => loaded),
        isFalse,
      );
    });

    test('own reaction reads at once, also while it is still sending, and '
        'a newer message from someone else is unread again', () {
      final room = _Room(_Client(), '!fixture:example.invalid');
      final own = room.client.userID!;
      final theirs = _event(room, r'$theirs', sender: _anna, minute: 1);
      room.latest = theirs;
      final loaded = <Event>[theirs];
      expect(conversationSourceUnread(room, loaded: loaded), isTrue);

      // The local echo of the reaction, before the server confirmed it.
      loaded.insert(
        0,
        Event(
          room: room,
          eventId: 'fixture-transaction',
          type: EventTypes.Reaction,
          senderId: own,
          status: EventStatus.sending,
          originServerTs: DateTime.now(),
          content: {
            'm.relates_to': {
              'rel_type': RelationshipTypes.reaction,
              'event_id': r'$theirs',
              'key': '👍',
            },
          },
        ),
      );
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);

      loaded
        ..removeAt(0)
        ..insertAll(0, [
          _status(room, r'$status', r'$reaction', 3),
          _reaction(room, r'$reaction', r'$theirs', sender: own, minute: 2),
        ]);
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);

      final next = _event(room, r'$next', sender: _anna, minute: 4);
      loaded.insert(0, next);
      room.latest = next;
      expect(conversationSourceUnread(room, loaded: loaded), isTrue);
    });

    test('a failed own send reads nothing', () {
      final room = _Room(_Client(), '!fixture:example.invalid')
        ..incoming(r'$one');
      final incoming = room.latest!;
      final echo = room.echo();
      expect(conversationSourceUnread(room, loaded: [echo, incoming]), isTrue);
    });

    test('reactions, edits and reports from others are not unread', () {
      final room = _Room(_Client(), '!fixture:example.invalid');
      final own = room.client.userID!;
      final loaded = [
        _status(room, r'$status', r'$mine', 5),
        _event(
          room,
          r'$edit',
          sender: _anna,
          minute: 4,
          content: {
            'msgtype': MessageTypes.Text,
            'body': '* Fictional edit',
            'm.new_content': {
              'msgtype': MessageTypes.Text,
              'body': 'Fictional edit',
            },
            'm.relates_to': {
              'rel_type': RelationshipTypes.edit,
              'event_id': r'$old',
            },
          },
        ),
        _reaction(room, r'$their-reaction', r'$mine', sender: _anna, minute: 3),
        _event(room, r'$mine', sender: own, minute: 2),
        _event(room, r'$old', sender: _anna, minute: 1),
      ];
      room.latest = loaded[3];
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);
    });

    test('a reaction the server counts stays unread until a marker reaches '
        'it', () {
      final room = _Room(_Client(), '!fixture:example.invalid');
      final own = room.client.userID!;
      final mine = _event(room, r'$mine', sender: own, minute: 2);
      final loaded = [
        _reaction(room, r'$their-reaction', r'$mine', sender: _anna, minute: 3),
        mine,
        _event(room, r'$old', sender: _anna, minute: 1),
      ];
      room.latest = mine;
      room.notificationCount = 1;
      expect(conversationSourceUnread(room, loaded: loaded), isTrue);
      // The button marks the reaction, not the preview.
      expect(
        conversationReadTarget(room, loaded: loaded)?.eventId,
        r'$their-reaction',
      );
      // A receipt on the user's own message does not reach the reaction.
      room.receiptState = _ownPublic(r'$mine', 2);
      expect(conversationSourceUnread(room, loaded: loaded), isTrue);
      room.receiptState = _ownPublic(r'$their-reaction', 3);
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);
    });

    test('a receipt at or after the newest message reads it; an older one '
        'does not', () {
      final room = _Room(_Client(), '!fixture:example.invalid');
      final theirs = _event(room, r'$theirs', sender: _anna, minute: 2);
      final loaded = [
        _status(room, r'$status', r'$theirs', 3),
        theirs,
        _event(room, r'$older', sender: _anna, minute: 1),
      ];
      room.latest = theirs;
      room.receiptState = _ownPublic(r'$older', 1);
      expect(conversationSourceUnread(room, loaded: loaded), isTrue);
      // Read on another device; the receipt points past the message.
      room.receiptState = _ownPublic(r'$status', 3);
      expect(conversationSourceUnread(room, loaded: loaded), isFalse);
      // Only the preview is known: the receipt time decides.
      expect(conversationSourceUnread(room), isFalse);
      room.receiptState = _ownPublic(r'$unknown', 1);
      expect(conversationSourceUnread(room), isTrue);
    });

    test('the fully read marker reads the conversation', () {
      final room = _Room(_Client(), '!fixture:example.invalid')
        ..incoming(r'$one');
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$one'},
      );
      expect(conversationSourceUnread(room), isFalse);
    });
  });

  testWidgets('the button hides once the own reaction syncs, though the '
      'bridge reports on it afterwards', (tester) async {
    final client = _Client();
    final room = _Room(client, '!fixture:example.invalid')..incoming(r'$one');
    final loaded = <Event>[room.latest!];
    await _mount(tester, [room], loaded: (_) => loaded);
    expect(find.byType(NotionGlassPill), findsOneWidget);

    loaded.insertAll(0, [
      _status(room, r'$status', r'$reaction', 2),
      _reaction(room, r'$reaction', r'$one', sender: client.userID, minute: 1),
    ]);
    client.onSync.add(
      SyncUpdate(
        nextBatch: '',
        rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPill), findsNothing);
  });

  testWidgets('a merged conversation stays unread while another source is', (
    tester,
  ) async {
    final client = _Client();
    final a = _Room(client, '!a:example.invalid')..incoming(r'$a');
    final b = _Room(client, '!b:example.invalid')..incoming(r'$b');
    final reply = _event(a, r'$reply', sender: client.userID, minute: 5);
    a.latest = reply;
    await _mount(tester, [a, b]);
    expect(find.byType(NotionGlassPill), findsOneWidget);
    b.latest = _event(b, r'$b-reply', sender: client.userID, minute: 6);
    await _mount(tester, [a, b]);
    expect(find.byType(NotionGlassPill), findsNothing);
  });
}
