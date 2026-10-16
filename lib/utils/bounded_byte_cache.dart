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

  void removeWhere(bool Function(K key) matches) {
    for (final key in _entries.keys.where(matches).toList()) {
      _bytes -= _entries.remove(key)!.length;
    }
  }
}
