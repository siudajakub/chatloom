// SPDX-License-Identifier: AGPL-3.0-or-later
// Interaction scripts shared by the device benchmark
// (integration_test/perf/smoothness_test.dart, real frames) and the Linux
// budget test (test/perf/frame_budget_test.dart, fake time). `pump` with a
// duration elapses fake time in widget tests and waits in real time on a
// device, so the same script drives both.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'perf_fixtures.dart';

const perfFrame = Duration(milliseconds: 16);

/// Pumps frames for [total].
Future<void> perfFrames(WidgetTester tester, Duration total) async {
  for (var t = Duration.zero; t < total; t += perfFrame) {
    await tester.pump(perfFrame);
  }
}

/// Waits until the first page is built: localizations load outside fake
/// time in widget tests.
Future<void> perfReady(WidgetTester tester) async {
  for (var i = 0; i < 50 && find.byType(Scaffold).evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(perfFrame);
  }
}

/// The main vertical list on screen (not the pinned row or a text field).
Finder perfVerticalList() => find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
    )
    .first;

/// Flings the inbox down and back up [rounds] times.
Future<void> perfInboxFling(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.fling(perfVerticalList(), const Offset(0, -1800), 4000);
    await perfFrames(tester, const Duration(milliseconds: 1500));
    await tester.fling(perfVerticalList(), const Offset(0, 1800), 4000);
    await perfFrames(tester, const Duration(milliseconds: 1500));
  }
}

/// Flings the inbox while [syncs] new messages arrive, one every 50 ms.
Future<void> perfInboxFlingWithSyncs(
  WidgetTester tester,
  PerfClient client,
  List<PerfRoom> rooms, {
  int syncs = 20,
}) async {
  await tester.fling(perfVerticalList(), const Offset(0, -2400), 3000);
  for (var k = 0; k < syncs; k++) {
    final room = rooms[(k * 7) % rooms.length];
    room
      ..message('\$perf-sync-$k', 'Fictional new message $k', minute: 2000 + k)
      ..unread += 1;
    client.onSync.add(perfSync([room], k));
    await perfFrames(tester, const Duration(milliseconds: 50));
  }
  await tester.fling(perfVerticalList(), const Offset(0, 2400), 3000);
  await perfFrames(tester, const Duration(milliseconds: 1500));
}

/// Flings a (reversed) conversation towards older messages and back, then
/// scrolls away from the bottom and returns.
Future<void> perfChatFling(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.fling(perfVerticalList(), const Offset(0, 1800), 4000);
    await perfFrames(tester, const Duration(milliseconds: 1500));
    await tester.fling(perfVerticalList(), const Offset(0, -1800), 4000);
    await perfFrames(tester, const Duration(milliseconds: 1500));
  }
  await tester.drag(perfVerticalList(), const Offset(0, 600));
  await perfFrames(tester, const Duration(milliseconds: 500));
  await tester.drag(perfVerticalList(), const Offset(0, -900));
  await perfFrames(tester, const Duration(milliseconds: 800));
}

/// Opens and closes the chat of [room] [times] times over the current page.
Future<void> perfChatOpenClose(
  WidgetTester tester,
  Room room, {
  int times = 10,
}) async {
  await perfReady(tester);
  final navigator = Navigator.of(tester.element(find.byType(Scaffold).first));
  for (var i = 0; i < times; i++) {
    navigator.push(MaterialPageRoute<void>(builder: (_) => perfChatPage(room)));
    await perfFrames(tester, const Duration(milliseconds: 1200));
    navigator.pop();
    await perfFrames(tester, const Duration(milliseconds: 700));
  }
}

/// Focuses and leaves the composer [times] times (the soft keyboard slides
/// in and out on phones).
Future<void> perfKeyboard(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byType(TextField).last);
    await perfFrames(tester, const Duration(milliseconds: 900));
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await perfFrames(tester, const Duration(milliseconds: 900));
  }
}
