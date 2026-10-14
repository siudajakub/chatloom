// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_core/personal_core.dart';

InboxRecord record(
  String id, {
  List<String> networks = const ['unknown'],
  bool archived = false,
  int? pin,
}) => InboxRecord(
  representativeRoomId: id,
  entityId: id,
  displayName: id,
  networks: networks,
  metadata: ConversationMetadata(
    entityId: id,
    archived: archived,
    pinOrder: pin,
  ),
);

void main() {
  test(
    'merged conversation matches ANY source without changing representative',
    () {
      final merged = record(
        'representative-whatsapp',
        networks: ['whatsapp', 'slack'],
      );
      final filtered = notionFilterRecords([merged], network: 'slack');
      expect(filtered.single, same(merged));
      expect(filtered.single.representativeRoomId, 'representative-whatsapp');
      expect(notionFilterRecords([merged], network: 'telegram'), isEmpty);
    },
  );
  test(
    'All chats removes network constraint and retains archive/hidden rules',
    () {
      final hidden = InboxRecord(
        representativeRoomId: 'hidden',
        entityId: 'hidden',
        displayName: 'hidden',
        labelKeys: ['private'],
        metadata: ConversationMetadata(entityId: 'hidden'),
      );
      final records = [
        record('visible'),
        record('archive', archived: true),
        hidden,
      ];
      expect(
        notionFilterRecords(
          records,
          hiddenLabelKeys: {'private'},
        ).map((r) => r.entityId),
        ['visible'],
      );
    },
  );
  test(
    'pin order comes from metadata and applies to matching source filters',
    () {
      final records = [
        record('late', pin: 9, networks: ['slack']),
        record('early', pin: 1, networks: ['whatsapp', 'slack']),
        record('normal'),
      ];
      expect(
        notionFilterRecords(records, network: 'slack').map((r) => r.entityId),
        ['early', 'late'],
      );
    },
  );
  test(
    'unknown network remains discoverable; selections are account-bound',
    () {
      expect(notionFilterRecords([record('unknown')]), hasLength(1));
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
