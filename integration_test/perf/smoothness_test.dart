// SPDX-License-Identifier: AGPL-3.0-or-later
// Frame-timing benchmark (PF-11): inbox fling, inbox fling with syncs, chat
// fling, chat open/close and keyboard open/close on fictional, account-free
// fixtures. Run on the Pixel and the Mac in profile mode through
// scripts/perf/run-benchmarks.sh (see docs/performance-benchmarks.md);
// never with `flutter drive` straight onto the phone's real app id.
//
// Each scenario reports Flutter's FrameTimingSummarizer numbers
// (average/90th/99th percentile build and raster times, missed budgets) to
// build/perf/chatloom_smoothness.json via the driver, and prints one
// `PERSONAL_BENCH {json}` line per scenario.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/perf/perf_fixtures.dart';
import '../../test/perf/perf_scenarios.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real frames from the engine (not test-driven), so timings are real.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(initPerfSettings);

  Future<void> measure(String key, Future<void> Function() action) async {
    await binding.watchPerformance(action, reportKey: key);
    final summary = binding.reportData?[key];
    if (summary is Map) {
      const fields = [
        'average_frame_build_time_millis',
        '90th_percentile_frame_build_time_millis',
        '99th_percentile_frame_build_time_millis',
        'worst_frame_build_time_millis',
        'average_frame_rasterizer_time_millis',
        '90th_percentile_frame_rasterizer_time_millis',
        '99th_percentile_frame_rasterizer_time_millis',
        'worst_frame_rasterizer_time_millis',
        'missed_frame_build_budget_count',
        'missed_frame_rasterizer_budget_count',
        'frame_count',
      ];
      debugPrint(
        'PERSONAL_BENCH ${jsonEncode({'scenario': key, for (final field in fields)
          if (summary.containsKey(field)) field: summary[field]})}',
      );
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await perfFrames(tester, const Duration(milliseconds: 500));
  }

  testWidgets('inbox fling (300 chats)', (tester) async {
    final fixture = perfInbox();
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfReady(tester);
    await perfFrames(tester, const Duration(seconds: 2));
    await measure('inbox_fling', () => perfInboxFling(tester));
    await unmount(tester);
  });

  testWidgets('inbox fling with 20 syncs', (tester) async {
    final fixture = perfInbox();
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfReady(tester);
    await perfFrames(tester, const Duration(seconds: 2));
    await measure(
      'inbox_fling_syncs',
      () => perfInboxFlingWithSyncs(tester, fixture.client, fixture.rooms),
    );
    await unmount(tester);
  });

  testWidgets('chat fling (500 messages)', (tester) async {
    final fixture = perfConversation();
    await tester.pumpWidget(
      perfApp(fixture.client, perfChatPage(fixture.room)),
    );
    await perfReady(tester);
    await perfFrames(tester, const Duration(seconds: 3));
    await measure('chat_fling', () => perfChatFling(tester));
    await unmount(tester);
  });

  testWidgets('chat open and close (10 times)', (tester) async {
    final fixture = perfConversation();
    await tester.pumpWidget(perfApp(fixture.client, const Scaffold()));
    await perfReady(tester);
    await perfFrames(tester, const Duration(seconds: 1));
    await measure(
      'chat_open_close',
      () => perfChatOpenClose(tester, fixture.room),
    );
    await unmount(tester);
  });

  testWidgets('keyboard open and close (5 times)', (tester) async {
    final fixture = perfConversation(events: 200);
    await tester.pumpWidget(
      perfApp(fixture.client, perfChatPage(fixture.room)),
    );
    await perfReady(tester);
    await perfFrames(tester, const Duration(seconds: 3));
    await measure('keyboard', () => perfKeyboard(tester));
    await unmount(tester);
  });
}
