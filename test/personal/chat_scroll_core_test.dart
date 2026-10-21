// SPDX-License-Identifier: AGPL-3.0-or-later
// Single-chat scroll paths (review R1, R10, R11, R19). Fictional offline
// fixtures only; no account, network or storage.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A timeline opened at an event context: new events are not appended.
class _ContextRoom extends ConversationRoom {
  bool context = true;
  int joins = 0;
  _ContextRoom(super.client, super.id);

  @override
  Future<void> join({bool leaveIfNotFound = true}) async {
    joins++;
    // Stays an invite while the dialog is up, like a slow server.
    await Future<void>.delayed(const Duration(seconds: 1));
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
  )..allowNewEvent = !context;
}

Future<void> _mount(WidgetTester tester, Client client, String roomId) async {
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
        home: ChatPage(roomId: roomId),
      ),
    ),
  );
  // Localizations, the timeline and the first rows load asynchronously.
  final rows = find.textContaining('Fictional message', findRichText: true);
  for (var i = 0; i < 40 && rows.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _frames(WidgetTester tester, [int count = 30]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

Future<int> _chatViewBuilds(Future<void> Function() body) async {
  var count = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    if (element.widget is ChatView) count++;
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
  late _ContextRoom room;

  setUp(() {
    client = ConversationClient();
    room = _ContextRoom(client, '!scroll-core:example.invalid');
    for (var i = 0; i < 60; i++) {
      room.message('\$scroll-$i', 'Fictional message number $i', minute: i);
    }
  });

  testWidgets('scrolling a context timeline does not rebuild the chat per '
      'frame', (tester) async {
    await _mount(tester, client, room.id);
    expect(
      find.textContaining('Fictional message number', findRichText: true),
      findsWidgets,
    );
    final controller = tester.state<ChatController>(
      find.byType(ChatPageWithRoom),
    );
    expect(controller.timeline?.allowNewEvent, isFalse);

    final builds = await _chatViewBuilds(() async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView).first),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await _frames(tester);
    });
    // At most the one transition into the scrolled-up state, never one
    // rebuild per scroll notification.
    expect(builds, lessThanOrEqualTo(1));
    expect(controller.scrollController.position.pixels, greaterThan(100));
    expect(controller.showScrollDownButton, isTrue);
    await _unmount(tester);
  });

  testWidgets('conversation events are filtered once per controller rebuild', (
    tester,
  ) async {
    room.context = false;
    await _mount(tester, client, room.id);
    final controller = tester.state<ChatController>(
      find.byType(ChatPageWithRoom),
    );
    final first = controller.conversationEvents;
    expect(identical(first, controller.conversationEvents), isTrue);
    expect(first, hasLength(60));

    // A timeline update (here: an in-place change plus onUpdate) refreshes it.
    room.message(r'$scroll-new', 'Fresh fictional message', minute: 59);
    controller.timeline!.events.insert(0, room.sourceEvents.first);
    controller.timeline!.onUpdate!();
    await tester.pump();
    final second = controller.conversationEvents;
    expect(identical(first, second), isFalse);
    expect(second!.first.eventId, r'$scroll-new');
    await _unmount(tester);
  });

  testWidgets('jumping to a loaded message centres that message', (
    tester,
  ) async {
    room.context = false;
    await _mount(tester, client, room.id);
    final controller = tester.state<ChatController>(
      find.byType(ChatPageWithRoom),
    );
    // The jump animates: drive frames instead of awaiting it.
    unawaited(controller.scrollToEventId(r'$scroll-30'));
    await _frames(tester, 40);
    final list = tester.getRect(find.byType(ListView).first);
    final centre = list.center.dy;
    double distance(int n) =>
        (tester
                    .getRect(
                      find.text(
                        'Fictional message number $n',
                        findRichText: true,
                      ),
                    )
                    .center
                    .dy -
                centre)
            .abs();
    // The target row, not its neighbour, sits in the middle of the list.
    expect(distance(30), lessThan(distance(29)));
    expect(distance(30), lessThan(distance(31)));
    await _unmount(tester);
  });

  testWidgets('an invite is joined once however often the chat rebuilds', (
    tester,
  ) async {
    room
      ..context = false
      ..membership = Membership.invite;
    await _mount(tester, client, room.id);
    final controller = tester.state<ChatController>(
      find.byType(ChatPageWithRoom),
    );
    for (var i = 0; i < 5; i++) {
      controller.updateView();
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 2));
    expect(room.joins, 1);
    await _unmount(tester);
  });
}
