// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'private_directories_stub.dart'
    if (dart.library.ffi) 'private_directories_native.dart'
    as native;

/// Name of a new voice recording in the temporary directory. It carries the
/// recording process, so a later start can tell a crashed recording's
/// leftover from a live one ([removeStaleVoiceRecordings]).
String voiceRecordingName(String id, String extension) =>
    'voice_${pid}_$id.$extension';

final _named = RegExp(
  r'^voice_(\d{1,10})_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,8}$',
);
final _legacy = RegExp(
  r'^voice_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,8}$',
);

/// Removes plaintext voice recordings that a dead process left in
/// [temporary] (killed or crashed while recording; a finished recording
/// session deletes its own file). Only ChatLoom's own name patterns, only
/// regular files, and never a file whose process may still be running.
/// Names of earlier versions carry no process: none of them belongs to this
/// process, which only writes [voiceRecordingName]s. Returns how many files
/// were removed; never throws.
Future<int> removeStaleVoiceRecordings(Directory temporary) async {
  var removed = 0;
  try {
    await for (final entity in temporary.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final owner = _named.firstMatch(name)?[1];
      if (owner == null && !_legacy.hasMatch(name)) continue;
      if (owner != null) {
        final process = int.tryParse(owner);
        if (process == null ||
            process == pid ||
            native.PrivateDirectories.processMayBeAlive(process)) {
          continue;
        }
      }
      try {
        await entity.delete();
        removed++;
      } on FileSystemException {
        // Gone already, or not ours to remove: the next start tries again.
      }
    }
  } catch (_) {
    // An unreadable temporary directory leaves nothing to sweep.
  }
  return removed;
}
