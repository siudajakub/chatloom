// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:matrix/matrix.dart' show Room;

abstract final class NotionMetadataActions {
  static bool canEdit(PersonalClient personal, String entity) =>
      personal.ready &&
      !personal.conflicts.containsKey('org:$entity') &&
      !personal.pending.values.any((op) => op.entityId == 'org:$entity');

  /// Mute and archive may follow a change that still awaits the worker's
  /// acknowledgement (an Undo right after the action): the durable replica
  /// coalesces them. Only an unresolved conflict blocks them.
  static bool canWrite(PersonalClient personal, String entity) =>
      personal.ready && !personal.conflicts.containsKey('org:$entity');

  static Future<void> setPinned(
    PersonalClient personal,
    String entity,
    bool pinned,
  ) async {
    if (!canEdit(personal, entity)) {
      throw StateError('Private changes are awaiting synchronization');
    }
    final metadata = InboxProjection(personal).metadataForEntity(entity);
    final orders = personal.values.entries
        .where((e) => e.key.startsWith('org:'))
        .map((e) => e.value['pinOrder'])
        .whereType<int>();
    final order = orders.isEmpty
        ? 0
        : orders.reduce((a, b) => a > b ? a : b) + 1;
    // Preserve archive source markers and all unrelated private properties.
    await personal.put(
      'org:$entity',
      {
        ...?personal.values['org:$entity'],
        ...metadata.setPin(pinned ? order : null).toJson(),
      }.cast<String, dynamic>(),
    );
  }

  /// The pin orders after the user dragged the visible pins into
  /// [visibleOrder] (FX-17): every pinned entity keeps its place except the
  /// visible ones, which take the visible slots in their new order (a
  /// network filter may hide pins in between), renumbered 0…n-1. Only the
  /// entities whose order changes are returned.
  static Map<String, int> pinOrdersAfterReorder(
    Map<String, int> current,
    List<String> visibleOrder,
  ) {
    final all = current.keys.toList()
      ..sort((a, b) {
        final byOrder = current[a]!.compareTo(current[b]!);
        return byOrder != 0 ? byOrder : a.compareTo(b);
      });
    final visible = visibleOrder.where(current.containsKey).toList();
    final shown = visible.toSet();
    var next = 0;
    final merged = [
      for (final entity in all)
        shown.contains(entity) ? visible[next++] : entity,
    ];
    return {
      for (final (index, entity) in merged.indexed)
        if (current[entity] != index) entity: index,
    };
  }

  /// Writes the pin order of [visibleOrder] (inbox entities, first first)
  /// to the private store, where pins live ([pinOrdersAfterReorder]).
  static Future<void> reorderPins(
    PersonalClient personal,
    List<String> visibleOrder,
  ) async {
    final current = <String, int>{
      for (final entry in personal.values.entries)
        if (entry.key.startsWith('org:') && entry.value['pinOrder'] is int)
          entry.key.substring(4): entry.value['pinOrder'] as int,
    };
    final changes = pinOrdersAfterReorder(current, visibleOrder);
    if (changes.keys.any((entity) => !canWrite(personal, entity))) {
      throw StateError('Private changes are awaiting synchronization');
    }
    final projection = InboxProjection(personal);
    for (final MapEntry(key: entity, value: order) in changes.entries) {
      await personal.put(
        'org:$entity',
        {
          ...?personal.values['org:$entity'],
          ...projection.metadataForEntity(entity).setPin(order).toJson(),
        }.cast<String, dynamic>(),
      );
    }
  }

  /// Private mute of [entity] until [until] (null: until unmuted), or
  /// unmute when [muted] is false. Other private properties are kept.
  static Future<void> setMuted(
    PersonalClient personal,
    String entity, {
    required bool muted,
    DateTime? until,
  }) async {
    if (!canWrite(personal, entity)) {
      throw StateError('Private changes are awaiting synchronization');
    }
    final metadata = InboxProjection(personal).metadataForEntity(entity);
    await personal.put(
      'org:$entity',
      {
        ...?personal.values['org:$entity'],
        ...metadata.setMuted(muted, until: until).toJson(),
      }.cast<String, dynamic>(),
    );
  }

  /// Archives [entity] (remembering the latest event of each of [sources],
  /// so new activity brings it back) or unarchives it.
  static Future<void> setArchived(
    PersonalClient personal,
    String entity,
    bool archived, {
    required Iterable<Room> sources,
  }) async {
    if (!canWrite(personal, entity)) {
      throw StateError('Private changes are awaiting synchronization');
    }
    final metadata = InboxProjection(
      personal,
    ).metadataForEntity(entity).setArchived(archived);
    await personal.put(
      'org:$entity',
      {
        ...?personal.values['org:$entity'],
        ...metadata.toJson(),
        if (archived) ...{
          'archivedAt': DateTime.now().toUtc().toIso8601String(),
          'archiveSources': {
            for (final room in sources) room.id: room.lastEvent?.eventId,
          },
        },
      }.cast<String, dynamic>(),
    );
  }
}
