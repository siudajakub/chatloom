// SPDX-License-Identifier: AGPL-3.0-or-later
// A long-open merged person chat bounds each source timeline like the
// ordinary chat: while the app is away a source that grew far beyond the
// screen reloads its newest events, only when the merged rows on screen
// stay the same. Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _StoredRoom extends ConversationRoom {
  bool honourLimit = false;
  final limits = <int?>[];
  final timelines = <Timeline>[];
  _StoredRoom(super.client, super.id, {super.network});

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
    final timeline = ConversationTimeline(
      room: this,
      chunk: TimelineChunk(events: stored),
      onUpdate: onUpdate,
    );
    timelines.add(timeline);
    return timeline;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  tearDown(() => ChatController.debugNow = DateTime.now);

  testWidgets('a long source of a merged chat reloads its newest events once '
      'hidden; the rows on screen stay', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = ConversationClient();
    final a = _StoredRoom(client, '!bound-a:example.invalid');
    final b = _StoredRoom(
      client,
      '!bound-b:example.invalid',
      network: 'messenger',
    );
    for (var i = 0; i < 450; i++) {
      a.message('\$a-$i', 'Fictional message $i', minute: i);
    }
    b.message(r'$b-0', 'Messenger fictional message', minute: 3);
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    PersonalClient.debugUse(client, personal);
    final group = PersonGroup(
      id: 'bound-person',
      name: 'Anna',
      members: [personal.ref(a), personal.ref(b)],
      defaultRoomId: a.id,
    );
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(
          client,
          await SharedPreferences.getInstance(),
        ),
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: MergedChatPage(personal: personal, group: group),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fictional message 449'), findsOneWidget);
    expect(a.timelines, hasLength(1));
    final before = a.timelines.single;
    expect(before.events, hasLength(450));
    a.honourLimit = true;

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(a.limits.last, ChatController.boundedTimelineEvents);
    expect(a.timelines, hasLength(2));
    expect(
      a.timelines.last.events,
      hasLength(ChatController.boundedTimelineEvents),
    );
    expect(b.limits, hasLength(1), reason: 'A short source is left alone');

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Fictional message 449'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
