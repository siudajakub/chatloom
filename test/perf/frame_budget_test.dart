// SPDX-License-Identifier: AGPL-3.0-or-later
// Frame-work budgets for the benchmark scenarios, runnable on Linux without
// a device (PF-11). Wall-clock frame times need the device benchmark
// (integration_test/perf/smoothness_test.dart); here the budget is the work
// each frame causes: page-level widgets must not rebuild per scroll frame,
// existing rows must not rebuild while they only move, and the screen must
// go idle (no scheduled frame) once the interaction is over.
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat_list/chat_list_body.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'perf_fixtures.dart';
import 'perf_scenarios.dart';
import 'rebuild_counter.dart';

/// Rebuilds of widgets already on screen, by type, while [body] runs.
Future<Map<Type, int>> _rebuilds(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final counts = await countRebuilds(tester, body);
  // Printed so a budget change has its evidence in the log.
  debugPrint('rebuilds: ${describeRebuilds(counts, top: 30)}');
  return counts;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Inbox debounce and status timers.
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  setUpAll(initPerfSettings);

  testWidgets('inbox fling: no page or row rebuilds, idle afterwards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final fixture = perfInbox();
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfInboxRows(tester);
    await perfFrames(tester, const Duration(seconds: 2));
    expect(find.byType(NotionInboxRow), findsWidgets);

    final rebuilds = await _rebuilds(
      tester,
      () => perfInboxFling(tester, rounds: 2),
    );
    expect(rebuilds[ChatListViewBody] ?? 0, 0);
    expect(rebuilds[NotionInboxPage] ?? 0, 0);
    expect(rebuilds[NotionInboxRow] ?? 0, 0, reason: 'rows only moved');
    await perfFrames(tester, const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'idle inbox');
    await _unmount(tester);
  });

  testWidgets('inbox fling with syncs rebuilds only the changed rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final fixture = perfInbox();
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfInboxRows(tester);
    await perfFrames(tester, const Duration(seconds: 2));
    expect(find.byType(NotionInboxRow), findsWidgets);

    final rebuilds = await _rebuilds(
      tester,
      () => perfInboxFlingWithSyncs(tester, fixture.client, fixture.rooms),
    );
    // Publishes are coalesced (debounce 250 ms, at most 1 s): 20 syncs in
    // one second must not mean 20 page rebuilds.
    expect(rebuilds[NotionInboxPage] ?? 0, lessThanOrEqualTo(8));
    // Each sync changes one row: at most that row rebuilds (a row that
    // moves to the top is re-inflated instead and is not counted).
    expect(rebuilds[NotionInboxRow] ?? 0, lessThanOrEqualTo(20));
    await perfFrames(tester, const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _unmount(tester);
  });

  testWidgets('chat fling: no ChatView or bubble rebuilds, idle afterwards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final fixture = perfConversation();
    await tester.pumpWidget(
      perfApp(fixture.client, perfChatPage(fixture.room)),
    );
    await _waitForRows(tester);

    final rebuilds = await _rebuilds(
      tester,
      () => perfChatFling(tester, rounds: 2),
    );
    expect(rebuilds[ChatView] ?? 0, lessThanOrEqualTo(2));
    expect(rebuilds[ConversationBubble] ?? 0, 0, reason: 'bubbles only moved');
    expect(rebuilds[MessageContent] ?? 0, 0);
    await perfFrames(tester, const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'idle chat');
    await _unmount(tester);
  });

  testWidgets('opening and closing a chat leaves nothing running', (
    tester,
  ) async {
    final fixture = perfConversation(events: 200);
    await tester.pumpWidget(perfApp(fixture.client, const Scaffold()));
    await perfChatOpenClose(tester, fixture.room, times: 3);
    await perfFrames(tester, const Duration(seconds: 2));
    expect(find.byType(ChatView), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _unmount(tester);
  });

  testWidgets('composer focus does not rebuild message rows', (tester) async {
    final fixture = perfConversation(events: 100);
    await tester.pumpWidget(
      perfApp(fixture.client, perfChatPage(fixture.room)),
    );
    await _waitForRows(tester);
    final rebuilds = await _rebuilds(
      tester,
      () => perfKeyboard(tester, times: 2),
    );
    expect(rebuilds[ConversationBubble] ?? 0, 0);
    expect(rebuilds[MessageContent] ?? 0, 0);
    await _unmount(tester);
  });
}

/// The timeline loads asynchronously (outside fake time).
Future<void> _waitForRows(WidgetTester tester) async {
  final rows = find.byType(ConversationBubble);
  for (var i = 0; i < 40 && rows.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await perfFrames(tester, const Duration(seconds: 1));
  expect(rows, findsWidgets);
}
