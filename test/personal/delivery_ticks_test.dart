// SPDX-License-Identifier: AGPL-3.0-or-later
// Delivery ticks (UX-07): the pure rule, receipt targets and positions, the
// room-level listenable, the inbox ledger and the bubble footer.
// Fictional offline fixtures only; no accounts, network or storage.

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

const _bot = '@whatsappbot:example.invalid';
const _anna = '@anna:example.invalid';

class _Db extends ConversationDatabase {
  List<Event> stored = const [];
  int reads = 0;
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async {
    reads++;
    return stored.take(limit ?? stored.length).toList();
  }
}

class _Client extends Client {
  _Client(_Db db) : super('offline ticks fixture', database: db);
  @override
  String get userID => '@owner:example.invalid';
}

ConversationRoom _bridged(
  Client client, [
  String id = '!ticks:example.invalid',
]) => ConversationRoom(client, id)
  ..state('m.bridge', {
    'protocol': {'id': 'whatsapp'},
    'bridgebot': _bot,
  }, key: 'fixture');

Event _status(Room room, String target, String status, {int second = 1}) =>
    Event(
      room: room,
      eventId: '\$status-$target-$second',
      type: beeperMessageSendStatusType,
      senderId: _bot,
      originServerTs: DateTime.utc(2026, 10, 22, 12, 0, second),
      content: {
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': target},
        'status': status,
      },
    );

void _receipt(Room room, String user, String eventId, {int ts = 1}) =>
    room.receiptState.global.otherUsers[user] = LatestReceiptStateData(
      eventId,
      ts,
    );

Timeline _timeline(ConversationRoom room, [List<Event> extra = const []]) =>
    Timeline(
      room: room,
      chunk: TimelineChunk(events: [...extra, ...room.sourceEvents]),
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('rule', () {
    test('failure, sending, read, delivered, sent — in that order', () {
      final success = BridgeSendStatus(
        status: 'SUCCESS',
        at: DateTime.utc(2026),
      );
      final failure = BridgeSendStatus(
        status: 'FAIL_PERMANENT',
        at: DateTime.utc(2026),
      );
      DeliveryProgress of({
        bool own = true,
        EventStatus status = EventStatus.synced,
        BridgeSendStatus? bridge,
        bool network = false,
        bool ack = false,
        bool read = false,
      }) => resolveDeliveryProgress(
        own: own,
        status: status,
        bridge: bridge,
        fromNetwork: network,
        deliveryReceipt: ack,
        read: read,
      );
      expect(of(own: false, read: true), DeliveryProgress.none);
      expect(
        of(status: EventStatus.error, read: true),
        DeliveryProgress.failed,
      );
      expect(of(bridge: failure, read: true), DeliveryProgress.failed);
      expect(of(status: EventStatus.sending), DeliveryProgress.sending);
      expect(of(read: true, bridge: success), DeliveryProgress.read);
      expect(of(bridge: success), DeliveryProgress.delivered);
      expect(of(ack: true), DeliveryProgress.delivered);
      expect(of(network: true), DeliveryProgress.delivered);
      expect(
        of(
          bridge: BridgeSendStatus(status: 'PENDING', at: DateTime.utc(2026)),
        ),
        DeliveryProgress.sent,
      );
      expect(of(status: EventStatus.sent), DeliveryProgress.sent);
      expect(DeliveryProgress.failed.tick, isNull);
      expect(DeliveryProgress.none.tick, isNull);
      expect(DeliveryProgress.read.tick, NotionDeliveryState.read);
    });

    test('a bubble reads delivery from its trusted bridge report', () {
      final client = ConversationClient();
      final room = _bridged(client);
      final own = room.message(r'$own', 'Hi', outgoing: true);
      expect(
        messageDeliveryProgress(own, _timeline(room)),
        DeliveryProgress.sent,
      );
      expect(
        messageDeliveryProgress(
          own,
          _timeline(room, [_status(room, r'$own', 'SUCCESS')]),
        ),
        DeliveryProgress.delivered,
      );
      // Only the declared bot may report.
      final forged = Event(
        room: room,
        eventId: r'$forged',
        type: beeperMessageSendStatusType,
        senderId: _anna,
        originServerTs: DateTime.utc(2026, 10, 22),
        content: {
          'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$own'},
          'status': 'SUCCESS',
        },
      );
      expect(
        messageDeliveryProgress(own, _timeline(room, [forged])),
        DeliveryProgress.sent,
      );
      // Written in the network's own app: on the network already.
      final puppet = room.message(
        r'$puppet',
        'From the phone',
        outgoing: true,
        content: {
          'msgtype': MessageTypes.Text,
          'body': 'From the phone',
          doublePuppetSourceKey: 'mautrix-whatsapp',
        },
      );
      expect(
        messageDeliveryProgress(puppet, _timeline(room)),
        DeliveryProgress.delivered,
      );
      final incoming = room.message(r'$in', 'Hello');
      expect(
        messageDeliveryProgress(incoming, _timeline(room)),
        DeliveryProgress.none,
      );
    });
  });

  group('receipts', () {
    test('readers exclude the account and the bridge bot', () {
      final client = ConversationClient();
      final room = _bridged(client);
      _receipt(room, client.userID, r'$a');
      _receipt(room, _bot, r'$b');
      _receipt(room, _anna, r'$c', ts: 5);
      final targets = ReceiptTargets.of(room);
      expect(targets.read, {r'$c'});
      expect(targets.acknowledged, {r'$b'});
      expect(targets.newestRead, DateTime.fromMillisecondsSinceEpoch(5));
      expect(ReceiptTargets.of(room), targets);
    });

    test('a receipt on a later event reads every earlier own message', () {
      final client = ConversationClient();
      final room = _bridged(client);
      final first = room.message(r'$1', 'One', outgoing: true, minute: 1);
      final second = room.message(r'$2', 'Two', outgoing: true, minute: 2);
      room.message(r'$3', 'Reply', minute: 3);
      final fourth = room.message(r'$4', 'Three', outgoing: true, minute: 4);
      final events = _timeline(room).events;
      final readSecond = ReceiptSnapshot.of(
        events,
        ReceiptTargets(read: {r'$2'}),
        ownUserId: client.userID,
      );
      expect(readSecond.isRead(first), isTrue);
      expect(readSecond.isRead(second), isTrue);
      expect(readSecond.isRead(fourth), isFalse);
      final readReply = ReceiptSnapshot.of(
        events,
        ReceiptTargets(read: {r'$3'}, acknowledged: {r'$4'}),
        ownUserId: client.userID,
      );
      expect(readReply.isRead(second), isTrue);
      expect(readReply.isRead(fourth), isFalse);
      expect(readReply.isAcknowledged(fourth), isTrue);
      expect(readReply.isAcknowledged(first), isTrue);
      // A receipt on an event outside the loaded live window says nothing.
      final unknown = ReceiptSnapshot.of(
        events,
        ReceiptTargets(read: {r'$older'}, newestRead: DateTime.utc(2030)),
        ownUserId: client.userID,
      );
      expect(unknown.isRead(first), isFalse);
      // In an older window (a jump into history) a newer receipt reads all.
      final history = ReceiptSnapshot.of(
        events,
        ReceiptTargets(read: {r'$newer'}, newestRead: DateTime.utc(2030)),
        ownUserId: client.userID,
        live: false,
      );
      expect(history.isRead(fourth), isTrue);
    });

    test('own ghosts never count as readers', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!ghost:example.invalid');
      const bot = '@telegrambot:bridge.invalid';
      for (final (type, key, content)
          in <(String, String, Map<String, dynamic>)>[
            (
              'm.bridge',
              'fixture',
              {
                'bridgebot': bot,
                'protocol': {'id': 'telegram'},
                'channel': {'id': '200', 'fi.mau.receiver': '100'},
                'com.beeper.room_type.v2': 'dm',
              },
            ),
            (EventTypes.RoomMember, bot, {'membership': 'join'}),
          ]) {
        room.setState(
          Event(
            room: room,
            type: type,
            stateKey: key,
            eventId: '\$state-$type-$key',
            senderId: bot,
            originServerTs: DateTime.utc(2026),
            content: content,
          ),
        );
      }
      OwnSenderResolver.invalidate(client);
      _receipt(room, '@telegram_100:bridge.invalid', r'$x');
      expect(ReceiptTargets.of(room).read, isEmpty);
      // A message of the user's own ghost came from the network.
      final ghost = Event(
        room: room,
        eventId: r'$ghost',
        type: EventTypes.Message,
        senderId: '@telegram_100:bridge.invalid',
        originServerTs: DateTime.utc(2026, 10, 22),
        content: {'msgtype': MessageTypes.Text, 'body': 'From the app'},
      );
      expect(inboxDeliveryProgress(room, ghost), DeliveryProgress.delivered);
    });

    test('the room listenable notifies only when others moved', () async {
      final client = ConversationClient();
      final room = _bridged(client);
      room.message(r'$1', 'One', outgoing: true);
      final receipts = RoomReadReceipts.of(room);
      expect(identical(receipts, RoomReadReceipts.of(room)), isTrue);
      var calls = 0;
      void listener() => calls++;
      receipts.addListener(listener);
      SyncUpdate receiptSync() => SyncUpdate(
        nextBatch: 'fixture',
        rooms: RoomsUpdate(
          join: {
            room.id: JoinedRoomUpdate(
              ephemeral: [BasicEvent(type: 'm.receipt', content: {})],
            ),
          },
        ),
      );
      // The account's own receipt: nothing moved for the ticks.
      room.receiptState.global.ownPublic = LatestReceiptStateData(r'$1', 1);
      client.onSync.add(receiptSync());
      await pumpEventQueue();
      expect(calls, 0);
      _receipt(room, _anna, r'$1');
      client.onSync.add(receiptSync());
      await pumpEventQueue();
      expect(calls, 1);
      // The same receipt again (servers repeat): no notification.
      client.onSync.add(receiptSync());
      await pumpEventQueue();
      expect(calls, 1);
      final timeline = _timeline(room);
      final snapshot = receipts.snapshotOf(timeline);
      expect(identical(receipts.snapshotOf(timeline), snapshot), isTrue);
      expect(snapshot.isRead(room.sourceEvents.first), isTrue);
      receipts.removeListener(listener);
      // Without listeners nothing is cached or subscribed.
      _receipt(room, _anna, r'$none');
      expect(
        receipts.snapshotOf(timeline).isRead(room.sourceEvents.first),
        isFalse,
      );
    });
  });

  group('inbox ledger', () {
    test('live reports from the bot only; the newest wins', () async {
      final db = _Db();
      final client = _Client(db);
      final room = _bridged(client);
      final own = room.message(r'$own', 'Hi', outgoing: true);
      final ledger = BridgeDeliveryLedger.of(client);
      final changes = <String>[];
      final sub = ledger.changes.listen(changes.add);
      addTearDown(sub.cancel);
      expect(inboxDeliveryProgress(room, own), DeliveryProgress.sent);
      client.onTimelineEvent.add(_status(room, r'$own', 'SUCCESS', second: 5));
      await pumpEventQueue();
      expect(changes, [room.id]);
      expect(inboxDeliveryProgress(room, own), DeliveryProgress.delivered);
      // An older report arriving late changes nothing.
      expect(
        ledger.record(_status(room, r'$own', 'PENDING', second: 2)),
        isFalse,
      );
      expect(ledger.statusOf(r'$own')?.status, 'SUCCESS');
      _receipt(room, _anna, r'$own');
      expect(inboxDeliveryProgress(room, own), DeliveryProgress.read);
      final incoming = room.message(r'$in', 'Hello');
      expect(inboxDeliveryProgress(room, incoming), DeliveryProgress.none);
    });

    test(
      'a missing report is looked up once in the newest stored events',
      () async {
        final db = _Db();
        final client = _Client(db);
        final room = _bridged(client, '!lookup:example.invalid');
        final own = room.message(r'$old', 'Before restart', outgoing: true);
        db.stored = [_status(room, r'$old', 'SUCCESS'), own];
        final ledger = BridgeDeliveryLedger.of(client);
        final changes = <String>[];
        final sub = ledger.changes.listen(changes.add);
        addTearDown(sub.cancel);
        ledger.lookUp(room, own);
        ledger.lookUp(room, own);
        await pumpEventQueue();
        expect(db.reads, 1);
        expect(changes, [room.id]);
        expect(inboxDeliveryProgress(room, own), DeliveryProgress.delivered);
        // Known now: no further look-up.
        ledger.lookUp(room, own);
        await pumpEventQueue();
        expect(db.reads, 1);
        // Unbridged rooms and unsent messages never look.
        final plain = ConversationRoom(client, '!plain:example.invalid');
        ledger.lookUp(plain, plain.message(r'$p', 'Matrix', outgoing: true));
        ledger.lookUp(
          room,
          room.message(
            r'$s',
            'Sending',
            outgoing: true,
            status: EventStatus.sending,
          ),
        );
        await pumpEventQueue();
        expect(db.reads, 1);
      },
    );
  });

  group('bubble footer', () {
    Future<void> mount(WidgetTester tester, Client client, Widget home) async {
      final matrix = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            theme: NotionTheme.build(Brightness.dark),
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Widget message(Event event, Timeline timeline) => Scaffold(
      body: Center(
        child: Message(
          event,
          bigEmojis: const {},
          onInfoTab: (_) {},
          scrollToEventId: (_) {},
          onSwipe: () {},
          timeline: timeline,
          onMention: () {},
          scrollController: ScrollController(),
          enterThread: null,
        ),
      ),
    );

    NotionDeliveryState tick(WidgetTester tester) => tester
        .widget<NotionDeliveryTick>(find.byType(NotionDeliveryTick))
        .state;

    testWidgets('sent → delivered → read beside the time', (tester) async {
      final client = ConversationClient();
      final room = _bridged(client);
      final own = room.message(r'$own', 'On its way', outgoing: true);
      final timeline = _timeline(room);
      addTearDown(timeline.cancelSubscriptions);
      await mount(tester, client, message(own, timeline));
      expect(tick(tester), NotionDeliveryState.sent);
      expect(find.bySemanticsLabel('Sent'), findsOneWidget);

      final delivered = _timeline(room, [_status(room, r'$own', 'SUCCESS')]);
      addTearDown(delivered.cancelSubscriptions);
      await mount(tester, client, message(own, delivered));
      expect(tick(tester), NotionDeliveryState.delivered);

      // A receipt updates only the ticks through the room listenable.
      _receipt(room, _anna, r'$own');
      RoomReadReceipts.of(room).refresh();
      await tester.pumpAndSettle();
      expect(tick(tester), NotionDeliveryState.read);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(NotionDeliveryTick),
          matching: find.byType(Icon),
        ),
      );
      final accent = tester
          .element(find.byType(NotionDeliveryTick))
          .notion
          .colors
          .accent;
      expect(
        icon.color,
        NotionContrast.readable(
          tester.element(find.byType(Message)).notion.colors.background,
          accent,
          minimum: 3,
        ),
      );
    });

    testWidgets('a bridge bot delivery receipt is two grey ticks', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = _bridged(client);
      final own = room.message(r'$own', 'Acked', outgoing: true);
      _receipt(room, _bot, r'$own');
      final timeline = _timeline(room);
      addTearDown(timeline.cancelSubscriptions);
      await mount(tester, client, message(own, timeline));
      expect(tick(tester), NotionDeliveryState.delivered);
    });

    testWidgets('no ticks on incoming or failed messages', (tester) async {
      final client = ConversationClient();
      final room = _bridged(client);
      final incoming = room.message(r'$in', 'Hello');
      _receipt(room, _anna, r'$in');
      var timeline = _timeline(room);
      await mount(tester, client, message(incoming, timeline));
      expect(find.byType(NotionDeliveryTick), findsNothing);
      timeline.cancelSubscriptions();

      final failed = room.message(
        r'$failed',
        'Rejected',
        outgoing: true,
        minute: 41,
      );
      timeline = _timeline(room, [_status(room, r'$failed', 'FAIL_PERMANENT')]);
      await mount(tester, client, message(failed, timeline));
      expect(find.byType(NotionDeliveryTick), findsNothing);
      expect(find.textContaining('Not delivered'), findsOneWidget);
      timeline.cancelSubscriptions();

      timeline.cancelSubscriptions();
    });

    testWidgets('the clock of a sending message turns into the ✓ in place', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = _bridged(client);
      final sending = room.message(
        'txn-1',
        'Wait',
        outgoing: true,
        minute: 42,
        status: EventStatus.sending,
      );
      var timeline = _timeline(room);
      await mount(tester, client, message(sending, timeline));
      await tester.pump(const Duration(seconds: 1));
      expect(tick(tester), NotionDeliveryState.sending);
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      final l10n = L10n.of(tester.element(find.byType(Message)));
      expect(find.text(l10n.sending), findsOneWidget);
      final switcher = tester.state(
        find.descendant(
          of: find.byType(NotionDeliveryTick),
          matching: find.byType(NotionLazySwitcher),
        ),
      );
      timeline.cancelSubscriptions();

      // The server has it: same slot, the ✓ grows in, "Sending…" folds.
      final sent = room.message(
        'txn-1',
        'Wait',
        outgoing: true,
        minute: 42,
        status: EventStatus.sent,
      );
      timeline = _timeline(room);
      addTearDown(timeline.cancelSubscriptions);
      final before = NotionLazySwitcher.debugControllers;
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(
            client,
            await SharedPreferences.getInstance(),
          ),
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            theme: NotionTheme.build(Brightness.dark),
            home: message(sent, timeline),
          ),
        ),
      );
      expect(NotionLazySwitcher.debugControllers, greaterThan(before));
      expect(
        tester.state(
          find.descendant(
            of: find.byType(NotionDeliveryTick),
            matching: find.byType(NotionLazySwitcher),
          ),
        ),
        same(switcher),
      );
      await tester.pumpAndSettle();
      expect(tick(tester), NotionDeliveryState.sent);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.text(l10n.sending), findsNothing);
    });
  });

  group('inbox row', () {
    Widget row(NotionDeliveryState? delivery) => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: NotionInboxRow(
          avatar: const SizedBox.shrink(),
          name: 'Anna',
          preview: 'You: See you',
          time: '12:30',
          delivery: delivery,
          onTap: () {},
        ),
      ),
    );

    testWidgets('ticks sit before the time and are announced', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(row(NotionDeliveryState.read));
      final tick = find.byKey(const ValueKey('notion_inbox_delivery'));
      expect(tick, findsOneWidget);
      expect(
        tester.getTopRight(tick).dx,
        lessThanOrEqualTo(tester.getTopLeft(find.text('12:30')).dx),
      );
      final icon = tester.widget<Icon>(
        find.descendant(of: tick, matching: find.byType(Icon)),
      );
      expect(icon.icon, Icons.done_all);
      expect(icon.color, tester.element(tick).notion.colors.accent);
      expect(
        find.bySemanticsLabel(RegExp('Last message read')),
        findsOneWidget,
      );

      await tester.pumpWidget(row(NotionDeliveryState.sent));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: tick, matching: find.byType(Icon)),
            )
            .icon,
        Icons.done,
      );

      await tester.pumpWidget(row(null));
      expect(tick, findsNothing);
      semantics.dispose();
    });
  });
}
