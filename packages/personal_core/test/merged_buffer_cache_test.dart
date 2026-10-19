// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const _a = ConversationRef(accountId: 'fixture', roomId: 'a');
const _b = ConversationRef(accountId: 'fixture', roomId: 'b');
final _now = DateTime.utc(2026, 10, 17, 12);

MergedEvent<String> _event(
  ConversationRef ref,
  int minutesAgo, {
  String id = 'e',
  int revision = 0,
  String value = 'fixture',
}) => MergedEvent(
  source: SourceEventRef(conversation: ref, eventId: '$id-$minutesAgo'),
  timestamp: _now.subtract(Duration(minutes: minutesAgo)),
  isOutgoing: false,
  value: value,
  revision: revision,
);

void main() {
  test('sorted and covered views are cached until the buffer changes', () {
    final buffer = MergedTimelineBuffer<String>([_a, _b]);
    buffer.addPage(member: _a, events: [_event(_a, 1)], hasMore: false);
    buffer.addPage(member: _b, events: [_event(_b, 2)], hasMore: false);
    final events = buffer.events;
    final covered = buffer.coveredEvents;
    expect(identical(buffer.events, events), isTrue);
    expect(identical(buffer.coveredEvents, covered), isTrue);
    expect(covered.map((e) => e.source.conversation), [_b, _a]);

    buffer.addLive(_event(_a, 0, id: 'live'));
    expect(identical(buffer.events, events), isFalse);
    expect(buffer.coveredEvents.length, 3);
    expect(buffer.coveredEvents.last.source.eventId, 'live-0');

    // A stale revision is ignored and keeps the cached view.
    final current = buffer.events;
    buffer.addLive(_event(_a, 1, revision: 0, value: 'stale'));
    expect(identical(buffer.events, current), isTrue);
    buffer.addLive(_event(_a, 1, revision: 1, value: 'edited'));
    expect(identical(buffer.events, current), isFalse);
    expect(
      buffer.events.firstWhere((e) => e.source.eventId == 'e-1').value,
      'edited',
    );
  });

  test('merged event key matches its source key', () {
    final event = _event(_a, 3);
    expect(event.key, event.source.key);
  });
}
