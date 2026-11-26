// SPDX-License-Identifier: AGPL-3.0-or-later
// Drafts while typing (perf wave 2, 2026-11-26): every composer pause saves
// the draft to the private store, and its journal echo follows. Such a save
// must refresh only its conversation's inbox row in place, never rebuild the
// inbox index or every row; the row preview and the Drafts view still follow.
// Fictional offline fixtures only.
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'perf_fixtures.dart';
import 'perf_scenarios.dart';

/// In-memory stand-in for the encrypted store.
class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  int writes = 0;
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    writes++;
    records[key] = value;
  }

  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _ids(Iterable<Room> rooms) => [for (final room in rooms) room.id];

/// A perf inbox whose private client has a working (in-memory) store.
({PerfClient client, List<PerfRoom> rooms, PersonalClient personal})
_inbox() {
  final fixture = perfInbox();
  final personal = PersonalClient.forTesting(
    fixture.client,
    openStore: () async => _Store(),
  );
  PersonalClient.debugUse(fixture.client, personal);
  return (client: fixture.client, rooms: fixture.rooms, personal: personal);
}

void main() {
  setUpAll(initPerfSettings);

  test('a draft save says which entity changed', () {
    fakeAsync((async) {
      final fixture = _inbox();
      final personal = fixture.personal;
      final changes = <PersonalChange>[];
      personal.changeDetails.listen(changes.add);
      personal.loadLocal();
      async.flushMicrotasks();
      // Opening the store may affect anything.
      expect(changes.last.entities, isNull);
      expect(changes.last.draftsOnly, isFalse);

      changes.clear();
      final room = fixture.rooms[7];
      personal.saveDraft(room, 'Fictional draft');
      async.flushMicrotasks();
      expect(changes, isNotEmpty);
      for (final change in changes) {
        expect(change.content, isTrue);
        expect(change.entities, {'draft:${room.id}'});
        expect(change.draftsOnly, isTrue);
      }
      expect(personal.lastChange, same(changes.last));

      // A direct notification may cover anything.
      changes.clear();
      personal.notifyListeners();
      async.flushMicrotasks();
      expect(changes.single.entities, isNull);
      expect(changes.single.draftsOnly, isFalse);
      personal.dispose();
    });
  });

  test('a draft save updates its record in place; the Drafts view follows', () {
    fakeAsync((async) {
      final fixture = _inbox();
      final personal = fixture.personal;
      final inbox = InboxController(
        fixture.client,
        personal,
        localReady: personal.loadLocal(),
      );
      async.elapse(const Duration(seconds: 2));
      inbox.index;
      final builds = inbox.debugFullBuilds;
      var selection = inbox.selectionGeneration;
      final room = fixture.rooms[42];

      List<String> drafts() => _ids(
        inbox.projection.select(inbox.index, filter: InboxFilter.drafts),
      );
      List<String> fresh(InboxFilter filter) {
        final projection = InboxProjection.snapshot(personal);
        return _ids(
          projection.select(
            projection.buildIndex(fixture.client.rooms),
            filter: filter,
          ),
        );
      }

      expect(drafts(), isEmpty);

      // The first draft of a chat adds it to the Drafts view.
      personal.saveDraft(room, 'Fictional draft');
      async.elapse(const Duration(seconds: 2));
      expect(inbox.debugFullBuilds, builds, reason: 'no index rebuild');
      expect(inbox.debugDraftUpdates, greaterThan(0));
      expect(inbox.selectionGeneration, greaterThan(selection));
      selection = inbox.selectionGeneration;
      expect(drafts(), [room.id]);
      expect(drafts(), fresh(InboxFilter.drafts));
      expect(
        _ids(inbox.projection.select(inbox.index)),
        fresh(InboxFilter.inbox),
      );

      // Typing on: the row republishes, nothing is re-selected.
      final published = inbox.generation;
      for (final text in ['Fictional draft 2', 'Fictional draft 23']) {
        personal.saveDraft(room, text);
        async.elapse(const Duration(seconds: 2));
      }
      expect(inbox.generation, greaterThan(published));
      expect(inbox.selectionGeneration, selection);
      expect(inbox.debugFullBuilds, builds);

      // Clearing it removes the chat from the Drafts view again.
      personal.saveDraft(room, '');
      async.elapse(const Duration(seconds: 2));
      expect(drafts(), isEmpty);
      expect(drafts(), fresh(InboxFilter.drafts));
      expect(inbox.debugFullBuilds, builds);

      // Any other private change still rebuilds the index.
      personal.notifyListeners();
      async.elapse(const Duration(seconds: 2));
      expect(inbox.debugFullBuilds, greaterThan(builds));

      inbox.dispose();
      personal.dispose();
      async.flushTimers();
    });
  });

  testWidgets('a draft save rebuilds only its own row', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final hidden = HiddenMessages.instance.storageFor;
    final kept = KeptMessages.instance.storageFor;
    HiddenMessages.instance.storageFor = (_) => null;
    KeptMessages.instance.storageFor = (_) => null;
    addTearDown(() {
      HiddenMessages.instance.storageFor = hidden;
      KeptMessages.instance.storageFor = kept;
    });
    final fixture = _inbox();
    final personal = fixture.personal;
    await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
    await perfReady(tester);
    final controller = tester.state<ChatListController>(find.byType(PerfInbox));
    final rows = find.byType(NotionInboxRow);
    for (var i = 0; i < 50 && rows.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(perfFrame);
    }
    await tester.runAsync(personal.loadLocal);
    await perfFrames(tester, const Duration(seconds: 2));
    expect(rows, findsWidgets);
    final inbox = controller.inbox;
    // The newest (unread) chat is the first row.
    final room = fixture.rooms[0];

    final builds = inbox.debugFullBuilds;
    final built = controller.rowMemo.debugBuilt;
    final existing = tester.allElements.toSet();
    var rowRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (existing.contains(element) && element.widget is NotionInboxRow) {
        rowRebuilds++;
      }
    };
    try {
      await tester.runAsync(() => personal.saveDraft(room, 'Fictional note'));
      await perfFrames(tester, const Duration(seconds: 2));
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
    expect(find.text('Draft: Fictional note'), findsOneWidget);
    expect(inbox.debugFullBuilds, builds, reason: 'no index rebuild');
    expect(controller.rowMemo.debugBuilt, built + 1, reason: 'one row');
    expect(rowRebuilds, lessThanOrEqualTo(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    personal.dispose();
  });
}
