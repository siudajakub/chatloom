// Standalone pure Dart check. Creates and removes only its own synthetic root.
// Run: dart test/personal/integration/recording_output_cleanup_check.dart
import 'dart:io';

import '../../../lib/pages/chat/recording_output_cleanup.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('voice_cleanup_fixture_');
  try {
    final owned = File('${root.path}/voice_owned.ogg');
    final other = File('${root.path}/unrelated.ogg');
    await owned.writeAsBytes([1, 2, 3]);
    await other.writeAsBytes([4, 5, 6]);
    await cleanupRecordingOutput(
      ownedNativePath: owned.path,
      stoppedBlobUrl: other.path,
    );
    check(!await owned.exists(), 'Owned output must be removed');
    check(await other.exists(), 'Plugin output must not be used for deletion');
    await cleanupRecordingOutput(stoppedBlobUrl: other.path);
    check(await other.exists(), 'Null ownership must not delete anything');
    await cleanupRecordingOutput(ownedNativePath: owned.path);

    final link = Link('${root.path}/voice_link.ogg');
    await link.create(other.path);
    await cleanupRecordingOutput(ownedNativePath: link.path);
    check(!await link.exists(), 'Owned link itself must be removed');
    check(await other.exists(), 'Cleanup must not follow a symlink target');

    final directory = await Directory('${root.path}/voice_directory').create();
    final retained = await File('${directory.path}/retained').writeAsBytes([7]);
    try {
      await cleanupRecordingOutput(ownedNativePath: directory.path);
    } on FileSystemException {
      // A mistaken directory path must not turn into recursive deletion.
    }
    check(
      await retained.exists(),
      'Cleanup must never recurse into a directory',
    );
    check(await other.exists(), 'Unrelated output must remain untouched');
    stdout.writeln('PASS: owned recording output cleanup (7 checks)');
  } finally {
    await root.delete(recursive: true);
  }
}
