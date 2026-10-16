// SPDX-License-Identifier: AGPL-3.0-or-later
// Actual production media source; run under process-specific umasks via harness.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../lib/personal/media/media_access.dart';
import '../../../lib/personal/storage/storage_failure.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> unavailable(Future<dynamic> Function() action) async {
  try {
    await action();
  } on StorageFailure catch (error) {
    check(error.code == StorageFailureCode.mediaUnavailable, 'Wrong failure');
    return;
  }
  throw StateError('Expected fail-closed media operation');
}

Future<void> privateLease(ManagedMediaFile lease) async {
  check(
    (await lease.file.parent.stat()).mode & 0x1ff == 0x1c0,
    'Lease is not owner-only before encoder access',
  );
  check(
    await File('${lease.writableDirectory}/.lock').exists(),
    'Missing lock',
  );
}

Future<void> child(String root) async {
  final media = await MediaAccess.open(directory: Directory(root));
  final lease = await media.create(Uint8List.fromList([71]), extension: '.ogg');
  final setup = Directory('$root/lease_${pid}_${'b' * 32}');
  await setup.create();
  final unlocked = Directory('$root/lease_${pid}_${'d' * 32}');
  await unlocked.create();
  await File('${unlocked.path}/.lock').writeAsString('');
  // Keep a real lock whose filename has no living PID, to independently verify
  // the lock fallback rather than passing only through the live-owner guard.
  final locked = Directory('$root/lease_0_${'e' * 32}');
  await locked.create();
  final lock = await File('${locked.path}/.lock').open(mode: FileMode.append);
  await lock.lock(FileLock.blockingExclusive);
  stdout.writeln(
    jsonEncode([lease.file.path, setup.path, unlocked.path, locked.path]),
  );
  await stdout.flush();
  await stdin.first;
  await lease.close();
  await lock.close();
  // Simulate death during setup; the parent sweeps this only after child exit.
}

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == 'child') {
    await child(arguments[1]);
    return;
  }
  if (arguments.isNotEmpty && arguments.first == 'failure') {
    // Harness supplies an already-private root, then starts us with umask 0777.
    // mkdir cannot establish owner access; no lock/bytes/handle may be exposed.
    final root = Directory(arguments[1]);
    final media = await MediaAccess.open(directory: root);
    var called = false;
    await unavailable(
      () => media.withFile(
        Uint8List.fromList([83, 69, 67]),
        extension: '.ogg',
        action: (_) async {
          called = true;
        },
      ),
    );
    await unavailable(() => media.createWriter(extension: '.mp4'));
    check(!called, 'Failed permissions exposed plaintext callback');
    check(
      await root.list(followLinks: false).isEmpty,
      'Failed permission setup left lock or plaintext',
    );
    stdout.writeln('PASS fail-closed media permission establishment');
    return;
  }
  final temp = await Directory.systemTemp.createTemp('personal_media_modes_');
  Process? process;
  try {
    final root = Directory('${temp.path}/managed');
    final media = await MediaAccess.open(directory: root);
    final first = await media.create(
      Uint8List.fromList([1, 2, 3]),
      extension: '.ogg',
    );
    final second = await media.createWriter(extension: '.mp4');
    await privateLease(first);
    await privateLease(second);
    check(first.file.parent.path != second.file.parent.path, 'Leases collided');
    final derived = first.derivedFile('.caf');
    final sibling = second.siblingFile('encoder_frame.mp4');
    await derived.writeAsBytes([4, 5]);
    await sibling.writeAsBytes([6, 7]);
    await second.file.writeAsBytes([8, 9]);
    await media.cleanupStale();
    check(
      await derived.exists() && await sibling.exists(),
      'Active files swept',
    );
    await Future.wait([first.close(), first.close(), second.close()]);
    await first.close();
    check(
      !await derived.exists() && !await sibling.exists(),
      'Close leaked files',
    );

    final unrelated = File('${root.path}/unrelated')..writeAsStringSync('keep');
    final outside = Directory('${temp.path}/outside');
    await outside.create();
    final canary = File('${outside.path}/canary')..writeAsStringSync('keep');
    final stale = Directory('${root.path}/lease_0_${'a' * 32}');
    await stale.create();
    await File('${stale.path}/.lock').writeAsString('');
    await Link('${stale.path}/derived.caf').create(canary.path);
    await Link('${root.path}/lease_0_${'c' * 32}').create(outside.path);
    await media.cleanupStale();
    check(!await stale.exists(), 'Dead lease survived cleanup');
    check(await canary.readAsString() == 'keep', 'Cleanup followed symlink');
    check(await unrelated.exists(), 'Cleanup removed unrelated file');

    process = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      'child',
      root.path,
    ]);
    final output = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final paths = (jsonDecode(output) as List).cast<String>();
    await media.cleanupStale();
    check(await File(paths[0]).exists(), 'Another process active lock swept');
    check(await Directory(paths[1]).exists(), 'Live mkdir/lock setup swept');
    check(
      await File('${paths[2]}/.lock').exists(),
      'Live existing-but-unlocked setup swept',
    );
    check(
      await Directory(paths[3]).exists(),
      'Another process lock swept without live PID hint',
    );
    process.stdin.writeln('close');
    await process.stdin.close();
    check(await process.exitCode == 0, 'Media child failed');
    process = null;
    await media.cleanupStale();
    for (final path in paths.skip(1)) {
      check(!await Directory(path).exists(), 'Dead incomplete lease survived');
    }

    final rootLink = Link('${temp.path}/managed-link');
    await rootLink.create(root.path);
    await unavailable(
      () => MediaAccess.open(directory: Directory(rootLink.path)),
    );
    final parked = await root.rename('${temp.path}/parked');
    await Link(root.path).create(outside.path);
    await unavailable(
      () => media.create(Uint8List.fromList([1]), extension: '.ogg'),
    );
    await unavailable(media.cleanupStale);
    check(
      await canary.readAsString() == 'keep',
      'Root swap changed unrelated data',
    );
    await Link(root.path).delete();
    await parked.rename(root.path);
    check(
      await root
          .list(followLinks: false)
          .where((entry) => entry is Directory)
          .isEmpty,
      'Failure created an owned lease',
    );
  } finally {
    process?.kill();
    if (process != null) await process.exitCode;
    await temp.delete(recursive: true);
  }
  stdout.writeln('PASS real-source media modes, writers, locks and symlinks');
}
