// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/chat_list_body.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

class _Client extends ConversationClient {
  _Client([String owner = '@owner:example.invalid']) : super(owner);
  @override
  String get prevBatch => 'fictional cursor';
}

class _Room extends ConversationRoom {
  _Room(super.client, super.id);
  int count = 0;
  @override
  Event? get lastEvent => sourceEvents.firstOrNull;
  @override
  int get notificationCount => count;
}

class _Inbox extends ChatList {
  const _Inbox({super.key}) : super(activeChat: null);
  @override
  ChatListController createState() => _Controller();
}

class _Controller extends ChatListController {
  @override
  // Native plugins are outside this offline subscription regression.
  // ignore: must_call_super
  void initState() {
    activeFilter = ActiveFilter.allChats;
  }

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(body: ChatListViewBody(this));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets(
    'inbox retains subscriptions across parent builds and rebinds accounts',
    (tester) async {
      final a = _Client();
      final b = _Client('@other:example.invalid');
      final matrix = ConversationMatrix(a, AppSettings.store);
      addTearDown(() => PersonalClient.of(a).dispose());
      addTearDown(() => PersonalClient.of(b).dispose());
      final key = GlobalKey<ChatListController>();
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: _Inbox(key: key),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller = key.currentState! as _Controller;
      final first = controller.inbox;
      controller.rebuild();
      await tester.pump();
      expect(controller.inbox, same(first));
      matrix.active = b;
      controller.rebuild();
      await tester.pump();
      expect(controller.inbox, isNot(same(first)));
      expect(controller.inbox.client, same(b));
      expect(first.detached, isTrue);
      final second = controller.inbox;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(second.detached, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared row projections refresh private names and synced previews',
    (tester) async {
      final client = _Client();
      final room = _Room(client, '!fixture:example.invalid');
      room.message(r'$before', 'Before sync');
      final personal = PersonalClient.of(client);
      addTearDown(personal.dispose);
      final matrix = ConversationMatrix(client, AppSettings.store);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const _Inbox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      NotionInboxRow row() =>
          tester.widget<NotionInboxRow>(find.byType(NotionInboxRow));
      expect(row().preview, contains('Before sync'));
      personal.values['org:${room.id}'] = {'nickname': 'Updated private name'};
      personal.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(row().name, 'Updated private name');
      room.message(r'$after', 'After sync', minute: 41);
      room.count = 3;
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'fixture-next',
          rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(row().preview, contains('After sync'));
      expect(row().unreadCount, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  Future<_Controller> mountInbox(
    WidgetTester tester,
    _Client client, {
    GlobalKey<NavigatorState>? navigator,
  }) async {
    final key = GlobalKey<ChatListController>();
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(client, AppSettings.store),
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: _Inbox(key: key),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState! as _Controller;
  }

  void sync(_Client client, Iterable<String> roomIds) => client.onSync.add(
    SyncUpdate(
      nextBatch: 'fixture-next',
      rooms: RoomsUpdate(
        join: {for (final id in roomIds) id: JoinedRoomUpdate()},
      ),
    ),
  );

  testWidgets(
    'rebuild budget: sync status ticks without room changes rebuild nothing',
    (tester) async {
      final client = _Client();
      _Room(client, '!fixture:example.invalid').message(r'$a', 'Stable');
      addTearDown(PersonalClient.of(client).dispose);
      final controller = await mountInbox(tester, client);
      final inbox = controller.inbox;
      NotionInboxRow row() =>
          tester.widget<NotionInboxRow>(find.byType(NotionInboxRow));
      final before = row();
      final generation = inbox.generation;
      final builds = inbox.debugFullBuilds;
      final classified = ConversationClassifier.debugComputations;
      for (var i = 0; i < 5; i++) {
        for (final status in [
          SyncStatus.waitingForResponse,
          SyncStatus.processing,
          SyncStatus.cleaningUp,
          SyncStatus.finished,
        ]) {
          client.onSyncStatus.add(SyncStatusUpdate(status));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }
      await tester.pump(const Duration(seconds: 2));
      expect(row(), same(before), reason: 'rows were rebuilt');
      expect(inbox.generation, generation);
      expect(inbox.debugFullBuilds, builds);
      expect(ConversationClassifier.debugComputations, classified);

      // Only error/recovered transitions republish (offline banner). The
      // notice waits out a short blip (the SDK retries after 3 s).
      client.onSyncStatus.add(
        SyncStatusUpdate(
          SyncStatus.error,
          error: SdkError(exception: Exception('fixture offline')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Showing loaded chats'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Showing loaded chats'), findsOneWidget);
      client.onSyncStatus.add(
        SyncStatusUpdate(
          SyncStatus.error,
          error: SdkError(exception: Exception('fixture offline')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(inbox.generation, generation + 1);
      client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
      await tester.pump(const Duration(milliseconds: 300));
      // The offline notice collapses instead of vanishing in one frame.
      await tester.pump(NotionMotion.medium);
      expect(find.textContaining('Showing loaded chats'), findsNothing);
      expect(inbox.debugFullBuilds, builds);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'a sync for one room updates that record only and coalesces bursts',
    (tester) async {
      final client = _Client();
      final first = _Room(client, '!first:example.invalid')
        ..message(r'$1', 'First chat', minute: 10);
      final second = _Room(client, '!second:example.invalid')
        ..message(r'$2', 'Second chat', minute: 20);
      addTearDown(PersonalClient.of(client).dispose);
      final controller = await mountInbox(tester, client);
      final inbox = controller.inbox;
      final builds = inbox.debugFullBuilds;
      final classified = ConversationClassifier.debugComputations;
      first.message(r'$3', 'First is newest', minute: 30);
      // Let start-up notifications (private client loading) settle first.
      for (var i = 0, last = -1; i < 20 && last != inbox.generation; i++) {
        last = inbox.generation;
        await tester.pump(const Duration(milliseconds: 300));
      }
      // A quiet inbox shows the first change without the debounce delay
      // (next event-loop turn); the rest of the burst is coalesced into one
      // more update.
      final updates = inbox.debugIncrementalUpdates;
      sync(client, [first.id]);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(inbox.debugIncrementalUpdates, updates + 1, reason: 'at once');
      expect(
        tester
            .widgetList<NotionInboxRow>(find.byType(NotionInboxRow))
            .first
            .preview,
        contains('First is newest'),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        sync(client, [first.id]);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(inbox.debugIncrementalUpdates, updates + 1, reason: 'coalescing');
      await tester.pump(const Duration(milliseconds: 300));
      expect(inbox.debugIncrementalUpdates, updates + 2, reason: 'coalesced');
      expect(inbox.debugFullBuilds, builds);
      expect(ConversationClassifier.debugComputations, classified);
      final previews = tester
          .widgetList<NotionInboxRow>(find.byType(NotionInboxRow))
          .map((row) => row.preview)
          .toList();
      expect(previews.first, contains('First is newest'));
      expect(previews.last, contains('Second chat'));
      expect(second.id, isNot(first.id));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('a covered inbox defers work and refreshes once on return', (
    tester,
  ) async {
    final client = _Client();
    final room = _Room(client, '!fixture:example.invalid')
      ..message(r'$a', 'Before chat');
    addTearDown(PersonalClient.of(client).dispose);
    final navigator = GlobalKey<NavigatorState>();
    final controller = await mountInbox(tester, client, navigator: navigator);
    final inbox = controller.inbox;
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(inbox.active, isFalse);
    final generation = inbox.generation;
    room.message(r'$b', 'While covered', minute: 45);
    for (var i = 0; i < 3; i++) {
      sync(client, [room.id]);
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(inbox.generation, generation);
    expect(inbox.debugIncrementalUpdates, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(inbox.active, isTrue);
    expect(inbox.generation, generation + 1);
    expect(inbox.debugIncrementalUpdates, 1);
    expect(
      tester.widget<NotionInboxRow>(find.byType(NotionInboxRow)).preview,
      contains('While covered'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('own bridge ghost messages preview as "You: Sticker"', (
    tester,
  ) async {
    final client = _Client();
    final room = _Room(client, '!fixture:example.invalid');
    // Trusted declaration: sent by the bridge bot, which is joined.
    const bot = '@telegrambot:bridge.invalid';
    for (final (type, key, content) in <(String, String, Map<String, dynamic>)>[
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
    room.sourceEvents.insert(
      0,
      Event(
        room: room,
        eventId: r'$sticker',
        type: EventTypes.Sticker,
        senderId: '@telegram_100:bridge.invalid',
        originServerTs: DateTime.utc(2026, 10, 16, 16, 50),
        content: {'body': 'sticker', 'url': 'mxc://example.invalid/s'},
      ),
    );
    OwnSenderResolver.invalidate(client);
    addTearDown(PersonalClient.of(client).dispose);
    await mountInbox(tester, client);
    expect(
      tester.widget<NotionInboxRow>(find.byType(NotionInboxRow)).preview,
      'You: Sticker',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
