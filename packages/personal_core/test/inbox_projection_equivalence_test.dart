// SPDX-License-Identifier: AGPL-3.0-or-later
// projectInbox reads the clock once per projection, precomputes sort keys and
// skips search text for an empty query. Its results must equal the previous
// implementation's (kept below verbatim as the reference) on every view.
import 'dart:math';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

/// The implementation before the 2026-11-26 perf wave, unchanged.
List<InboxRecord> _reference(
  Iterable<InboxRecord> records, {
  InboxFilter filter = InboxFilter.inbox,
  String query = '',
  String? labelKey,
  Set<String> hiddenLabelKeys = const {},
}) {
  final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
  final result = records.where((record) {
    var placement = record.metadata.placement ?? record.placement;
    if (placement == ChatPlacement.groups && record.metadata.isPinned) {
      placement = ChatPlacement.inbox;
    }
    final ignored =
        record.metadata.ignored || placement == ChatPlacement.ignored;
    if (record.technical) {
      return filter == InboxFilter.technical &&
          terms.every(
            '${record.displayName} ${record.networks.join(' ')}'
                .toLowerCase()
                .contains,
          );
    }
    if (filter == InboxFilter.technical) return false;
    if (ignored && filter != InboxFilter.ignored) return false;
    if (!ignored && filter == InboxFilter.ignored) return false;
    final aside = placement == ChatPlacement.aside;
    if (!ignored && aside != (filter == InboxFilter.aside)) return false;
    final inInbox =
        placement == ChatPlacement.inbox &&
        !record.metadata.archived &&
        !record.metadata.lowPriority &&
        !record.labelKeys.any(hiddenLabelKeys.contains);
    final inGroups =
        placement == ChatPlacement.groups &&
        !record.metadata.archived &&
        !record.metadata.lowPriority &&
        !record.labelKeys.any(hiddenLabelKeys.contains);
    final matchesFilter = switch (filter) {
      InboxFilter.inbox => inInbox,
      InboxFilter.unread => (inInbox || inGroups) && record.unread,
      InboxFilter.drafts => inInbox && record.hasDraft,
      InboxFilter.unanswered => inInbox && record.unanswered,
      InboxFilter.direct => inInbox && !record.isGroup,
      InboxFilter.groups =>
        !record.metadata.archived &&
            !record.metadata.lowPriority &&
            record.isGroup &&
            !record.labelKeys.any(hiddenLabelKeys.contains),
      InboxFilter.ignored => ignored,
      InboxFilter.aside => aside,
      InboxFilter.technical => false,
      InboxFilter.label =>
        labelKey != null && record.labelKeys.contains(labelKey),
      InboxFilter.archive => record.metadata.archived,
      InboxFilter.lowPriority => record.metadata.lowPriority,
      InboxFilter.all => placement == ChatPlacement.inbox,
      InboxFilter.requests =>
        record.messageRequest && !record.metadata.archived,
    };
    final searchable = '${record.displayName}\n${record.networks.join(' ')}'
        .toLowerCase();
    return matchesFilter && terms.every(searchable.contains);
  }).toList();
  bool raised(InboxRecord r) =>
      r.unread && !r.metadata.muted && !r.movedDown;
  result.sort((a, b) {
    if (a.metadata.isPinned != b.metadata.isPinned) {
      return a.metadata.isPinned ? -1 : 1;
    }
    if (a.metadata.isPinned) {
      final pin = a.metadata.pinOrder!.compareTo(b.metadata.pinOrder!);
      if (pin != 0) return pin;
    } else if (raised(a) != raised(b)) {
      return raised(a) ? -1 : 1;
    }
    final time = (b.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0));
    return time != 0 ? time : a.entityId.compareTo(b.entityId);
  });
  return List.unmodifiable(result);
}

/// A seeded synthetic inbox covering pins, raised/muted/moved-down bands,
/// equal timestamps (entity tie-break), missing activity, timed mutes (far
/// past and far future, so the clock never sits on a boundary), placements,
/// labels, technical rooms and requests.
List<InboxRecord> _fixture(int seed, int count) {
  final random = Random(seed);
  final base = DateTime.utc(2026, 11, 1);
  const names = ['Ada Synthetic', 'Bob Fixture', 'Cleo Example', 'Dan Test'];
  const networks = ['whatsapp', 'telegram', 'signal', 'instagram'];
  T pick<T>(List<T> items) => items[random.nextInt(items.length)];
  return [
    for (var i = 0; i < count; i++)
      () {
        final id = 'entity-${random.nextInt(count * 4)}-$i';
        final muteChoice = random.nextInt(4);
        return InboxRecord(
          representativeRoomId: '!room-$i:example.invalid',
          entityId: id,
          displayName: '${pick(names)} $i',
          metadata: ConversationMetadata(
            entityId: id,
            pinOrder: random.nextInt(6) == 0 ? random.nextInt(3) : null,
            archived: random.nextInt(8) == 0,
            lowPriority: random.nextInt(9) == 0,
            muted: muteChoice > 0,
            mutedUntil: switch (muteChoice) {
              2 => DateTime.utc(2000),
              3 => DateTime.utc(2999),
              _ => null,
            },
            ignored: random.nextInt(15) == 0,
            placement: random.nextInt(4) == 0
                ? pick(ChatPlacement.values)
                : null,
            labelIds: random.nextBool() ? ['label-${random.nextInt(3)}'] : [],
          ),
          networks: [pick(networks), if (random.nextBool()) pick(networks)],
          labelKeys: random.nextBool() ? ['label-${random.nextInt(3)}'] : [],
          isGroup: random.nextBool(),
          technical: random.nextInt(12) == 0,
          messageRequest: random.nextInt(10) == 0,
          placement: pick(ChatPlacement.values),
          unread: random.nextBool(),
          hasDraft: random.nextInt(4) == 0,
          unanswered: random.nextBool(),
          movedDown: random.nextInt(5) == 0,
          // Few distinct times: many ties exercise the entity tie-break.
          lastActivity: random.nextInt(10) == 0
              ? null
              : base.add(Duration(minutes: random.nextInt(count ~/ 3 + 1))),
        );
      }(),
  ];
}

void main() {
  test('projectInbox orders and selects exactly like before', () {
    for (final seed in [1, 7, 42, 2026]) {
      final records = _fixture(seed, 300);
      for (final filter in InboxFilter.values) {
        for (final query in ['', '   ', 'ada', 'BOB fix', 'telegram', 'zz']) {
          for (final labelKey in [null, 'label-1']) {
            for (final hidden in [const <String>{}, const {'label-2'}]) {
              final expected = _reference(
                records,
                filter: filter,
                query: query,
                labelKey: labelKey,
                hiddenLabelKeys: hidden,
              ).map((r) => r.entityId).toList();
              final actual = projectInbox(
                records,
                filter: filter,
                query: query,
                labelKey: labelKey,
                hiddenLabelKeys: hidden,
              ).map((r) => r.entityId).toList();
              expect(
                actual,
                expected,
                reason: 'seed $seed, ${filter.name}, "$query", $labelKey',
              );
            }
          }
        }
      }
    }
  });

  test('an ended timed mute is raised like an unmuted chat', () {
    InboxRecord record(String id, {DateTime? until}) => InboxRecord(
      representativeRoomId: id,
      entityId: id,
      displayName: id,
      unread: true,
      lastActivity: DateTime.utc(2026, 11, id == 'a' ? 1 : 2),
      metadata: ConversationMetadata(
        entityId: id,
        muted: until != null,
        mutedUntil: until,
      ),
    );
    // "a" is older but unmuted (its timed mute ended): it is raised like "b".
    final result = projectInbox([
      record('a', until: DateTime.utc(2000)),
      record('b'),
      record('c', until: DateTime.utc(2999)),
    ]);
    expect(result.map((r) => r.entityId), ['b', 'a', 'c']);
  });
}
