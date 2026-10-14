// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';

import 'storage_failure.dart';

abstract interface class KeyVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Loading a key is deliberately separate from deleting or recovering data.
/// Callers must set [requireExisting] when any associated database exists.
class CipherPolicy {
  final KeyVault vault;
  final Map<String, Future<String>> _pending = {};
  CipherPolicy(this.vault);

  Future<String> load(String key, {bool requireExisting = false}) async {
    final pending = _pending[key];
    if (pending != null) return pending;
    final operation = _load(key, requireExisting: requireExisting);
    _pending[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pending[key], operation)) _pending.remove(key);
    }
  }

  Future<String> _load(String key, {required bool requireExisting}) async {
    try {
      final existing = await vault.read(key);
      if (existing != null) {
        if (!_valid(existing)) {
          throw const StorageFailure(StorageFailureCode.keyUnavailable);
        }
        return existing;
      }
      if (requireExisting) {
        throw const StorageFailure(StorageFailureCode.keyUnavailable);
      }
      final random = Random.secure();
      final generated = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      await vault.write(key, generated);
      final verified = await vault.read(key);
      if (verified != generated) {
        throw const StorageFailure(StorageFailureCode.keyCreationFailed);
      }
      return generated;
    } on StorageFailure {
      rethrow;
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
  }

  // These keys are inserted in a SQLCipher PRAGMA. The format restriction also
  // prevents malformed secure-storage values from becoming SQL text.
  bool _valid(String key) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}=?$').hasMatch(key)) return false;
    try {
      return base64Url.decode(key).length == 32;
    } catch (_) {
      return false;
    }
  }
}
