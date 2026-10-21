// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'conversation_test_support.dart';

/// Chat-list publication timing (2026-10-21): a change to a quiet inbox shows
/// in the next event-loop turn; changes right after it are still coalesced.
void main() {
  test(
    'space updates keep ordinary child chats visible without rebuilding',
    () {
      fakeAsync((async) {
        final client = ConversationClient();
        final child = ConversationRoom(client, '!child:example.invalid');
        final space = ConversationRoom(client, '!space:example.invalid');
        space.state(EventTypes.RoomCreate, {'type': RoomCreationTypes.mSpace});
        space.state('m.space.child', {
          'via': ['example.invalid'],
        }, key: child.id);
        final personal = PersonalClient.of(client);
        final inbox = InboxController(client, personal);

        expect(inbox.projection.select(inbox.index), [child]);
        final builds = inbox.debugFullBuilds;
        space.state('m.space.child', {}, key: child.id);
        inbox.markChanged(rooms: [space.id]);
        async.elapse(Duration.zero);

        expect(inbox.projection.select(inbox.index), [child]);
        expect(inbox.debugFullBuilds, builds);
        inbox.dispose();
        personal.dispose();
        async.flushTimers();
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('a single change shows at once; a burst right after it coalesces', () {
    fakeAsync((async) {
      final client = ConversationClient();
      final personal = PersonalClient.of(client);
      final inbox = InboxController(client, personal);
      var published = 0;
      inbox.addListener(() => published++);

      inbox.markChanged(touch: true);
      async.elapse(Duration.zero);
      expect(published, 1, reason: 'no debounce delay for a quiet inbox');

      // Three more changes 100 ms apart: one coalesced publication, 250 ms
      // after the last one.
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(milliseconds: 100));
        inbox.markChanged(touch: true);
      }
      async.elapse(const Duration(milliseconds: 200));
      expect(published, 1);
      async.elapse(const Duration(milliseconds: 100));
      expect(published, 2);

      // Quiet again after the cool-down: the next change is immediate.
      async.elapse(const Duration(seconds: 1));
      inbox.markChanged(touch: true);
      async.elapse(Duration.zero);
      expect(published, 3);

      // Several changes in one turn (one sync) are one publication.
      async.elapse(const Duration(seconds: 1));
      inbox.markChanged(touch: true);
      inbox.markChanged(all: true);
      async.elapse(Duration.zero);
      expect(published, 4);

      // While covered by a chat nothing publishes; returning refreshes once.
      async.elapse(const Duration(seconds: 1));
      inbox.active = false;
      inbox.markChanged(touch: true);
      async.elapse(const Duration(seconds: 2));
      expect(published, 4);
      inbox.active = true;
      async.elapse(Duration.zero);
      expect(published, 5);

      inbox.dispose();
      personal.dispose();
      async.flushTimers();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
