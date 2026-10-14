// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';

abstract final class NotionMetadataActions {
  static bool canEdit(PersonalClient personal, String entity) =>
      personal.ready &&
      !personal.pending.values.any((op) => op.entityId == 'org:$entity');

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
}
