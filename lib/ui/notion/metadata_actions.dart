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
