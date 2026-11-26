// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

/// Bounds retained encoded bytes independently of Flutter's decoded image cache.
class BoundedByteCache<K> {
  BoundedByteCache({required this.maxBytes, required this.maxEntries});
  final int maxBytes, maxEntries;
  final _entries = <K, Uint8List>{};
  int _bytes = 0;
  int get retainedBytes => _bytes;
  int get length => _entries.length;

  Uint8List? get(K key) {
    final data = _entries.remove(key);
    if (data != null) _entries[key] = data;
    return data;
  }

  void put(K key, Uint8List data) {
    _bytes -= _entries.remove(key)?.length ?? 0;
    if (data.length > maxBytes || maxEntries <= 0) return;
    _entries[key] = data;
    _bytes += data.length;
    while (_bytes > maxBytes || _entries.length > maxEntries) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  /// The largest retained entry whose key [matches] (marked as recently
  /// used), or null.
  Uint8List? largestWhere(bool Function(K key) matches) {
    K? best;
    var bestLength = -1;
    for (final entry in _entries.entries) {
      if (entry.value.length > bestLength && matches(entry.key)) {
        best = entry.key;
        bestLength = entry.value.length;
      }
    }
    return bestLength < 0 ? null : get(best as K);
  }

  void removeWhere(bool Function(K key) matches) {
    for (final key in _entries.keys.where(matches).toList()) {
      _bytes -= _entries.remove(key)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  /// Drops least recently used entries the [evictable] test allows until at
  /// most [bytes] remain (or nothing evictable is left).
  void trimTo(int bytes, {bool Function(K key)? evictable}) {
    if (_bytes <= bytes) return;
    for (final key in _entries.keys.toList()) {
      if (_bytes <= bytes) return;
      if (evictable != null && !evictable(key)) continue;
      _bytes -= _entries.remove(key)!.length;
    }
  }
}
