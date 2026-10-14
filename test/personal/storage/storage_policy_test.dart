// SPDX-License-Identifier: AGPL-3.0-or-later
// Standalone Dart regression suite; no Flutter/native build hooks required.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../lib/personal/media/media_access.dart';
import '../../../lib/personal/storage/cipher_policy.dart';
import '../../../lib/personal/storage/database_policy.dart';
import '../../../lib/personal/storage/storage_failure.dart';

class FakeVault implements KeyVault {
  String? value;
  bool failRead = false;
  bool failWrite = false;
  bool discardWrite = false;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('secret-canary');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (failWrite) throw StateError('secret-canary');
    if (!discardWrite) this.value = value;
  }
}

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> fails(
  Future<void> Function() action,
  StorageFailureCode code,
) async {
  try {
    await action();
  } on StorageFailure catch (error) {
    check(error.code == code, 'Expected safe failure code');
    check(!error.toString().contains('secret-canary'), 'Secret escaped');
    return;
  }
  throw StateError('Expected storage failure');
}

Future<void> main() async {
  final key = base64UrlEncode(List<int>.filled(32, 7));
  final vault = FakeVault()..value = key;
  final policy = CipherPolicy(vault);
  check(await policy.load('key', requireExisting: true) == key, 'Existing key');
  check(vault.writes == 0, 'Existing key rewritten');
  vault.failRead = true;
  await fails(() => policy.load('key'), StorageFailureCode.keyUnavailable);
  check(vault.value == key, 'Read failure erased key');
  vault.failRead = false;
  check(await policy.load('key') == key, 'Transient failure recovery');

  vault.value = null;
  await fails(
    () => policy.load('key', requireExisting: true),
    StorageFailureCode.keyUnavailable,
  );
  check(vault.writes == 0, 'Missing key for existing database regenerated');
  vault.discardWrite = true;
  await fails(() => policy.load('key'), StorageFailureCode.keyCreationFailed);
  vault.discardWrite = false;
  vault.failWrite = true;
  await fails(() => policy.load('key'), StorageFailureCode.keyUnavailable);
  vault.failWrite = false;
  final generated = await policy.load('key');
  check(base64Url.decode(generated).length == 32, 'Generated key entropy size');
  check(await policy.load('key') == generated, 'Generated key changed');
  final concurrentVault = FakeVault();
  final concurrentPolicy = CipherPolicy(concurrentVault);
  final values = await Future.wait(
    List.generate(10, (_) => concurrentPolicy.load('key')),
  );
  check(values.toSet().length == 1, 'Concurrent initialization changed key');
  check(concurrentVault.writes == 1, 'Concurrent initialization wrote twice');
  vault.value = "key'; secret-canary";
  await fails(() => policy.load('key'), StorageFailureCode.keyUnavailable);

  final temp = await Directory.systemTemp.createTemp('personal_storage_test_');
  try {
    final file = File('${temp.path}/legacy.sqlite');
    final original = [...utf8.encode('SQLite format 3\u0000'), 1, 2, 3];
    await file.writeAsBytes(original);
    await fails(
      () => requireEncryptedDatabaseFile(file.path),
      StorageFailureCode.legacyMigrationRequired,
    );
    check(
      base64Encode(await file.readAsBytes()) == base64Encode(original),
      'Legacy database changed',
    );
    var attempts = 0;
    await fails(
      () => preserveOnStorageFailure(() async {
        attempts++;
        throw StateError('secret-canary');
      }),
      StorageFailureCode.databaseUnavailable,
    );
    check(attempts == 1, 'Initialization retried');
    check(await file.exists(), 'Failure deleted database');
    final packageOutput = <String>[];
    await runZoned(
      () => preserveOnStorageFailure(() async {
        // ignore: avoid_print
        print('secret-canary SQL/path from dependency');
      }),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => packageOutput.add(line),
      ),
    );
    check(packageOutput.isEmpty, 'Dependency exception output escaped');

    final scratch = Directory('${temp.path}/scratch');
    await scratch.create();
    final unrelated = File('${scratch.path}/keep');
    await unrelated.writeAsString('unrelated');
    final stale = Directory('${scratch.path}/lease_0_${'a' * 32}');
    await stale.create();
    await File('${stale.path}/.lock').writeAsString('');
    await File('${stale.path}/media.ogg').writeAsString('private-canary');
    final media = await MediaAccess.open(directory: scratch);
    check(!await stale.exists(), 'Crash leftovers not removed');
    check(await unrelated.exists(), 'Unrelated file removed');
    String? path;
    await media.withFile(
      Uint8List.fromList([1, 2, 3]),
      extension: '.ogg',
      action: (file) async {
        path = file.path;
        check(await file.length() == 3, 'Temp media incomplete');
        await media.cleanupStale();
        check(await file.exists(), 'Active media swept');
      },
    );
    check(!await File(path!).exists(), 'Successful action leaked media');
    final lease = await media.create(
      Uint8List.fromList([4, 5]),
      extension: '.ogg',
    );
    check(
      (await lease.file.parent.stat()).mode & 0x3f == 0,
      'Media directory has non-owner permissions',
    );
    final converted = lease.derivedFile('.caf');
    await converted.writeAsBytes([6, 7]);
    await media.cleanupStale();
    check(await lease.file.exists(), 'Paused player lease removed');
    check(await converted.exists(), 'Converted active media removed');
    await lease.close();
    await lease.close();
    check(!await converted.exists(), 'Converted file leaked');
    check(!await lease.file.exists(), 'Explicit player close leaked');
    await fails(
      () => media.withFile(
        Uint8List(1),
        extension: '.ogg',
        action: (file) async {
          path = file.path;
          throw StateError('secret-canary');
        },
      ),
      StorageFailureCode.mediaUnavailable,
    );
    check(!await File(path!).exists(), 'Failed action leaked media');
    await fails(
      () => media.withFile(
        Uint8List(1),
        extension: '/../escape',
        action: (_) async {},
      ),
      StorageFailureCode.invalidData,
    );
  } finally {
    await temp.delete(recursive: true);
  }
  stdout.writeln('PASS storage policies and managed media regressions');
}
