// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_core/personal_core.dart';

InboxRecord record(String id, {List<String> networks = const ['unknown']}) =>
    InboxRecord(
      representativeRoomId: id,
      entityId: id,
      displayName: id,
      networks: networks,
      metadata: ConversationMetadata(entityId: id),
    );

void main() {
  test(
    'merged conversation matches ANY source without changing representative',
    () {
      final merged = record(
        'representative-whatsapp',
        networks: ['whatsapp', 'slack'],
      );
      expect(notionMatchesNetwork(merged.networks, 'slack'), isTrue);
      expect(merged.representativeRoomId, 'representative-whatsapp');
      expect(notionMatchesNetwork(merged.networks, 'telegram'), isFalse);
      expect(notionMatchesNetwork(merged.networks, null), isTrue);
    },
  );
  test(
    'unknown network remains discoverable; selections are account-bound',
    () {
      expect(notionMatchesNetwork(record('unknown').networks, null), isTrue);
      final state = NotionAccountNetworkSelection();
      state.select('account-a', 'slack');
      state.select('account-b', 'telegram');
      expect(state.forAccount('account-a'), 'slack');
      state.select('account-a', null);
      expect(state.forAccount('account-a'), isNull);
      expect(state.forAccount('account-b'), 'telegram');
    },
  );
}
