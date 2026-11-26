// SPDX-License-Identifier: AGPL-3.0-or-later
// Work per inbox publish (perf wave 2026-11-26): a sync of one room must
// cost O(changed rooms). Publishes that change no view's selection or order
// (a receipt, a delivery tick, a status flip) must not filter and sort the
// inbox again, nor rescan every room's networks; the status rows rebuild
// only from their own sources.
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show projectInbox;

import 'perf_fixtures.dart';
import 'perf_scenarios.dart';
import 'rebuild_counter.dart';

List<String> _ids(Iterable<Room> rooms) => [for (final room in rooms) room.id];

void main() {
  setUpAll(initPerfSettings);

  test('a one-room sync updates in place; only a reorder re-selects', () {
    fakeAsync((async) {
      final fixture = perfInbox();
      final client = fixture.client;
      final personal = PersonalClient.of(client);
      final inbox = InboxController(client, personal);
      inbox.index;
      final builds = inbox.debugFullBuilds;
      final scans = inbox.debugNetworkScans;
      var selection = inbox.selectionGeneration;

      // A status flip or account data: rows republish, the selection stays.
      inbox.markChanged(touch: true);
      async.elapse(const Duration(seconds: 2));
      expect(inbox.selectionGeneration, selection);

      // A sync of a room whose record did not move (a receipt, a tick).
      final quiet = fixture.rooms[42];
      inbox.markChanged(rooms: [quiet.id]);
      async.elapse(const Duration(seconds: 2));
      expect(inbox.debugIncrementalUpdates, greaterThan(0));
      expect(inbox.selectionGeneration, selection, reason: 'same order');

      // A new message moves the (unread) room to the top: one re-selection,
      // still no rebuild and no network rescan.
      final moved = fixture.rooms[135];
      moved.message(r'$perf-new', 'Fictional new message', minute: 5000);
      inbox.markChanged(rooms: [moved.id]);
      async.elapse(const Duration(seconds: 2));
      expect(inbox.selectionGeneration, greaterThan(selection));
      selection = inbox.selectionGeneration;
      expect(inbox.debugFullBuilds, builds, reason: 'incremental only');
      expect(inbox.debugNetworkScans, scans, reason: 'networks unchanged');

      // The incremental selection equals a full rebuild's.
      final fresh = InboxProjection.snapshot(personal);
      expect(
        _ids(inbox.projection.select(inbox.index)),
        _ids(fresh.select(fresh.buildIndex(client.rooms))),
      );
      expect(_ids(inbox.projection.select(inbox.index)).first, moved.id);

      // A whole rebuild always counts as a new selection.
      inbox.markChanged(all: true);
      async.elapse(const Duration(seconds: 2));
      expect(inbox.selectionGeneration, greaterThan(selection));
      expect(inbox.debugNetworkScans, scans + 1);

      inbox.dispose();
      async.flushTimers();
    });
  });

  test('view pre-filters never change a selection', () {
    final fixture = perfInbox();
    final personal = PersonalClient.of(fixture.client);
    final projection = InboxProjection.snapshot(personal);
    final index = projection.buildIndex(fixture.client.rooms);
    for (final filter in [
      InboxFilter.unread,
      InboxFilter.requests,
      InboxFilter.drafts,
      InboxFilter.unanswered,
      InboxFilter.archive,
      InboxFilter.lowPriority,
      InboxFilter.technical,
    ]) {
      final expected = [
        for (final record in projectInbox(index.records, filter: filter))
          record.representativeRoomId,
      ];
      expect(
        _ids(projection.select(index, filter: filter)),
        expected,
        reason: filter.name,
      );
    }
    expect(
      projection.select(index, filter: InboxFilter.unread),
      hasLength(60),
      reason: 'every fifth chat is unread',
    );
  });

  testWidgets('publishes that keep the order skip selection and status rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final fixture = perfInbox();
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfInboxRows(tester);
    final controller = tester.state<ChatListController>(find.byType(PerfInbox));
    await perfFrames(tester, const Duration(seconds: 2));
    expect(find.byType(NotionInboxRow), findsWidgets);
    final inbox = controller.inbox;

    final selections = controller.debugSelections;
    final published = inbox.generation;
    final quiet = await countRebuilds(tester, () async {
      // A room sync that changes no row (as for another user's receipt).
      fixture.client.onSync.add(perfSync([fixture.rooms[3]], 1));
      await perfFrames(tester, const Duration(seconds: 2));
      inbox.markChanged(touch: true);
      await perfFrames(tester, const Duration(seconds: 2));
    });
    expect(inbox.generation, greaterThan(published));
    expect(quiet[NotionInboxPage] ?? 0, greaterThan(0));
    expect(controller.debugSelections, selections, reason: 'memoised');
    expect(quiet[NotionInboxRow] ?? 0, 0, reason: 'rows unchanged');
    expect(quiet[InboxHealthStatus] ?? 0, 0);
    expect(quiet[ConnectionStatusLine] ?? 0, 0);

    // A new message re-selects once for the list and each chip count.
    fixture.rooms[3]
      ..message(r'$perf-new', 'Fictional new message', minute: 5000)
      ..unread += 1;
    fixture.client.onSync.add(perfSync([fixture.rooms[3]], 2));
    await perfFrames(tester, const Duration(seconds: 2));
    expect(controller.debugSelections, selections + 3);

    // A message in the top chat changes its row in place: that row, and
    // only that row, rebuilds (the counter measures something). A row that
    // moves to the very top is re-inflated instead (RenderSliverList drops
    // a leading child without a layout offset), so it is not used here.
    final top = fixture.rooms[3];
    final changed = await countRebuilds(tester, () async {
      top
        ..message(r'$perf-newer', 'Fictional newer message', minute: 5001)
        ..unread += 1;
      fixture.client.onSync.add(perfSync([top], 3));
      await perfFrames(tester, const Duration(seconds: 2));
    });
    expect(find.text('Fictional newer message'), findsOneWidget);
    expect(changed[NotionInboxRow], 1, reason: describeRebuilds(changed));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
