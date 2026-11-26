// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqflite.dart';

import 'zone_transaction_mixin.dart';

/// Key-Value store abstraction over Sqflite so that the sdk database can use
/// a single interface for all platforms. API is inspired by Hive.
class BoxCollection with ZoneTransactionMixin {
  final Database _db;
  final Set<String> boxNames;
  final String name;

  BoxCollection(this._db, this.boxNames, this.name);

  static Future<BoxCollection> open(
    String name,
    Set<String> boxNames, {
    Object? sqfliteDatabase,
    DatabaseFactory? sqfliteFactory,
    dynamic idbFactory,
    int version = 1,
  }) async {
    if (sqfliteDatabase is! Database) {
      throw ('You must provide a Database `sqfliteDatabase` for use on native.');
    }
    final batch = sqfliteDatabase.batch();
    for (final name in boxNames) {
      batch.execute(
        'CREATE TABLE IF NOT EXISTS $name (k TEXT PRIMARY KEY NOT NULL, v TEXT)',
      );
      batch.execute(
        'DROP INDEX IF EXISTS k_index',
      ); // Previously we have created a redundant index. We can safely remove it.
    }
    await batch.commit(noResult: true);
    return BoxCollection(sqfliteDatabase, boxNames, name);
  }

  Box<V> openBox<V>(String name) {
    if (!boxNames.contains(name)) {
      throw ('Box with name $name is not in the known box names of this collection.');
    }
    return Box<V>(name, this);
  }

  Batch? _activeBatch;

  /// Transactions started and not yet committed. While any is open, cached
  /// values may be newer than the database, so boxes must not evict them.
  int _openTransactions = 0;

  /// Whether a box may drop cached values (nothing uncommitted is pending).
  bool get _canEvict => _activeBatch == null && _openTransactions == 0;

  Future<void> transaction(
    Future<void> Function() action, {
    List<String>? boxNames,
    bool readOnly = false,
  }) => zoneTransaction(() async {
    _openTransactions++;
    try {
      final batch = _db.batch();
      _activeBatch = batch;
      await action();
      _activeBatch = null;
      await batch.commit(noResult: true);
    } finally {
      _openTransactions--;
    }
  });

  Future<void> clear() => transaction(() async {
    for (final name in boxNames) {
      await _db.delete(name);
    }
  });

  Future<void> close() => zoneTransaction(_db.close);

  @Deprecated('use collection.deleteDatabase now')
  static Future<void> delete(String path, [dynamic factory]) =>
      (factory ?? databaseFactory).deleteDatabase(path);

  Future<void> deleteDatabase(String path, [dynamic factory]) async {
    await close();
    await (factory ?? databaseFactory).deleteDatabase(path);
  }
}

class Box<V> {
  final String name;
  final BoxCollection boxCollection;

  /// Values read or written recently, in least-recently-used order (a
  /// [LinkedHashMap]: oldest first). Bounded by [maxCachedValues]; upstream
  /// kept every value ever read or written until logout, which grew a
  /// long-running client by hundreds of MB (events, receipts, presences).
  final Map<String, V?> _quickAccessCache = {};

  /// Most values kept in [_quickAccessCache]; older ones are read again
  /// from the database when needed.
  static int maxCachedValues = 2000;

  void _touch(String key, V? value) {
    _quickAccessCache.remove(key);
    _quickAccessCache[key] = value;
    _evict();
  }

  /// Drops the oldest values beyond [maxCachedValues] (with 10 % slack, so
  /// it runs once per batch of inserts), but never while a transaction may
  /// hold values that are not committed yet.
  void _evict() {
    final max = maxCachedValues;
    if (_quickAccessCache.length <= max + max ~/ 10) return;
    if (!boxCollection._canEvict) return;
    final excess = _quickAccessCache.length - max;
    final oldest = _quickAccessCache.keys.take(excess).toList();
    for (final key in oldest) {
      _quickAccessCache.remove(key);
    }
  }

  /// Forgets a key set that outgrew [maxCachedValues] once no transaction
  /// is open (inside one it may hold keys not committed yet).
  void _dropLargeKeySet() {
    final keys = _quickAccessCachedKeys;
    if (keys != null &&
        keys.length > maxCachedValues &&
        boxCollection._canEvict) {
      _quickAccessCachedKeys = null;
    }
  }

  /// Tests: values cached now.
  int get debugCachedValues => _quickAccessCache.length;

  /// _quickAccessCachedKeys is only used to make sure that if you fetch all keys from a
  /// box, you do not need to have an expensive read operation twice. There is
  /// no other usage for this at the moment. So the cache is never partial.
  /// Once the keys are cached, they need to be updated when changed in put and
  /// delete* so that the cache does not become outdated.
  Set<String>? _quickAccessCachedKeys;

  static const Set<Type> allowedValueTypes = {
    List<dynamic>,
    Map<dynamic, dynamic>,
    String,
    int,
    double,
    bool,
  };

  Box(this.name, this.boxCollection) {
    if (!allowedValueTypes.any((type) => V == type)) {
      throw Exception(
        'Illegal value type for Box: "$V". Must be one of $allowedValueTypes',
      );
    }
  }

  String? _toString(V? value) {
    if (value == null) return null;
    switch (V) {
      case const (List<dynamic>):
      case const (Map<dynamic, dynamic>):
        return jsonEncode(value);
      case const (String):
      case const (int):
      case const (double):
      case const (bool):
      default:
        return value.toString();
    }
  }

  V? _fromString(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw Exception(
        'Wrong database type! Expected String but got one of type ${value.runtimeType}',
      );
    }
    switch (V) {
      case const (int):
        return int.parse(value) as V;
      case const (double):
        return double.parse(value) as V;
      case const (bool):
        return (value == 'true') as V;
      case const (List<dynamic>):
        return List.unmodifiable(jsonDecode(value)) as V;
      case const (Map<dynamic, dynamic>):
        return Map.unmodifiable(jsonDecode(value)) as V;
      case const (String):
      default:
        return value as V;
    }
  }

  Future<List<String>> getAllKeys([Transaction? txn]) async {
    if (_quickAccessCachedKeys != null) return _quickAccessCachedKeys!.toList();

    final executor = txn ?? boxCollection._db;

    final result = await executor.query(name, columns: ['k']);
    final keys = result.map((row) => row['k'] as String).toList();

    // ChatLoom: only small boxes keep their key set. For events or room
    // members it would pin every key ever stored and grow with each write.
    if (keys.length <= maxCachedValues) _quickAccessCachedKeys = keys.toSet();
    return keys;
  }

  Future<Map<String, V>> getAllValues([Transaction? txn]) async {
    final executor = txn ?? boxCollection._db;

    final result = await executor.query(name);
    return Map.fromEntries(
      result.map(
        (row) => MapEntry(row['k'] as String, _fromString(row['v']) as V),
      ),
    );
  }

  Future<V?> get(String key, [Transaction? txn]) async {
    if (_quickAccessCache.containsKey(key)) {
      final cached = _quickAccessCache.remove(key);
      _quickAccessCache[key] = cached;
      return cached;
    }

    final executor = txn ?? boxCollection._db;

    final result = await executor.query(
      name,
      columns: ['v'],
      where: 'k = ?',
      whereArgs: [key],
    );

    final value = result.isEmpty ? null : _fromString(result.single['v']);
    // A write during the query (another zone) is newer: keep it.
    if (!_quickAccessCache.containsKey(key)) _touch(key, value);
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [Transaction? txn]) async {
    if (!keys.any((key) => !_quickAccessCache.containsKey(key))) {
      return keys.map((key) => _quickAccessCache[key]).toList();
    }

    // The SQL operation might fail with more than 1000 keys. We define some
    // buffer here and half the amount of keys recursively for this situation.
    const getAllMax = 800;
    if (keys.length > getAllMax) {
      final half = keys.length ~/ 2;
      return [
        ...(await getAll(keys.sublist(0, half))),
        ...(await getAll(keys.sublist(half))),
      ];
    }

    final executor = txn ?? boxCollection._db;

    final list = <V?>[];

    final result = await executor.query(
      name,
      where: 'k IN (${keys.map((_) => '?').join(',')})',
      whereArgs: keys,
    );
    final resultMap = Map<String, V?>.fromEntries(
      result.map((row) => MapEntry(row['k'] as String, _fromString(row['v']))),
    );

    // We want to make sure that they values are returnd in the exact same
    // order than the given keys. That's why we do this instead of just return
    // `resultMap.values`.
    list.addAll(keys.map((key) => resultMap[key]));

    for (final entry in resultMap.entries) {
      if (!_quickAccessCache.containsKey(entry.key)) {
        _quickAccessCache[entry.key] = entry.value;
      }
    }
    _evict();

    return list;
  }

  Future<void> put(String key, V val) async {
    final txn = boxCollection._activeBatch;

    final params = {'k': key, 'v': _toString(val)};
    if (txn == null) {
      await boxCollection._db.insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      txn.insert(name, params, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    _touch(key, val);
    _quickAccessCachedKeys?.add(key);
    _dropLargeKeySet();
    return;
  }

  Future<void> delete(String key, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await boxCollection._db.delete(name, where: 'k = ?', whereArgs: [key]);
    } else {
      txn.delete(name, where: 'k = ?', whereArgs: [key]);
    }

    // Set to null instead remove() so that inside of transactions null is
    // returned.
    _touch(key, null);
    _quickAccessCachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    final placeholder = keys.map((_) => '?').join(',');
    if (txn == null) {
      await boxCollection._db.delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    } else {
      txn.delete(name, where: 'k IN ($placeholder)', whereArgs: keys);
    }

    for (final key in keys) {
      _quickAccessCache[key] = null;
      _quickAccessCachedKeys?.removeAll(keys);
    }
    return;
  }

  void clearQuickAccessCache() {
    _quickAccessCache.clear();
    _quickAccessCachedKeys = null;
  }

  Future<void> clear([Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await boxCollection._db.delete(name);
    } else {
      txn.delete(name);
    }

    clearQuickAccessCache();
  }
}
