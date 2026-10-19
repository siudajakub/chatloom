// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Registry of background (prefetch) media downloads keyed by `mxc://` URI.
///
/// Dependency-free on purpose: play paths ([RoundMediaLoader], the voice
/// player) await an in-flight prefetch of the same ciphertext instead of
/// starting a second network download, then read the encrypted media cache.
/// Tracked futures never complete with an error.
abstract final class MediaInflight {
  static final _pending = <String, Future<void>>{};

  /// Longest a background path (thumbnails) waits for a prefetch.
  static const maxWait = Duration(seconds: 30);

  /// Longest a user-started play waits for a prefetch before downloading
  /// itself: a slow prefetch must not hold a tap for half a minute.
  static const userWait = Duration(seconds: 4);

  /// How often a waiting play path re-checks [settle]'s `cancelled`.
  static const cancelPoll = Duration(milliseconds: 200);

  static Future<void>? of(Uri? mxc) =>
      mxc == null ? null : _pending[mxc.toString()];

  static bool contains(Uri mxc) => _pending.containsKey(mxc.toString());

  /// Waits for a tracked download of [mxc], or returns null synchronously
  /// when nothing is in flight. The wait ends at the first of: the download
  /// settling, [wait] elapsing (default [userWait]), or [cancelled] turning
  /// true (checked every [cancelPoll]). It never completes with an error.
  static Future<void>? settle(
    Uri? mxc, {
    Duration wait = userWait,
    bool Function()? cancelled,
  }) {
    final pending = of(mxc);
    if (pending == null) return null;
    if (cancelled?.call() == true) return Future<void>.value();
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final deadline = Timer(wait, finish);
    final poll = cancelled == null
        ? null
        : Timer.periodic(cancelPoll, (_) {
            if (cancelled()) finish();
          });
    unawaited(pending.then((_) => finish()));
    return done.future.whenComplete(() {
      deadline.cancel();
      poll?.cancel();
    });
  }

  static Future<void> track(Uri mxc, Future<void> work) {
    final key = mxc.toString();
    late final Future<void> tracked;
    tracked = work.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_pending[key], tracked)) _pending.remove(key);
    });
    _pending[key] = tracked;
    return tracked;
  }
}
