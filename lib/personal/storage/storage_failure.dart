// SPDX-License-Identifier: AGPL-3.0-or-later

enum StorageFailureCode {
  keyUnavailable,
  keyCreationFailed,
  legacyMigrationRequired,
  encryptionUnavailable,
  databaseUnavailable,
  unsupportedPlatform,
  invalidData,
  mediaUnavailable,
}

/// Never contains the original exception, paths, keys or stored data.
class StorageFailure implements Exception {
  final StorageFailureCode code;
  const StorageFailure(this.code);

  @override
  String toString() => 'StorageFailure(${code.name})';
}
