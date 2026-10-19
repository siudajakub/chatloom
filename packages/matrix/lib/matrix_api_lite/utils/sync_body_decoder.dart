// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import '../model/sync_update.dart';
import 'sync_body_runner_native.dart'
    if (dart.library.js_interop) 'sync_body_runner_web.dart';

/// `/sync` bodies above this size are decoded off the calling isolate.
const int largeSyncBodyBytes = 256 * 1024;

/// Decodes a `/sync` response body. Large catch-up responses would otherwise
/// block the UI isolate for the whole UTF-8 + JSON + model decode.
///
/// Kept top-level so the isolate closure captures only [body], never the API
/// instance or its HTTP client.
Future<SyncUpdate> decodeSyncUpdateBody(
  Uint8List body, {
  int threshold = largeSyncBodyBytes,
}) {
  if (body.length <= threshold) {
    return Future.sync(() => parseSyncUpdateBody(body));
  }
  return runSyncBodyDecode(() => parseSyncUpdateBody(body));
}

SyncUpdate parseSyncUpdateBody(Uint8List body) =>
    SyncUpdate.fromJson(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
