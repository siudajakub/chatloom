// SPDX-License-Identifier: AGPL-3.0-or-later
// Rebuild budgets for the conversation timelines (no device needed): typing,
// unrelated personal-store changes and healthy sync ticks must not rebuild
// message rows. Fictional offline fixtures only.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Personal extends ConversationPersonal {
  _Personal(super.client);
  void poke() => notifyListeners();
}

class _CountingTimeline extends ConversationTimeline {
  int keyRequests = 0;
  _CountingTimeline({
    required super.room,
    required super.chunk,
    super.onUpdate,
  });
  @override
  void requestKeys({
    bool tryOnlineBackup = true,
    bool onlineKeyBackupOnly = true,
  }) {
    keyRequests++;
    expect(onlineKeyBackupOnly, isFalse);
    super.requestKeys(
      tryOnlineBackup: tryOnlineBackup,
      onlineKeyBackupOnly: onlineKeyBackupOnly,
    );
  }
}

class _Room extends ConversationRoom {
  _CountingTimeline? timeline;
  _Room(super.client, super.id);
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async => timeline = _CountingTimeline(
    room: this,
    chunk: TimelineChunk(events: sourceEvents),
    onUpdate: onUpdate,
  );
}

class _SyncedClient extends ConversationClient {
  @override
  String? get prevBatch => 'fixture-batch';
}

Future<void> _mount(WidgetTester tester, Widget child, Client client) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Counts rebuilds of the message rows that exist when [body] starts (rows
/// built for the first time, e.g. scrolled into the cache, do not count).
Future<int> _rowUpdates(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final existing = <Element>{
    ...find.byType(MessageContent, skipOffstage: false).evaluate(),
    ...find.byType(ConversationBubble, skipOffstage: false).evaluate(),
  };
  expect(existing, isNotEmpty);
  var count = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    if (existing.contains(element)) count++;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return count;
}

Finder get _editor => find.descendant(
  of: find.byType(InputBar),
  matching: find.byType(TextField),
);

/// Counts rebuilds of message-row widgets while [body] runs.
Future<int> _rowRebuilds(Future<void> Function() body) async {
  var count = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    final widget = element.widget;
    if (widget is MessageContent || widget is ConversationBubble) count++;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return count;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late _Room a, b;
  late _Personal personal;
  late PersonGroup person;

  setUp(() {
    client = ConversationClient();
    a = _Room(client, '!budget-a:example.invalid');
    b = _Room(client, '!budget-b:example.invalid');
    a.message(r'$budget-a1', 'First fictional message');
    b.message(r'$budget-b1', 'Second fictional message', minute: 41);
    personal = _Personal(client);
    person = PersonGroup(
      id: 'budget-person',
      name: 'Anna',
      members: [personal.ref(a), personal.ref(b)],
      defaultRoomId: a.id,
    );
  });
  tearDown(() => personal.dispose());

  testWidgets('merged composer typing does not rebuild message rows', (
    tester,
  ) async {
    await _mount(
      tester,
      MergedChatPage(personal: personal, group: person),
      client,
    );
    expect(find.text('First fictional message'), findsOneWidget);
    final rebuilds = await _rowRebuilds(() async {
      for (final text in ['H', 'He', 'Hel', 'Hello']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
      }
    });
    expect(rebuilds, 0);
    // The composer itself still reacts to the text.
    expect(find.byKey(const Key('send_button')), findsOneWidget);
  });

  testWidgets(
    'merged rows ignore unrelated personal changes but follow palette changes',
    (tester) async {
      await _mount(
        tester,
        MergedChatPage(personal: personal, group: person),
        client,
      );
      final unrelated = await _rowRebuilds(() async {
        personal.values['draft:person:${person.id}'] = {'text': 'saved'};
        personal.values['unrelated:fixture'] = {'value': 1};
        personal.poke();
        await tester.pump();
      });
      expect(unrelated, 0);

      final palette = await _rowRebuilds(() async {
        personal.values['org:person:${person.id}'] = {
          'theme': {'incomingColor': 0xFFF5F5F5},
        };
        personal.poke();
        await tester.pump();
      });
      expect(palette, greaterThan(0));
      expect(
        tester
            .widgetList<ConversationBubble>(find.byType(ConversationBubble))
            .first
            .backgroundColor,
        const Color(0xFFF5F5F5),
      );
    },
  );

  testWidgets(
    'merged live update keeps row state, requests keys and observes visible rows',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _mount(
        tester,
        MergedChatPage(personal: personal, group: person),
        client,
      );
      expect(a.timeline!.keyRequests, 1);
      expect(b.timeline!.keyRequests, 1);
      expect(PersonalPrivacy.frozenReadCutoff(a), r'$budget-a1');

      // Rows are keyed by event (transaction) id, as in ordinary chats.
      final rowKey = ValueKey(a.sourceEvents.single.eventId);
      final before = tester.state(find.byKey(rowKey));
      // Several updates in one frame are applied once.
      a.message(r'$budget-a2', 'Fresh fictional message', minute: 45);
      for (var i = 0; i < 5; i++) {
        a.timeline!.onUpdate!();
      }
      await tester.pumpAndSettle();
      expect(find.text('Fresh fictional message'), findsOneWidget);
      expect(tester.state(find.byKey(rowKey)), same(before));
      expect(PersonalPrivacy.frozenReadCutoff(a), r'$budget-a2');
    },
  );

  group('single chat', () {
    late ConversationRoom room;
    late ConversationPersonal ordinary;

    setUp(() {
      room = ConversationRoom(client, '!budget-single:example.invalid');
      for (var i = 0; i < 40; i++) {
        room.message('\$single-$i', 'Fictional row $i', minute: i);
      }
      ordinary = ConversationPersonal(client);
      PersonalClient.debugUse(client, ordinary);
    });
    tearDown(() => ordinary.dispose());

    Future<ChatController> mountChat(WidgetTester tester) async {
      await _mount(tester, ChatPageWithRoom(room: room), client);
      // Let the list widen its cache (a one-off rebuild after the open)
      // before anything is measured.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      return tester.state<ChatController>(find.byType(ChatPageWithRoom));
    }

    testWidgets('the first scroll pixel and the way back rebuild no row', (
      tester,
    ) async {
      final controller = await mountChat(tester);
      final jump = <bool>[];
      controller.jumpButtonVisible.addListener(
        () => jump.add(controller.jumpButtonVisible.value),
      );
      final rebuilds = await _rowUpdates(tester, () async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(ListView).first),
        );
        // The first move only wins the drag (touch slop); then a few pixels.
        for (var i = 0; i < 3; i++) {
          await gesture.moveBy(const Offset(0, 12));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.scrollController.position.pixels, greaterThan(0));
        for (var i = 0; i < 4; i++) {
          await gesture.moveBy(const Offset(0, -12));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pumpAndSettle();
      });
      expect(rebuilds, 0);
      expect(controller.scrollController.position.pixels, 0);
      // Only the jump button followed the flip.
      expect(jump, [true, false]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('typing the first character and clearing rebuild no row', (
      tester,
    ) async {
      await mountChat(tester);
      final rebuilds = await _rowUpdates(tester, () async {
        await tester.enterText(_editor, 'H');
        await tester.pump();
        await tester.enterText(_editor, 'He');
        await tester.pump();
        await tester.enterText(_editor, '');
        await tester.pump();
      });
      expect(rebuilds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a send (start, durable, network end) rebuilds no row', (
      tester,
    ) async {
      final gate = Completer<void>();
      ordinary.transportGate = gate;
      await mountChat(tester);
      await tester.enterText(_editor, 'Fictional outgoing text');
      await tester.pump();
      final rebuilds = await _rowUpdates(tester, () async {
        await tester.tap(find.byKey(const Key('send_button')));
        for (var i = 0; i < 4; i++) {
          await tester.pump(Duration.zero);
        }
        expect(ordinary.sends.single.text, 'Fictional outgoing text');
        gate.complete();
        await tester.pump();
        await tester.pump();
      });
      expect(rebuilds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('emoji picker and action tray toggles rebuild no row', (
      tester,
    ) async {
      final controller = await mountChat(tester);
      final rebuilds = await _rowUpdates(tester, () async {
        controller.emojiPickerAction();
        await tester.pump(const Duration(milliseconds: 400));
        controller.emojiPickerAction();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byTooltip('More message actions'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byTooltip('Hide message actions'));
        await tester.pump(const Duration(milliseconds: 400));
      });
      expect(rebuilds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a timeline update rebuilds rows and keeps their state', (
      tester,
    ) async {
      final controller = await mountChat(tester);
      // Not the newest row: its seen-by row carries the same key.
      final rowKey = ValueKey(room.sourceEvents[2].eventId);
      final before = tester.state(find.byKey(rowKey));
      final revision = controller.timelineRevision;
      final event = room.message(r'$single-new', 'Fresh fictional row');
      final rebuilds = await _rowUpdates(tester, () async {
        // The fixture timeline shares the room's event list.
        if (!controller.timeline!.events.contains(event)) {
          controller.timeline!.events.insert(0, event);
        }
        for (var i = 0; i < 3; i++) {
          controller.timeline!.onUpdate!();
        }
        await tester.pumpAndSettle();
      });
      expect(rebuilds, greaterThan(0));
      expect(controller.timelineRevision, revision + 1);
      expect(find.text('Fresh fictional row'), findsOneWidget);
      expect(tester.state(find.byKey(rowKey)), same(before));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('the list gate hands back the rows until the revision moves', (
      tester,
    ) async {
      var builds = 0;
      Widget gate(int revision) => ConversationListGate(
        revision: revision,
        child: Builder(
          builder: (_) {
            builds++;
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(gate(0));
      await tester.pumpWidget(gate(0));
      await tester.pumpWidget(gate(0));
      expect(builds, 1);
      await tester.pumpWidget(gate(1));
      expect(builds, 2);
    });
  });

  testWidgets('healthy sync ticks rebuild neither chrome nor timeline', (
    tester,
  ) async {
    final synced = _SyncedClient();
    final room = ConversationRoom(synced, '!signals:example.invalid');
    synced.onSync.add(SyncUpdate(nextBatch: 'fixture-batch'));
    synced.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
    var chromeBuilds = 0;
    var timelineBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatRoomSignals(
          room: room,
          child: Builder(
            builder: (_) {
              timelineBuilds++;
              return const SizedBox();
            },
          ),
          builder: (context, child) {
            chromeBuilds++;
            return Column(children: [Expanded(child: child)]);
          },
        ),
      ),
    );
    expect((chromeBuilds, timelineBuilds), (1, 1));

    for (final status in [
      SyncStatus.waitingForResponse,
      SyncStatus.processing,
      SyncStatus.cleaningUp,
      SyncStatus.finished,
    ]) {
      synced.onSyncStatus.add(SyncStatusUpdate(status));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pump(const Duration(seconds: 2));
    expect((chromeBuilds, timelineBuilds), (1, 1));

    // Entering the error state shows the notice: chrome only.
    synced.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.error));
    await tester.pump(const Duration(seconds: 2));
    expect(chatSyncNoticeVisible(synced), isTrue);
    expect((chromeBuilds, timelineBuilds), (2, 1));

    // Recovery hides it again.
    synced.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
    await tester.pump(const Duration(seconds: 2));
    expect(chatSyncNoticeVisible(synced), isFalse);
    expect((chromeBuilds, timelineBuilds), (3, 1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
