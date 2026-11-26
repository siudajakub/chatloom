// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// ChatLoom: the in-memory inbound group sessions of a key manager, keyed by
/// room and session id and bounded in least-recently-used order.
///
/// Upstream kept every session it loaded or received until logout. Eviction
/// only drops the in-memory copy: the database row is unchanged and
/// `KeyManager.loadInboundGroupSession` reloads it on demand, which puts the
/// session in the same state as after an app restart.
///
/// - A held session ([hold]) is never evicted. The SDK holds a session from
///   loading it until it is used, and while a write of what changed in it
///   (replay indexes, `allowed_at_index`) is pending, so memory and database
///   agree whenever a session is dropped.
/// - Recently evicted ids are remembered ([wasEvicted]) so the key manager
///   can compare an incoming key with the stored copy exactly as if the
///   session had stayed in memory.
///
/// Vodozemac sessions are Rust opaque objects freed by their finalizer once
/// nothing references them; nothing is disposed here, so a caller that still
/// holds an evicted session keeps a valid object.
class InboundGroupSessionCache<V extends Object> {
  InboundGroupSessionCache({required int Function() maxSessions})
    : _maxSessions = maxSessions;

  /// Most sessions kept in memory; `0` or less disables the bound.
  final int Function() _maxSessions;

  /// Insertion-ordered (map and set literals are linked): oldest first.
  final _sessions = <(String, String), V>{};
  final _evicted = <(String, String)>{};
  final _holds = <(String, String), int>{};

  /// Evicted ids remembered per cached session; older evictions are treated
  /// like sessions not loaded since the app started.
  static const evictedMemoryFactor = 16;

  int get length => _sessions.length;

  /// Tests: remembered evicted ids.
  int get evictedLength => _evicted.length;

  /// Tests: whether the session is in memory, without touching its order.
  bool contains(String roomId, String sessionId) =>
      _sessions.containsKey((roomId, sessionId));

  /// The session if it is in memory; marks it as recently used.
  V? get(String roomId, String sessionId) {
    final key = (roomId, sessionId);
    final value = _sessions.remove(key);
    if (value != null) _sessions[key] = value;
    return value;
  }

  void put(String roomId, String sessionId, V value) {
    final key = (roomId, sessionId);
    _sessions.remove(key);
    _sessions[key] = value;
    _evicted.remove(key);
    _evict(keep: key);
  }

  /// Whether the session was dropped from memory earlier in this run and has
  /// not been loaded or stored again since.
  bool wasEvicted(String roomId, String sessionId) =>
      _evicted.contains((roomId, sessionId));

  /// Keeps the session in memory (once it is there) until the returned
  /// callback runs. Calling the callback again does nothing.
  void Function() hold(String roomId, String sessionId) {
    final key = (roomId, sessionId);
    _holds[key] = (_holds[key] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_holds[key] ?? 1) - 1;
      if (count > 0) {
        _holds[key] = count;
      } else {
        _holds.remove(key);
      }
    };
  }

  /// Drops every session and the evicted-id memory; holds stay with their
  /// holders.
  void clear() {
    _sessions.clear();
    _evicted.clear();
  }

  /// Drops the oldest unheld sessions beyond the bound (with 10 % slack, so
  /// it runs once per batch of inserts).
  void _evict({required (String, String) keep}) {
    final max = _maxSessions();
    if (max <= 0 || _sessions.length <= max + max ~/ 10) return;
    var excess = _sessions.length - max;
    final victims = <(String, String)>[];
    for (final key in _sessions.keys) {
      if (excess == 0) break;
      if (key == keep || _holds.containsKey(key)) continue;
      victims.add(key);
      excess--;
    }
    for (final key in victims) {
      _sessions.remove(key);
      _evicted.add(key);
    }
    final maxEvicted = max * evictedMemoryFactor;
    while (_evicted.length > maxEvicted) {
      _evicted.remove(_evicted.first);
    }
  }
}
