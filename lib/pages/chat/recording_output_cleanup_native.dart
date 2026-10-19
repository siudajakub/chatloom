// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

Future<void> cleanupRecordingOutput({
  String? ownedNativePath,
  String? stoppedBlobUrl,
}) async {
  if (ownedNativePath == null) return;
  final file = File(ownedNativePath);
  try {
    await file.delete();
  } on FileSystemException {
    // SDK cancel may already have removed it. No recursive directory cleanup.
    if (await FileSystemEntity.type(ownedNativePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      rethrow;
    }
  }
}
