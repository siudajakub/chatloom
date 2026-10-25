// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/preview_repair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

void main() {
  group('needsPreviewRepair', () {
    final client = Client('preview repair fixture', database: _Database());
    final room = Room(id: '!fixture:example.invalid', client: client);
    Event event(String type) => Event(
      type: type,
      content: const {'body': 'x'},
      room: room,
      eventId: type,
      senderId: '@owner:example.invalid',
      originServerTs: DateTime.utc(2026),
    );
    final types = client.roomPreviewLastEvents;

    test('a stored placeholder is repaired', () {
      expect(
        needsPreviewRepair(event(EventTypes.refreshingLastEvent), types),
        isTrue,
      );
    });

    test('a bridge report is repaired', () {
      expect(
        needsPreviewRepair(event('com.beeper.message_send_status'), types),
        isTrue,
      );
    });

    test('messages and empty rooms are left alone', () {
      expect(needsPreviewRepair(event(EventTypes.Message), types), isFalse);
      expect(needsPreviewRepair(event(EventTypes.Encrypted), types), isFalse);
      expect(needsPreviewRepair(null, types), isFalse);
    });
  });

  group('PreviewRepairBackoff', () {
    late DateTime now;
    late PreviewRepairBackoff backoff;
    setUp(() {
      now = DateTime.utc(2026);
      backoff = PreviewRepairBackoff(now: () => now);
    });

    test('a room may try at once until it fails', () {
      expect(backoff.wait('!a'), Duration.zero);
    });

    test('failures double the wait up to the cap', () {
      expect(backoff.failed('!a'), PreviewRepairBackoff.first);
      expect(backoff.wait('!a'), PreviewRepairBackoff.first);
      expect(backoff.failed('!a'), PreviewRepairBackoff.first * 2);
      for (var i = 0; i < 20; i++) {
        backoff.failed('!a');
      }
      expect(backoff.failed('!a'), PreviewRepairBackoff.cap);
      expect(backoff.wait('!b'), Duration.zero);
    });

    test('the wait runs out and a success resets the back-off', () {
      backoff.failed('!a');
      now = now.add(PreviewRepairBackoff.first);
      expect(backoff.wait('!a'), Duration.zero);
      backoff.failed('!a');
      backoff.succeeded('!a');
      expect(backoff.wait('!a'), Duration.zero);
      expect(backoff.failed('!a'), PreviewRepairBackoff.first);
    });
  });
}
