// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_worker/src/heartbeat_schedule.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 17, 12);
  Map<String, Object?> payload({int pending = 0}) => {
    'healthy': true,
    'verified': true,
    'pending': pending,
  };

  test('first heartbeat is immediate, then one per five minutes', () {
    final schedule = HeartbeatSchedule();
    expect(schedule.due(start, payload()), isTrue);
    schedule.sent(start, payload());
    var sent = 1;
    // The daemon loop runs every few seconds; an unchanged payload is only
    // re-sent as the periodic proof of life.
    for (var second = 2; second <= 3600; second += 2) {
      final now = start.add(Duration(seconds: second));
      if (schedule.due(now, payload())) {
        schedule.sent(now, payload());
        sent++;
      }
    }
    expect(sent, 13, reason: 'One hour: the first plus every five minutes');
    expect(
      HeartbeatSchedule.interval * 2 + const Duration(minutes: 1),
      const Duration(minutes: 11),
      reason: 'Matches the client freshness window (WorkerReadiness)',
    );
  });

  test('payload change is sent promptly but never more than once a minute', () {
    final schedule = HeartbeatSchedule()..sent(start, payload());
    final soon = start.add(const Duration(seconds: 20));
    expect(schedule.due(soon, payload(pending: 1)), isFalse);
    final later = start.add(HeartbeatSchedule.minimumSpacing);
    expect(schedule.due(later, payload(pending: 1)), isTrue);
    schedule.sent(later, payload(pending: 1));
    expect(
      schedule.due(later.add(const Duration(minutes: 2)), payload(pending: 1)),
      isFalse,
    );
    expect(
      schedule.due(later.add(const Duration(minutes: 2)), payload(pending: 2)),
      isTrue,
    );
  });

  test('key order does not count as a change', () {
    final schedule = HeartbeatSchedule()..sent(start, {'a': 1, 'b': 2});
    expect(
      schedule.due(start.add(const Duration(minutes: 2)), {'b': 2, 'a': 1}),
      isFalse,
    );
  });

  test('a clock stepping backwards does not silence the worker', () {
    final schedule = HeartbeatSchedule()..sent(start, payload());
    expect(
      schedule.due(start.subtract(const Duration(hours: 1)), payload()),
      isTrue,
    );
  });
}
