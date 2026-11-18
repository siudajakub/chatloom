// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Measures the homeserver's upload limit (`m.upload.size`) for a round
/// video preflight.
///
/// A fresh request is tried twice; a single dropped request (a phone waking
/// up, a network handover) used to refuse the round with "Couldn't confirm
/// the server's upload limit". When both fail, the last limit this client
/// measured within [reuseFor] is reused: the limit is server configuration
/// and rarely changes, and the upload itself still fails closed if it did.
/// Null means unknown (no limit published, or nothing measured yet), which
/// keeps refusing the round as before.
abstract final class UploadLimitProbe {
  static const Duration reuseFor = Duration(hours: 24);
  static const Duration retryDelay = Duration(milliseconds: 600);

  static final _measured = Expando<(int, DateTime)>('roundUploadLimit');

  /// Tests replace the request.
  static Future<int?> Function(Client client) fetch = _fetch;

  static Future<int?> _fetch(Client client) async => (await client.getConfig(
    cacheLifetime: Duration.zero,
    throwOnUpdateFailure: true,
  )).mUploadSize;

  /// The measured limit in bytes, or null when it is unknown. Throws only
  /// when the server could not be asked and nothing recent is known.
  static Future<int?> measure(Client client, {DateTime? now}) async {
    Object? failure;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay);
      try {
        final limit = await fetch(client);
        if (limit == null || limit <= 0) {
          _measured[client] = null;
          return null;
        }
        _measured[client] = (limit, now ?? DateTime.now());
        return limit;
      } catch (error) {
        failure = error;
      }
    }
    final last = _measured[client];
    if (last != null &&
        (now ?? DateTime.now()).difference(last.$2) < reuseFor) {
      return last.$1;
    }
    throw failure!;
  }

  static void forget(Client client) => _measured[client] = null;
}
