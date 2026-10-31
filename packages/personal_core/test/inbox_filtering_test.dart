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
  bool movedDown = false,
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
  movedDown: movedDown,
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
  test('Unread includes chats placed in Groups; All chats and the main '
      'list leave them out (CC-37)', () {
    InboxRecord placed(
      String id, {
      bool unread = true,
      ChatPlacement placement = ChatPlacement.groups,
      bool archived = false,
    }) => InboxRecord(
      representativeRoomId: id,
      entityId: id,
      displayName: 'Synthetic group',
      metadata: ConversationMetadata(entityId: id, archived: archived),
      networks: const ['telegram'],
      isGroup: true,
      placement: placement,
      unread: unread,
      lastActivity: now,
    );
    final items = [
      fixture('main-unread', unread: true),
      placed('groups-unread'),
      placed('groups-read', unread: false),
      placed('groups-archived', archived: true),
      placed('groups-ignored', placement: ChatPlacement.ignored),
    ];
    expect(
      projectInbox(
        items,
        filter: InboxFilter.unread,
      ).map((r) => r.entityId).toSet(),
      {'main-unread', 'groups-unread'},
    );
    expect(
      projectInbox(items, filter: InboxFilter.all).map((r) => r.entityId),
      ['main-unread'],
    );
    expect(projectInbox(items).map((r) => r.entityId), ['main-unread']);
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
  test('unread chats sort above newer read ones, below pins', () {
    final items = [
      fixture('newest', activity: now),
      fixture(
        'older-unread',
        unread: true,
        activity: now.subtract(const Duration(days: 2)),
      ),
      fixture('read', activity: now.subtract(const Duration(days: 1))),
      fixture(
        'old-unread',
        unread: true,
        activity: now.subtract(const Duration(days: 3)),
      ),
      fixture(
        'pinned',
        pin: 0,
        activity: now.subtract(const Duration(days: 9)),
      ),
    ];
    expect(projectInbox(items).map((r) => r.entityId), [
      'pinned',
      'older-unread',
      'old-unread',
      'newest',
      'read',
    ]);
  });
  test('a moved-down unread chat sorts by time among the read ones', () {
    final items = [
      fixture('newest', activity: now),
      fixture(
        'moved',
        unread: true,
        movedDown: true,
        activity: now.subtract(const Duration(days: 2)),
      ),
      fixture('read', activity: now.subtract(const Duration(days: 1))),
      fixture(
        'unread',
        unread: true,
        activity: now.subtract(const Duration(days: 3)),
      ),
      fixture(
        'pinned',
        pin: 0,
        movedDown: true,
        unread: true,
        activity: now.subtract(const Duration(days: 9)),
      ),
    ];
    final result = projectInbox(items);
    expect(result.map((r) => r.entityId), [
      'pinned',
      'unread',
      'newest',
      'read',
      'moved',
    ]);
    // Still unread: the Unread view keeps it, below the raised ones.
    expect(result.firstWhere((r) => r.entityId == 'moved').unread, isTrue);
    expect(
      projectInbox(items, filter: InboxFilter.unread).map((r) => r.entityId),
      ['pinned', 'unread', 'moved'],
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

  test('a pinned group placed under Groups stays on the main list', () {
    InboxRecord group(String id, {int? pin}) {
      final base = fixture(id, group: true, pin: pin, network: 'Telegram');
      return InboxRecord(
        representativeRoomId: id,
        entityId: id,
        displayName: base.displayName,
        metadata: base.metadata,
        networks: base.networks,
        isGroup: true,
        placement: ChatPlacement.groups,
        lastActivity: now,
      );
    }

    final pinned = group('pinned', pin: 0);
    final plain = group('plain');
    expect(projectInbox([pinned, plain]), [pinned]);
    expect(projectInbox([pinned, plain], filter: InboxFilter.groups), [
      pinned,
      plain,
    ]);
  });
}
