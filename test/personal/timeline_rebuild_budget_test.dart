// SPDX-License-Identifier: AGPL-3.0-or-later
// Rebuild budgets for the conversation timelines (no device needed): typing,
// unrelated personal-store changes and healthy sync ticks must not rebuild
// message rows. Fictional offline fixtures only.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat_view.dart';
import 'package:fluffychat/pages/chat/conversation_bubble.dart';
import 'package:fluffychat/pages/chat/events/message_content.dart';
import 'package:fluffychat/personal/merged_chat_page.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/widgets/matrix.dart';
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
  late PersonGroup group;

  setUp(() {
    client = ConversationClient();
    a = _Room(client, '!budget-a:example.invalid');
    b = _Room(client, '!budget-b:example.invalid');
    a.message(r'$budget-a1', 'First fictional message');
    b.message(r'$budget-b1', 'Second fictional message', minute: 41);
    personal = _Personal(client);
    group = PersonGroup(
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
      MergedChatPage(personal: personal, group: group),
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
        MergedChatPage(personal: personal, group: group),
        client,
      );
      final unrelated = await _rowRebuilds(() async {
        personal.values['draft:person:${group.id}'] = {'text': 'saved'};
        personal.values['unrelated:fixture'] = {'value': 1};
        personal.poke();
        await tester.pump();
      });
      expect(unrelated, 0);

      final palette = await _rowRebuilds(() async {
        personal.values['org:person:${group.id}'] = {
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
        MergedChatPage(personal: personal, group: group),
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
