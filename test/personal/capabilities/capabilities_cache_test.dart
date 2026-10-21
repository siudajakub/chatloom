// SPDX-License-Identifier: AGPL-3.0-or-later
// Bridge capability declarations are parsed once per state revision (review
// R10) and never served stale after the bridge state changes. Fictional
// offline fixtures only.
import 'package:chatloom/personal/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';

void main() {
  late ConversationRoom room;
  setUp(() {
    room = ConversationRoom(ConversationClient(), '!caps:example.invalid');
  });

  CapabilityStatus reply() => RoomCapabilities.declared(
    room,
  ).evidence(BridgeFeature.reply).result.status;

  test('repeated reads reuse one parsed declaration', () {
    final first = RoomCapabilities.declared(room);
    expect(identical(RoomCapabilities.declared(room), first), isTrue);
    expect(reply(), CapabilityStatus.available);
    // Each state key has its own entry.
    final keyed = RoomCapabilities.declared(room, stateKey: 'fixture');
    expect(
      identical(RoomCapabilities.declared(room, stateKey: 'fixture'), keyed),
      isTrue,
    );
  });

  test('a new room_features event is picked up at once', () {
    expect(reply(), CapabilityStatus.available);
    room.state(bridgeFeaturesEventType, {'reply': -2}, key: 'fixture');
    expect(reply(), CapabilityStatus.unavailable);
    room.state(bridgeFeaturesEventType, {'reply': 2}, key: 'fixture');
    expect(reply(), CapabilityStatus.available);
  });

  test('bridge state changes re-select the declaring bridge', () {
    // A second features source without a matching bridge stays ignored...
    room.state(bridgeFeaturesEventType, {'reply': -2}, key: 'other');
    expect(reply(), CapabilityStatus.available);
    // ...until a second bridge appears: two sources need a state key.
    room.state('m.bridge', {
      'protocol': {'id': 'other'},
    }, key: 'other');
    expect(reply(), CapabilityStatus.unverified);
    expect(
      RoomCapabilities.declared(
        room,
        stateKey: 'other',
      ).evidence(BridgeFeature.reply).result.status,
      CapabilityStatus.unavailable,
    );
  });

  test('a redaction that rewrites the event in place invalidates it', () {
    expect(reply(), CapabilityStatus.available);
    final features = room.states[bridgeFeaturesEventType]!['fixture']! as Event;
    features.setRedactionEvent(
      Event(
        room: room,
        type: EventTypes.Redaction,
        eventId: r'$redaction',
        senderId: room.client.userID!,
        originServerTs: DateTime.utc(2026),
        content: {'redacts': features.eventId},
      ),
    );
    expect(reply(), CapabilityStatus.unverified);
  });
}
