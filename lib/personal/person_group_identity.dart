// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';

/// Structural identity of saved person groups.
///
/// The private store parses a new [PersonGroup] on every read
/// (`PersonalClient.groups`), so object identity changes with every store
/// notification (a saved draft, an acknowledgement, a heartbeat) although
/// nothing about the person changed. Compare with these instead.

/// The same sources in the same order: same account and room for each
/// member ([ConversationRef] equality).
bool samePersonMembers(PersonGroup a, PersonGroup b) {
  if (identical(a, b)) return true;
  final left = a.members, right = b.members;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// Everything a person page renders from its group: id, name, default
/// source, revision and the members including their network labels.
bool samePersonGroup(PersonGroup? a, PersonGroup? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.id != b.id ||
      a.name != b.name ||
      a.defaultRoomId != b.defaultRoomId ||
      a.revision != b.revision ||
      !samePersonMembers(a, b)) {
    return false;
  }
  for (var i = 0; i < a.members.length; i++) {
    if (a.members[i].network != b.members[i].network) return false;
  }
  return true;
}
