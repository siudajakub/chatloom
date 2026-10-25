// SPDX-License-Identifier: AGPL-3.0-or-later

/// Back-off for inbox preview repairs (`Room.refreshLastEvent`).
///
/// A failed refresh leaves the SDK's "Loading… Please wait." placeholder in
/// the room, and the placeholder is stored, so it also comes back on the
/// next launch. The inbox row retries the refresh; this keeps the attempts
/// per room across row rebuilds and remounts (scrolling), so an offline
/// phone does not hammer the homeserver.
library;

import 'package:matrix/matrix.dart';

/// Whether an inbox row has to refresh this preview: the stored
/// "Loading… Please wait." placeholder, or an event that is not a message
/// (a bridge report).
bool needsPreviewRepair(Event? event, Set<String> previewTypes) =>
    event != null &&
    (event.type == EventTypes.refreshingLastEvent ||
        !previewTypes.contains(event.type));

class PreviewRepairBackoff {
  PreviewRepairBackoff({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final instance = PreviewRepairBackoff();

  static const first = Duration(seconds: 10);
  static const cap = Duration(minutes: 5);

  final DateTime Function() _now;
  final _failures = <String, int>{};
  final _notBefore = <String, DateTime>{};

  /// How long the room has to wait before the next attempt; zero when it may
  /// try now.
  Duration wait(String roomId) {
    final notBefore = _notBefore[roomId];
    if (notBefore == null) return Duration.zero;
    final left = notBefore.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Records a failed attempt and returns the delay before the next one:
  /// [first], doubling up to [cap].
  Duration failed(String roomId) {
    final failures = (_failures[roomId] ?? 0) + 1;
    _failures[roomId] = failures;
    var delay = first * (1 << (failures - 1).clamp(0, 16));
    if (delay > cap) delay = cap;
    _notBefore[roomId] = _now().add(delay);
    return delay;
  }

  void succeeded(String roomId) {
    _failures.remove(roomId);
    _notBefore.remove(roomId);
  }
}
