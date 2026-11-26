// SPDX-License-Identifier: AGPL-3.0-or-later
// A long-open chat (desktop for days, a long-lived Android process) must not
// keep every event it ever loaded: while the app is away the live timeline
// is reloaded to its newest events, and only when the rows on and around
// the screen, the scroll position and the unread divider stay. Fictional
// offline fixtures only; no account, network or storage.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// The store: the newest [limit] events, once [honourLimit] is set (the
/// first open loads everything, like a chat scrolled back for days).
class _StoredRoom extends ConversationRoom {
  bool honourLimit = false;
  final limits = <int?>[];
  _StoredRoom(super.client, super.id);

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async {
    limits.add(limit);
    final stored = honourLimit && limit != null
        ? sourceEvents.take(limit).toList()
        : List.of(sourceEvents);
    return ConversationTimeline(
      room: this,
      chunk: TimelineChunk(events: stored),
      onUpdate: onUpdate,
    );
  }

  /// A message arriving through sync: stored first, then delivered.
  Event arrive(int i) {
    final event = message('\$m-$i', 'Fictional message $i', minute: i);
    client.onTimelineEvent.add(event);
    return event;
  }
}

Future<ChatController> _mountChat(
  WidgetTester tester,
  ConversationClient client,
  Room room,
) async {
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
        home: ChatPage(roomId: room.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<ChatController>(find.byType(ChatPageWithRoom));
}

Future<void> _leave(WidgetTester tester, {bool hide = true}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  if (hide) {
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }
  await tester.pump();
}

Future<void> _return(WidgetTester tester) async {
  final binding = tester.binding;
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late _StoredRoom room;
  late ConversationPersonal personal;

  setUp(() {
    client = ConversationClient();
    room = _StoredRoom(client, '!bound:example.invalid');
    for (var i = 0; i < 450; i++) {
      room.message('\$m-$i', 'Fictional message $i', minute: i);
    }
    personal = ConversationPersonal(client);
    PersonalClient.debugUse(client, personal);
  });
  tearDown(() {
    ChatController.debugNow = DateTime.now;
    personal.dispose();
  });

  test('the bounded size keeps the screen, its headroom and the divider', () {
    final events = room.sourceEvents;
    const window = ChatController.boundedTimelineEvents;
    expect(
      ChatController.boundedTimelineLimit(events, oldestBuilt: 10),
      window,
    );
    // Not loaded or not laid out: unknown, kept.
    expect(
      ChatController.boundedTimelineLimit(events, oldestBuilt: -1),
      isNull,
    );
    // Scrolled far up: it would not even halve.
    expect(
      ChatController.boundedTimelineLimit(events, oldestBuilt: 150),
      isNull,
    );
    expect(
      ChatController.boundedTimelineLimit(
        events.take(400).toList(),
        oldestBuilt: 10,
      ),
      isNull,
    );
    // The unread divider stays loaded unless it is far above.
    expect(
      ChatController.boundedTimelineLimit(
        events,
        oldestBuilt: 10,
        readMarkerEventId: events[180].eventId,
      ),
      isNull,
      reason: '180 + 50 rows would not halve 450',
    );
    expect(
      ChatController.boundedTimelineLimit(
        [...events, ...events],
        oldestBuilt: 10,
        readMarkerEventId: events[180].eventId,
      ),
      230,
    );
    expect(
      ChatController.boundedTimelineLimit(
        events,
        oldestBuilt: 10,
        readMarkerEventId: events[420].eventId,
      ),
      window,
    );
  });

  testWidgets('a chat left at its newest message reloads its newest events '
      'once hidden; rows and position stay', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _mountChat(tester, client, room);
    final before = controller.timeline!;
    expect(before.events, hasLength(450));
    expect(find.text('Fictional message 449'), findsOneWidget);
    expect(controller.scrollController.position.pixels, 0);
    room.honourLimit = true;

    await _leave(tester);
    await tester.pump();
    expect(room.limits.last, ChatController.boundedTimelineEvents);
    final after = controller.timeline!;
    expect(after, isNot(same(before)));
    expect(after.events, hasLength(ChatController.boundedTimelineEvents));
    expect(after.events.first.eventId, r'$m-449');

    await _return(tester);
    expect(find.text('Fictional message 449'), findsOneWidget);
    expect(controller.scrollController.position.pixels, 0);
    // A message arriving later lands in the bounded timeline.
    room.arrive(450);
    await tester.pumpAndSettle();
    expect(controller.timeline, same(after));
    expect(find.text('Fictional message 450'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a chat scrolled far up keeps everything it loaded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _mountChat(tester, client, room);
    controller.scrollController.jumpTo(
      controller.scrollController.position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    final position = controller.scrollController.position.pixels;
    room.honourLimit = true;
    final loads = room.limits.length;
    await _leave(tester);
    await tester.pump();
    expect(room.limits, hasLength(loads));
    expect(controller.timeline!.events, hasLength(450));
    await _return(tester);
    expect(controller.scrollController.position.pixels, position);
    await _unmount(tester);
  });

  testWidgets('an unfocused window reloads only after a while, on an arrival', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var now = DateTime.utc(2026, 11, 26, 9);
    ChatController.debugNow = () => now;
    final controller = await _mountChat(tester, client, room);
    final before = controller.timeline!;
    room.honourLimit = true;
    final loads = room.limits.length;

    // Visible but unfocused (macOS): nothing happens at first.
    await _leave(tester, hide: false);
    room.arrive(450);
    await tester.pumpAndSettle();
    expect(room.limits, hasLength(loads));
    expect(controller.timeline, same(before));

    now = now.add(ChatController.boundTimelineAfter);
    room.arrive(451);
    await tester.pumpAndSettle();
    expect(room.limits, hasLength(loads + 1));
    expect(controller.timeline, isNot(same(before)));
    expect(controller.timeline!.events.first.eventId, r'$m-451');
    expect(find.text('Fictional message 451'), findsOneWidget);
    expect(controller.scrollController.position.pixels, 0);
    await _return(tester);
    await _unmount(tester);
  });

  testWidgets('an open thread keeps the timeline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _mountChat(tester, client, room);
    controller.enterThread(r'$m-440');
    await tester.pumpAndSettle();
    room.honourLimit = true;
    final loads = room.limits.length;
    await _leave(tester);
    await tester.pump();
    expect(room.limits, hasLength(loads));
    expect(controller.timeline!.events, hasLength(450));
    await _return(tester);
    await _unmount(tester);
  });
}
