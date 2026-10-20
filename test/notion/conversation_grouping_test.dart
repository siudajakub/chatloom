import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationGroupingItem item({
  String account = 'account-a',
  String source = 'room-a',
  String sender = 'sender-a',
  bool outgoing = false,
  DateTime? time,
  String? thread,
  String state = 'sent',
  bool boundary = false,
  bool startsSeries = false,
}) => ConversationGroupingItem(
  accountId: account,
  sourceId: source,
  senderId: sender,
  outgoing: outgoing,
  timestamp: time ?? DateTime(2026, 10, 16, 12),
  threadId: thread,
  deliveryState: state,
  boundary: boundary,
  startsSeries: startsSeries,
);

void main() {
  final older = item(time: DateTime(2026, 10, 16, 11, 59));
  final current = item();
  final newer = item(time: DateTime(2026, 10, 16, 12, 1));

  test('single first middle and last use ascending chronology', () {
    expect(
      conversationGroupPosition(item: current),
      ConversationGroupPosition.single,
    );
    expect(
      conversationGroupPosition(item: current, newer: newer),
      ConversationGroupPosition.first,
    );
    expect(
      conversationGroupPosition(item: current, older: older, newer: newer),
      ConversationGroupPosition.middle,
    );
    expect(
      conversationGroupPosition(item: current, older: older),
      ConversationGroupPosition.last,
    );
  });

  test(
    'reversed list children are translated into chronological neighbours',
    () {
      final reverseEvents = [newer, current, older];
      expect(
        conversationGroupPosition(
          item: reverseEvents[1],
          older: reverseEvents[2],
          newer: reverseEvents[0],
        ),
        ConversationGroupPosition.middle,
      );
      // A wrongly ordered caller must not join a negative time gap.
      expect(
        conversationGroupPosition(item: current, older: newer, newer: older),
        ConversationGroupPosition.single,
      );
    },
  );

  test('five minute threshold is inclusive and larger gaps break', () {
    expect(
      conversationGroupPosition(
        item: current,
        newer: item(time: DateTime(2026, 10, 16, 12, 5)),
      ),
      ConversationGroupPosition.first,
    );
    expect(
      conversationGroupPosition(
        item: current,
        newer: item(time: DateTime(2026, 10, 16, 12, 5, 0, 1)),
      ),
      ConversationGroupPosition.single,
    );
  });

  test('local midnight always breaks even inside five minutes', () {
    expect(
      conversationGroupPosition(
        item: item(time: DateTime(2026, 10, 16, 23, 59)),
        newer: item(time: DateTime(2026, 10, 17, 0, 1)),
      ),
      ConversationGroupPosition.single,
    );
  });

  final differences = <String, ConversationGroupingItem>{
    'account': item(account: 'account-b'),
    'source even with the same sender': item(source: 'room-b'),
    'sender': item(sender: 'sender-b'),
    'direction': item(outgoing: true),
    'thread': item(thread: 'thread-a'),
    'pending state': item(state: 'pending'),
    'error state': item(state: 'error'),
    'separator or read marker': item(boundary: true),
  };
  for (final entry in differences.entries) {
    test('${entry.key} splits both chronological edges', () {
      expect(
        conversationGroupPosition(item: current, older: entry.value),
        ConversationGroupPosition.single,
      );
      expect(
        conversationGroupPosition(item: current, newer: entry.value),
        ConversationGroupPosition.single,
      );
    });
  }

  test('boundary item does not join otherwise compatible neighbours', () {
    expect(
      conversationGroupPosition(
        item: item(boundary: true),
        older: older,
        newer: newer,
      ),
      ConversationGroupPosition.single,
    );
  });

  test('compatible pending state groups but error transition does not', () {
    expect(
      conversationGroupPosition(
        item: item(state: 'pending'),
        newer: item(state: 'pending'),
      ),
      ConversationGroupPosition.first,
    );
    expect(
      conversationGroupPosition(
        item: item(state: 'pending'),
        newer: item(state: 'error'),
      ),
      ConversationGroupPosition.single,
    );
  });

  test(
    'unloaded pagination edge stays closed until neighbour is available',
    () {
      expect(
        conversationGroupPosition(item: current, newer: newer),
        ConversationGroupPosition.first,
      );
      expect(
        conversationGroupPosition(item: current, older: older, newer: newer),
        ConversationGroupPosition.middle,
      );
      expect(
        conversationGroupPosition(
          item: current,
          older: item(boundary: true),
          newer: newer,
        ),
        ConversationGroupPosition.first,
      );
    },
  );

  test('a reply opens a new group but later messages join it', () {
    final reply = item(startsSeries: true);
    expect(
      conversationGroupPosition(item: reply, older: older, newer: newer),
      ConversationGroupPosition.first,
    );
    expect(
      conversationGroupPosition(item: older, newer: reply),
      ConversationGroupPosition.single,
    );
    expect(
      conversationGroupPosition(
        item: newer,
        older: reply,
      ),
      ConversationGroupPosition.last,
    );
  });
}
