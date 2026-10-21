// SPDX-License-Identifier: AGPL-3.0-or-later
// Local SDK patch (packages/matrix UPSTREAM-PIN, 2026-10-21): sendFileEvent
// shrinks before it derives the thumbnail and uploads file and thumbnail
// concurrently. Real in-memory SDK database; uploads and the final send are
// offline fakes, nothing reaches a server.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _UploadClient extends Client {
  final starts = <String>[];
  final gates = <String, Completer<Uri>>{};
  final pending = <Completer<Uri>>[];
  final failNext = <String, Object>{};
  final resized = <(int, int)>[];
  int sent = 0;

  _UploadClient(DatabaseApi database)
    : super(
        'send-file fixture',
        database: database,
        customImageResizer: _resize,
      );

  static _UploadClient? current;

  static Future<MatrixImageFileResizedResponse?> _resize(
    MatrixImageFileResizeArguments arguments,
  ) async {
    current!.resized.add((arguments.maxDimension, arguments.bytes.length));
    final side = arguments.maxDimension ~/ 100;
    return MatrixImageFileResizedResponse(
      bytes: Uint8List(side),
      width: side,
      height: side,
      originalWidth: arguments.bytes.length,
      originalHeight: arguments.bytes.length,
      mimeType: 'image/jpeg',
    );
  }

  @override
  String get userID => '@owner:example.invalid';

  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig(mUploadSize: 1 << 20);

  @override
  Future<Uri> uploadContent(
    Uint8List file, {
    String? filename,
    String? contentType,
  }) {
    final name = filename ?? '';
    starts.add(name);
    final failure = failNext.remove(name);
    if (failure != null) return Future<Uri>.error(failure);
    final gate = gates[name] = Completer<Uri>();
    pending.add(gate);
    return gate.future;
  }

  @override
  Future<String> sendMessage(
    String roomId,
    String eventType,
    String txnId,
    Map<String, Object?> body,
  ) async {
    sent++;
    return r'$sent';
  }
}

Future<(_UploadClient, Room)> _setUp() async {
  final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final database = await MatrixSdkDatabase.init(
    'send-file-fixture',
    database: raw,
    sqfliteFactory: databaseFactoryFfi,
  );
  final client = _UploadClient.current = _UploadClient(database);
  final room = Room(
    id: '!send-file:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  return (client, room);
}

void main() {
  test('file and thumbnail upload at the same time', () async {
    final (client, room) = await _setUp();
    final sending = room.sendFileEvent(
      MatrixFile(
        bytes: Uint8List(64),
        name: 'doc.bin',
        mimeType: 'application/octet-stream',
      ),
      thumbnail: MatrixImageFile(
        bytes: Uint8List(8),
        name: 'doc.jpg',
        mimeType: 'image/jpeg',
      ),
      txid: 'fixture-txid',
    );
    // The local echo goes through the real (threaded) database first.
    for (var i = 0; i < 200 && client.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Both are on the wire before either finished.
    expect(client.starts, ['doc.bin', 'doc.jpg']);
    client.gates['doc.jpg']!.complete(Uri.parse('mxc://example.invalid/t'));
    await pumpEventQueue();
    expect(client.sent, 0, reason: 'the event waits for the file');
    client.gates['doc.bin']!.complete(Uri.parse('mxc://example.invalid/f'));
    expect(await sending, r'$sent');
    expect(client.sent, 1);
  });

  test('a retry uploads only the part that is missing', () async {
    final (client, room) = await _setUp();
    client.failNext['doc.jpg'] = StateError('fictional connection reset');
    final sending = room.sendFileEvent(
      MatrixFile(
        bytes: Uint8List(64),
        name: 'doc.bin',
        mimeType: 'application/octet-stream',
      ),
      thumbnail: MatrixImageFile(
        bytes: Uint8List(8),
        name: 'doc.jpg',
        mimeType: 'image/jpeg',
      ),
      txid: 'fixture-retry',
    );
    for (var i = 0; i < 200 && client.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    client.gates['doc.bin']!.complete(Uri.parse('mxc://example.invalid/f'));
    // The SDK waits a second before it tries again.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (client.starts.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(client.starts, ['doc.bin', 'doc.jpg', 'doc.jpg']);
    client.gates['doc.jpg']!.complete(Uri.parse('mxc://example.invalid/t'));
    expect(await sending, r'$sent');
  });

  test(
    'a photo is shrunk once and its thumbnail comes from the shrunk image',
    () async {
      final (client, room) = await _setUp();
      final sending = room.sendFileEvent(
        MatrixImageFile(
          bytes: Uint8List(4000),
          name: 'photo.jpg',
          mimeType: 'image/jpeg',
        ),
        shrinkImageMaxDimension: 1600,
        txid: 'fixture-photo',
      );
      for (var i = 0; i < 200 && client.starts.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // Shrink of the 4000-byte original, then the thumbnail of the 16-byte
      // shrunk image: the original is decoded once.
      expect(client.resized, [(1600, 4000), (Client.defaultThumbnailSize, 16)]);
      expect(client.starts, hasLength(2));
      for (final gate in client.pending) {
        gate.complete(Uri.parse('mxc://example.invalid/x'));
      }
      expect(await sending, r'$sent');
    },
  );
}
