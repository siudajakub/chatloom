// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'conversation_test_support.dart';

class _CachedClient extends ConversationClient {
  @override
  String get prevBatch => 'fictional saved cursor';
}

void main() {
  test('saved cursor does not bypass local rooms and private metadata', () {
    fakeAsync((async) {
      final client = _CachedClient();
      final rooms = Completer<void>();
      final metadata = Completer<void>();
      client.roomsLoading = rooms.future;
      final personal = PersonalClient.of(client);
      final inbox = InboxController(
        client,
        personal,
        localReady: metadata.future,
      );
      expect(inbox.loading, isTrue);
      // A build during hydration must not pin the empty index forever.
      expect(inbox.index.rooms, isEmpty);
      ConversationRoom(client, '!fixture:example.invalid');
      rooms.complete();
      async.flushMicrotasks();
      expect(inbox.loading, isTrue);
      metadata.complete();
      async.elapse(Duration.zero);
      expect(inbox.loading, isFalse);
      expect(inbox.index.rooms, hasLength(1));
      inbox.dispose();
      personal.dispose();
      async.flushTimers();
      expect(async.pendingTimers, isEmpty);
    });
  });

  for (final outcome in ['success', 'failure', 'slow', 'detach']) {
    test('cached catch-up is bounded and releases resources: $outcome', () {
      fakeAsync((async) {
        final client = _CachedClient();
        ConversationRoom(client, '!fixture:example.invalid');
        final sync = Completer<void>();
        client.firstSyncReceived = sync.future;
        final personal = PersonalClient.of(client);
        final inbox = InboxController(
          client,
          personal,
          localReady: Future.value(),
        );
        var publications = 0;
        inbox.addListener(() => publications++);
        async.flushMicrotasks();
        expect(inbox.loading, isTrue);
        if (outcome == 'success') sync.complete();
        if (outcome == 'failure')
          sync.completeError(StateError('offline fixture'));
        if (outcome == 'detach') inbox.detach();
        async.elapse(
          outcome == 'slow' ? const Duration(seconds: 3) : Duration.zero,
        );
        if (outcome == 'detach') {
          expect(publications, 0);
        } else {
          expect(inbox.loading, isFalse);
          expect(inbox.index.rooms, hasLength(1));
        }
        inbox.dispose();
        personal.dispose();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  }

  test('local failure ends skeleton and retry restores the inbox once', () {
    fakeAsync((async) {
      final client = _CachedClient();
      final metadata = Completer<void>();
      final personal = PersonalClient.of(client);
      final inbox = InboxController(
        client,
        personal,
        localReady: metadata.future,
      );
      metadata.completeError(StateError('encrypted storage unavailable'));
      async.elapse(Duration.zero);
      expect(inbox.loading, isFalse);
      expect(inbox.localLoadFailed, isTrue);
      final retry = Completer<void>();
      var attempts = 0;
      Future<void> load() {
        attempts++;
        return retry.future;
      }

      inbox.retryLocal(load);
      inbox.retryLocal(load);
      async.flushMicrotasks();
      expect(inbox.loading, isTrue);
      expect(attempts, 1);
      retry.complete();
      async.elapse(const Duration(seconds: 1));
      expect(inbox.loading, isFalse);
      expect(inbox.localLoadFailed, isFalse);
      inbox.dispose();
      inbox.retryLocal(load);
      expect(attempts, 1);
      personal.dispose();
      async.flushTimers();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
