// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

class PersonGroupCollection {
  final List<PersonGroup> groups;
  final int invalidCount;
  PersonGroupCollection(Iterable<PersonGroup> groups, this.invalidCount)
    : groups = List.unmodifiable(groups);
}

/// Malformed private metadata is preserved by the store. A bad entry must not
/// prevent opening other groups or route a group through another account.
PersonGroupCollection parsePersonGroups(
  Map<String, Map<String, dynamic>> values, {
  required String? accountId,
}) {
  final groups = <PersonGroup>[];
  var invalidCount = 0;
  for (final entry in values.entries.where(
    (entry) => entry.key.startsWith('person:'),
  )) {
    try {
      final group = PersonGroup.fromJson(entry.value);
      if (group.id.isEmpty ||
          entry.key != 'person:${group.id}' ||
          accountId == null ||
          group.members.any((member) => member.accountId != accountId)) {
        throw const FormatException('Invalid conversation group binding');
      }
      groups.add(group);
    } catch (_) {
      invalidCount++;
    }
  }
  return PersonGroupCollection(groups, invalidCount);
}
