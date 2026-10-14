// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 10, 4);
InboxRecord fixture(
  String id, {
  bool archived = false,
  bool lowPriority = false,
  int? pin,
  bool group = false,
  bool unread = false,
  bool draft = false,
  bool unanswered = false,
  Iterable<String> labels = const [],
  String name = 'Synthetic person',
  String network = 'WhatsApp',
  DateTime? activity,
}) => InboxRecord(
  representativeRoomId: id,
  entityId: id,
  displayName: name,
  metadata: ConversationMetadata(
    entityId: id,
    archived: archived,
    lowPriority: lowPriority,
    pinOrder: pin,
  ),
  networks: [network],
  labelKeys: labels,
  isGroup: group,
  unread: unread,
  hasDraft: draft,
  unanswered: unanswered,
  lastActivity: activity ?? now,
);

void main() {
  test('Inbox hides archive, low priority and hidden labels', () {
    final result = projectInbox(
      [
        fixture('visible'),
        fixture('archive', archived: true),
        fixture('low', lowPriority: true),
        fixture('hidden', labels: ['work']),
      ],
      hiddenLabelKeys: {'work'},
    );
    expect(result.map((r) => r.entityId), ['visible']);
  });
  test(
    'label view reveals its explicitly hidden and archived conversations',
    () {
      final hidden = fixture(
        'hidden',
        archived: true,
        lowPriority: true,
        labels: ['work'],
      );
      expect(
        projectInbox(
          [hidden],
          filter: InboxFilter.label,
          labelKey: 'work',
          hiddenLabelKeys: {'work'},
        ),
        [hidden],
      );
      expect(
        projectInbox([hidden], filter: InboxFilter.label, labelKey: 'unknown'),
        isEmpty,
      );
      expect(projectInbox([hidden], filter: InboxFilter.label), isEmpty);
    },
  );
  test('all view and archive have deliberate independent scopes', () {
    final items = [
      fixture('visible'),
      fixture('archive', archived: true),
      fixture('low', lowPriority: true),
    ];
    expect(projectInbox(items, filter: InboxFilter.all).length, 3);
    expect(
      projectInbox(items, filter: InboxFilter.archive).single.entityId,
      'archive',
    );
    expect(
      projectInbox(items, filter: InboxFilter.lowPriority).single.entityId,
      'low',
    );
  });
  test('unread filter cannot reintroduce hidden labels', () {
    final items = [
      fixture('unread', unread: true),
      fixture('read'),
      fixture('hidden', unread: true, labels: ['work']),
    ];
    expect(
      projectInbox(
        items,
        filter: InboxFilter.unread,
        hiddenLabelKeys: {'work'},
      ).map((r) => r.entityId),
      ['unread'],
    );
  });
  test('Drafts and Unanswered are distinct', () {
    final items = [
      fixture('draft', draft: true),
      fixture('incoming', unanswered: true),
      fixture('answered'),
    ];
    expect(
      projectInbox(items, filter: InboxFilter.drafts).single.entityId,
      'draft',
    );
    expect(
      projectInbox(items, filter: InboxFilter.unanswered).single.entityId,
      'incoming',
    );
  });
  test('people and groups never duplicate one another', () {
    final items = [fixture('person'), fixture('network-group', group: true)];
    expect(
      projectInbox(items, filter: InboxFilter.direct).single.entityId,
      'person',
    );
    expect(
      projectInbox(items, filter: InboxFilter.groups).single.entityId,
      'network-group',
    );
  });
  test('pin order precedes recency without relying on arrival order', () {
    final items = [
      fixture('newest', activity: now.add(const Duration(days: 1))),
      fixture('second-pin', pin: 1),
      fixture(
        'first-pin',
        pin: 0,
        activity: now.subtract(const Duration(days: 30)),
      ),
    ];
    expect(projectInbox(items).map((r) => r.entityId), [
      'first-pin',
      'second-pin',
      'newest',
    ]);
  });
  test('equal pin/time values have a stable order across devices', () {
    final a = fixture('a', pin: 0);
    final b = fixture('b', pin: 0);
    expect(
      projectInbox([b, a]).map((r) => r.entityId),
      projectInbox([a, b]).map((r) => r.entityId),
    );
  });
  test('keyword query covers the private display name and network', () {
    final items = [
      fixture('match', name: 'Family fixture'),
      fixture('other', name: 'Work fixture', network: 'Slack'),
    ];
    expect(
      projectInbox(items, query: 'FaMiLy WhatsApp').single.entityId,
      'match',
    );
    expect(projectInbox(items, query: 'family slack'), isEmpty);
  });
  test('record inputs and projected results cannot be mutated', () {
    final labels = <String>['work'];
    final record = fixture('immutable', labels: labels);
    labels.add('later');
    expect(record.labelKeys, {'work'});
    expect(() => projectInbox([record]).clear(), throwsUnsupportedError);
    expect(record.toString(), isNot(contains('Synthetic')));
  });
  test('activity derived unarchive preserves low priority exclusion', () {
    final metadata = ConversationMetadata(
      entityId: 'fixture',
      archived: true,
      lowPriority: true,
    ).onActivity();
    final record = InboxRecord(
      representativeRoomId: 'fixture',
      entityId: 'fixture',
      displayName: 'Fixture',
      metadata: metadata,
    );
    expect(projectInbox([record]), isEmpty);
    expect(projectInbox([record], filter: InboxFilter.lowPriority), [record]);
  });
}
