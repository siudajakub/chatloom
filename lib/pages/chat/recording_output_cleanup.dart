// SPDX-License-Identifier: AGPL-3.0-or-later
import 'recording_output_cleanup_native.dart'
    if (dart.library.js_interop) 'recording_output_cleanup_web.dart'
    as platform;

typedef RecordingOutputCleanup =
    Future<void> Function({String? ownedNativePath, String? stoppedBlobUrl});

/// Release only this session's output, never a path reported by a codec.
Future<void> cleanupRecordingOutput({
  String? ownedNativePath,
  String? stoppedBlobUrl,
}) => platform.cleanupRecordingOutput(
  ownedNativePath: ownedNativePath,
  stoppedBlobUrl: stoppedBlobUrl,
);
