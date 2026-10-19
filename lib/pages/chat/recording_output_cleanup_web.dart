// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:js_interop';

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(JSString url);

Future<void> cleanupRecordingOutput({
  String? ownedNativePath,
  String? stoppedBlobUrl,
}) async {
  if (stoppedBlobUrl == null ||
      Uri.tryParse(stoppedBlobUrl)?.scheme != 'blob') {
    return;
  }
  _revokeObjectUrl(stoppedBlobUrl.toJS);
}
