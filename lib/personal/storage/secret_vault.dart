// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:webcrypto/webcrypto.dart';

import 'storage_failure.dart';

/// One Keychain item, read or written by its name.
abstract interface class KeychainItems {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Where the vault's bytes live.
abstract interface class VaultFile {
  Future<bool> exists();
  Future<Uint8List> readAsBytes();

  /// Replaces the whole content so a crash leaves the old or the new bytes.
  Future<void> replace(Uint8List bytes);

  /// Runs [action] while no other process holds the vault (a second app
  /// instance), so neither creates a second key or drops the other's entries.
  Future<T> exclusive<T>(Future<T> Function() action);
}

/// A [VaultFile] at a known path.
class PathVaultFile implements VaultFile {
  final File file;
  const PathVaultFile(this.file);

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Future<void> replace(Uint8List bytes) => replaceFileAtomically(file, bytes);

  @override
  Future<T> exclusive<T>(Future<T> Function() action) =>
      withFileLock(File('${file.path}.lock'), action);
}

/// Holds an advisory exclusive lock on [lockFile] while [action] runs.
Future<T> withFileLock<T>(File lockFile, Future<T> Function() action) async {
  final handle = await lockFile.open(mode: FileMode.append);
  try {
    await handle.lock(FileLock.blockingExclusive);
    return await action();
  } finally {
    await handle.close();
  }
}

/// Writes a sibling file and renames it over [file], so a crash leaves
/// either the old or the new content, never a partial one.
Future<void> replaceFileAtomically(File file, Uint8List bytes) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
}

/// Keeps every secret of the macOS app in one encrypted file whose key is
/// the only Keychain item the app reads at startup.
///
/// The app is signed without an Apple Team ID, so the login Keychain ties
/// each item to the exact build (its cdhash) and asks for the password once
/// per item after every update. With one item it asks once.
///
/// Migration is a copy: the first read of a name the vault has never seen
/// copies the old Keychain item (asking for it one last time) and records
/// the name, also when the item is absent, so a later delete is never undone
/// by the old copy. Old items are left in the Keychain.
///
/// Fails closed: an existing vault whose key is missing or wrong, or a file
/// that does not decrypt, throws [StorageFailure] and never starts empty.
class SecretVault {
  static const masterKeyName = 'chatloom.secret_vault.key';
  static const _magic = 'CLV1';
  static const _nonceLength = 12;
  static final _associatedData = utf8.encode('chatloom.secret_vault.v1');

  final VaultFile file;
  final KeychainItems keychain;

  SecretVault({required this.file, required this.keychain});

  AesGcmSecretKey? _key;
  Future<void> _queue = Future.value();

  /// Every operation re-reads the file under the lock, so a value another
  /// app instance changed or deleted is never served from memory.
  Future<String?> read(String key) => _serial(
    () => _locked((entries) async {
      if (entries.containsKey(key)) return entries[key];
      final legacy = await keychain.read(key);
      await _save({...entries, key: legacy});
      return legacy;
    }),
  );

  /// A null [value] deletes, as `FlutterSecureStorage.write` does.
  Future<void> write(String key, String? value) => _serial(
    () => _locked((entries) async {
      if (entries.containsKey(key) && entries[key] == value) return;
      await _save({...entries, key: value});
    }),
  );

  /// Stores [value] only while [key] has none, also in the old Keychain
  /// item, and returns the value now stored. A new database key never
  /// replaces one another app instance created in the meantime.
  Future<String> createIfAbsent(String key, String value) => _serial(
    () => _locked((entries) async {
      final existing = entries.containsKey(key)
          ? entries[key]
          : await keychain.read(key);
      if (existing != null) {
        if (!entries.containsKey(key)) {
          await _save({...entries, key: existing});
        }
        return existing;
      }
      await _save({...entries, key: value});
      return value;
    }),
  );

  /// Re-reads the file under the lock, so entries written by another
  /// instance since this one loaded are kept.
  Future<T> _locked<T>(
    Future<T> Function(Map<String, String?> entries) action,
  ) => file.exclusive(() async {
    final entries = await _load();
    return action(entries);
  });

  Future<void> delete(String key) => write(key, null);

  /// Runs operations one at a time so concurrent writes never lose an entry.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// The AES key is imported once; the entries are read fresh each time.
  Future<Map<String, String?>> _load() async {
    try {
      if (_key == null) return await _open();
      if (!await file.exists()) return <String, String?>{};
      return await _decode(await file.readAsBytes());
    } on StorageFailure {
      rethrow;
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
  }

  Future<Map<String, String?>> _open() async {
    final exists = await file.exists();
    var encodedKey = await keychain.read(masterKeyName);
    if (encodedKey == null) {
      // A vault without its key stays locked: a new key would hide every
      // secret in it and let callers create replacement database keys.
      if (exists) throw const StorageFailure(StorageFailureCode.keyUnavailable);
      final random = Random.secure();
      final generated = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      await keychain.write(masterKeyName, generated);
      if (await keychain.read(masterKeyName) != generated) {
        throw const StorageFailure(StorageFailureCode.keyCreationFailed);
      }
      encodedKey = generated;
    }
    final List<int> rawKey;
    try {
      rawKey = base64Url.decode(encodedKey);
    } on FormatException {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
    if (rawKey.length != 32) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
    _key = await AesGcmSecretKey.importRawKey(rawKey);
    if (!exists) return <String, String?>{};
    return _decode(await file.readAsBytes());
  }

  Future<Map<String, String?>> _decode(Uint8List bytes) async {
    final header = ascii.encode(_magic);
    if (bytes.length < header.length + _nonceLength + 16) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    for (var i = 0; i < header.length; i++) {
      if (bytes[i] != header[i]) {
        throw const StorageFailure(StorageFailureCode.invalidData);
      }
    }
    final nonce = bytes.sublist(header.length, header.length + _nonceLength);
    final sealed = bytes.sublist(header.length + _nonceLength);
    final Uint8List plain;
    try {
      plain = await _key!.decryptBytes(
        sealed,
        nonce,
        additionalData: _associatedData,
      );
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(plain));
    } on FormatException {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    if (json is! Map<String, Object?> || json['v'] != 1) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    final entries = json['entries'];
    if (entries is! Map<String, Object?>) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    final result = <String, String?>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      if (value != null && value is! String) {
        throw const StorageFailure(StorageFailureCode.invalidData);
      }
      result[key] = value as String?;
    }
    return result;
  }

  Future<void> _save(Map<String, String?> entries) async {
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(_nonceLength, (_) => random.nextInt(256)),
    );
    final plain = utf8.encode(jsonEncode({'v': 1, 'entries': entries}));
    final sealed = await _key!.encryptBytes(
      plain,
      nonce,
      additionalData: _associatedData,
    );
    final bytes = (BytesBuilder(copy: false)
          ..add(ascii.encode(_magic))
          ..add(nonce)
          ..add(sealed))
        .takeBytes();
    await file.replace(bytes);
  }
}
