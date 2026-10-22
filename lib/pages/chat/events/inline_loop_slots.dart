// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// The app-wide budget of native muted-loop players (timeline GIFs and
/// video stickers, GIF search results in the composer panel): at most
/// [max] exist at once; the oldest gives way to a newer one.
abstract final class InlineLoopSlots {
  /// Native players alive at once across the app.
  static const max = 3;

  /// Owner → its give-way callback, oldest first.
  static final _live = <Object, VoidCallback>{};

  /// Players alive now.
  static int get live => _live.length;

  /// Takes a slot for [owner]. When all are taken, the oldest owner is
  /// removed first and told to give way ([giveWay] of that owner runs
  /// synchronously, so players starting in the same frame never exceed
  /// [max] together).
  static void acquire(Object owner, VoidCallback giveWay) {
    _live.remove(owner);
    while (_live.length >= max) {
      final oldest = _live.keys.first;
      final evict = _live.remove(oldest)!;
      evict();
    }
    _live[owner] = giveWay;
  }

  /// Frees [owner]'s slot (a no-op when it holds none).
  static void release(Object owner) => _live.remove(owner);

  @visibleForTesting
  static void debugReset() => _live.clear();
}
