// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:fluffychat/personal/ui/notion_chat_details_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

enum FixtureNotification { notify, mentionsOnly, dontNotify }

void main() {
  test(
    'failed native write displays the actual source rule and permits retry',
    () async {
      var actual = FixtureNotification.mentionsOnly;
      var fail = true;
      final binding = NotionNotificationBinding(
        read: () => actual,
        write: (value) async {
          if (fail) throw StateError('synthetic failure');
          actual = value;
        },
      );
      addTearDown(binding.dispose);
      await binding.set(FixtureNotification.dontNotify);
      expect(binding.value, FixtureNotification.mentionsOnly);
      expect(binding.error, isNotNull);
      expect(binding.canEdit, isTrue);
      fail = false;
      await binding.set(FixtureNotification.dontNotify);
      expect(binding.value, FixtureNotification.dontNotify);
      expect(binding.error, isNull);
      expect(binding.status, isNull);
    },
  );
  test(
    'acknowledged request waits source sync and rejects duplicate writes',
    () async {
      var actual = FixtureNotification.notify;
      var writes = 0;
      final acknowledgement = Completer<void>();
      final binding = NotionNotificationBinding(
        read: () => actual,
        write: (_) {
          writes++;
          return acknowledgement.future;
        },
      );
      addTearDown(binding.dispose);
      final pending = binding.set(FixtureNotification.dontNotify);
      await binding.set(FixtureNotification.mentionsOnly);
      expect(writes, 1);
      expect(binding.busy, isTrue);
      acknowledgement.complete();
      await pending;
      expect(binding.value, FixtureNotification.notify);
      expect(binding.pending, FixtureNotification.dontNotify);
      expect(binding.canEdit, isFalse);
      actual = FixtureNotification.dontNotify;
      binding.refresh();
      expect(binding.pending, isNull);
      expect(binding.canEdit, isTrue);
    },
  );
  test(
    'partially failed rule mutation does not fabricate the previous value',
    () async {
      var actual = FixtureNotification.dontNotify;
      final binding = NotionNotificationBinding(
        read: () => actual,
        write: (_) async {
          actual = FixtureNotification.notify;
          throw StateError('second network request failed');
        },
      );
      addTearDown(binding.dispose);
      await binding.set(FixtureNotification.mentionsOnly);
      expect(binding.value, FixtureNotification.notify);
      expect(binding.error, isNotNull);
    },
  );
}
