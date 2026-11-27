// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: synthetic secrets in a private temp folder and a fake Keychain.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/storage/secret_vault.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts Keychain reads per item: each one is a password prompt after an
/// update of an app signed without a Team ID.
class _FakeKeychain implements KeychainItems {
  final Map<String, String> items;
  final Map<String, int> reads = {};
  final List<String> writes = [];
  Set<String> denied = {};

  _FakeKeychain([Map<String, String>? items]) : items = {...?items};

  @override
  Future<String?> read(String key) async {
    reads[key] = (reads[key] ?? 0) + 1;
    if (denied.contains(key)) throw Exception('denied');
    return items[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    items[key] = value;
  }
}

class _FailingFile implements VaultFile {
  final VaultFile inner;
  bool failWrites = false;
  _FailingFile(this.inner);

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<Uint8List> readAsBytes() => inner.readAsBytes();

  @override
  Future<void> replace(Uint8List bytes) {
    if (failWrites) throw const FileSystemException('full');
    return inner.replace(bytes);
  }

  @override
  Future<T> exclusive<T>(Future<T> Function() action) =>
      inner.exclusive(action);
}

const _secret = 'PLAINTEXT-SECRET-MARKER';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('secret_vault_test');
    file = File('${directory.path}/vault.v1');
  });

  tearDown(() async {
    PersonalSecureStorage.debugVault = null;
    await directory.delete(recursive: true);
  });

  SecretVault open(_FakeKeychain keychain, [VaultFile? vaultFile]) =>
      SecretVault(file: vaultFile ?? PathVaultFile(file), keychain: keychain);

  test('a new vault keeps values encrypted across restarts', () async {
    final keychain = _FakeKeychain();
    await open(keychain).write('database_password', _secret);

    expect(keychain.writes, [SecretVault.masterKeyName]);
    final bytes = await file.readAsBytes();
    expect(utf8.decode(bytes, allowMalformed: true), isNot(contains(_secret)));

    final restarted = open(keychain);
    expect(await restarted.read('database_password'), _secret);
  });

  test('after an update only the vault key is read from the Keychain', () async {
    final keychain = _FakeKeychain({
      'database_password': 'db',
      'chat.fluffy.app_lock': '1234',
      'personal_store': 'store',
    });
    final first = open(keychain);
    for (final key in keychain.items.keys.toList()) {
      if (key == SecretVault.masterKeyName) continue;
      await first.read(key);
    }
    expect(await first.read('chat.fluffy.use_biometrics'), isNull);

    keychain.reads.clear();
    final updated = open(keychain);
    expect(await updated.read('database_password'), 'db');
    expect(await updated.read('chat.fluffy.app_lock'), '1234');
    expect(await updated.read('personal_store'), 'store');
    expect(await updated.read('chat.fluffy.use_biometrics'), isNull);
    expect(keychain.reads, {SecretVault.masterKeyName: 1});
  });

  test('migration copies and never deletes the old Keychain item', () async {
    final keychain = _FakeKeychain({'database_password': 'db'});
    final vault = open(keychain);
    expect(await vault.read('database_password'), 'db');
    expect(await vault.read('database_password'), 'db');
    expect(keychain.reads['database_password'], 1);
    expect(keychain.items['database_password'], 'db');
  });

  test('a delete is not undone by the old Keychain copy', () async {
    final keychain = _FakeKeychain({'chat.fluffy.app_lock': '1234'});
    final vault = open(keychain);
    expect(await vault.read('chat.fluffy.app_lock'), '1234');
    await vault.write('chat.fluffy.app_lock', null);

    expect(await open(keychain).read('chat.fluffy.app_lock'), isNull);
    final never = open(keychain);
    await never.delete('personal_gateway_nonce');
    keychain.items['personal_gateway_nonce'] = 'old';
    expect(await open(keychain).read('personal_gateway_nonce'), isNull);
  });

  test('an existing vault without its key fails closed', () async {
    final keychain = _FakeKeychain();
    await open(keychain).write('database_password', 'db');
    final before = await file.readAsBytes();
    keychain.items.remove(SecretVault.masterKeyName);
    keychain.writes.clear();

    await expectLater(
      open(keychain).read('database_password'),
      throwsA(isA<StorageFailure>()),
    );
    expect(keychain.writes, isEmpty);
    expect(await file.readAsBytes(), before);
  });

  test('a wrong key or damaged file fails closed', () async {
    final keychain = _FakeKeychain();
    await open(keychain).write('database_password', 'db');
    final before = await file.readAsBytes();

    final wrong = _FakeKeychain({
      SecretVault.masterKeyName: base64UrlEncode(List<int>.filled(32, 7)),
    });
    await expectLater(
      open(wrong).read('database_password'),
      throwsA(isA<StorageFailure>()),
    );

    final damaged = Uint8List.fromList(before)..[before.length - 1] ^= 1;
    await file.writeAsBytes(damaged);
    await expectLater(
      open(keychain).read('database_password'),
      throwsA(isA<StorageFailure>()),
    );
    expect(wrong.writes, isEmpty);
    expect(await file.readAsBytes(), damaged);
  });

  test('a denied Keychain read throws and is retried later', () async {
    final keychain = _FakeKeychain({'database_password': 'db'})
      ..denied = {'database_password'};
    final vault = open(keychain);
    await expectLater(vault.read('database_password'), throwsException);
    keychain.denied = {};
    expect(await vault.read('database_password'), 'db');
  });

  test('a failed write keeps the previous value', () async {
    final keychain = _FakeKeychain();
    final failing = _FailingFile(PathVaultFile(file));
    final vault = open(keychain, failing);
    await vault.write('personal_gateway_nonce', 'one');
    failing.failWrites = true;
    await expectLater(
      vault.write('personal_gateway_nonce', 'two'),
      throwsA(isA<FileSystemException>()),
    );
    failing.failWrites = false;
    expect(await vault.read('personal_gateway_nonce'), 'one');
    expect(await open(keychain).read('personal_gateway_nonce'), 'one');
  });

  test('concurrent writes all land', () async {
    final keychain = _FakeKeychain();
    final vault = open(keychain);
    await Future.wait([
      for (var i = 0; i < 20; i++) vault.write('key$i', 'value$i'),
    ]);
    final restarted = open(keychain);
    for (var i = 0; i < 20; i++) {
      expect(await restarted.read('key$i'), 'value$i');
    }
    expect(keychain.writes, [SecretVault.masterKeyName]);
  });

  // The file lock is per process (fcntl), so two vaults in this one test
  // process cannot contend for it; this checks the re-read before a change.
  test('two app instances keep each other\'s entries and key', () async {
    final keychain = _FakeKeychain();
    final first = open(keychain);
    final second = open(keychain);
    await first.write('database_password', 'db');
    await second.write('personal_gateway_nonce', 'n');
    await first.write('chat.fluffy.app_lock', '1234');
    await second.write('personal_store', 'store');

    expect(keychain.writes, [SecretVault.masterKeyName]);
    final restarted = open(keychain);
    expect(await restarted.read('database_password'), 'db');
    expect(await restarted.read('personal_gateway_nonce'), 'n');
    expect(await restarted.read('chat.fluffy.app_lock'), '1234');
    expect(await restarted.read('personal_store'), 'store');
  });

  test('a delete in another instance is seen at once', () async {
    final keychain = _FakeKeychain({'recovery': 'secret'});
    final first = open(keychain);
    final second = open(keychain);
    expect(await first.read('recovery'), 'secret');
    await second.delete('recovery');
    expect(await first.read('recovery'), isNull);
  });

  test('createIfAbsent never replaces a stored key', () async {
    final keychain = _FakeKeychain({'legacy_db': 'old'});
    final first = open(keychain);
    final second = open(keychain);
    expect(await first.read('database_password'), isNull);
    expect(await second.createIfAbsent('database_password', 'K'), 'K');
    expect(await first.createIfAbsent('database_password', 'K2'), 'K');
    expect(await first.read('database_password'), 'K');
    expect(await first.createIfAbsent('legacy_db', 'new'), 'old');
    expect(await open(keychain).read('legacy_db'), 'old');
  });

  test('PersonalSecureStorage routes through the vault', () async {
    final keychain = _FakeKeychain({'chat.fluffy.app_lock': '1234'});
    PersonalSecureStorage.debugVault = open(keychain);
    const storage = personalSecureStorage;
    expect(await storage.read(key: 'chat.fluffy.app_lock'), '1234');
    await storage.write(key: 'chat.fluffy.app_lock', value: null);
    expect(await storage.containsKey(key: 'chat.fluffy.app_lock'), isFalse);
    await storage.write(key: 'personal_gateway_nonce', value: 'n');
    expect(await storage.read(key: 'personal_gateway_nonce'), 'n');
    expect(() => storage.readAll(), throwsUnsupportedError);
  });
}
