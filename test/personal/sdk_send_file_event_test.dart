// SPDX-License-Identifier: AGPL-3.0-or-later
// Local SDK patches (packages/matrix UPSTREAM-PIN, 2026-10-21/22):
// sendFileEvent shrinks before it derives the thumbnail and uploads file and
// thumbnail concurrently; a failed final send keeps this device's copy; a
// missing copy never deletes an unsent event; the member list is stored in
// one transaction. Real in-memory SDK database; uploads and the final send
// are offline fakes, nothing reaches a server.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The SDK database with files in memory (production keeps them in the
/// encrypted media cache) and a transaction counter.
class _FileDatabase extends MatrixSdkDatabase {
  final files = <Uri, Uint8List>{};
  int transactions = 0;
  _FileDatabase(Database database)
    : super.buildWithoutOpen(
        'send-file-files',
        database: database,
        sqfliteFactory: databaseFactoryFfi,
      );
  @override
  bool get supportsFileStoring => true;
  @override
  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) async =>
      files[mxcUri] = bytes;
  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => files[mxcUri];
  @override
  Future<bool> deleteFile(Uri mxcUri) async => files.remove(mxcUri) != null;
  @override
  Future<void> transaction(Future<void> Function() action) {
    transactions++;
    return super.transaction(action);
  }
}

class _UploadClient extends Client {
  final starts = <String>[];
  Object? sendFailure;
  List<MatrixEvent> members = const [];
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
    final failure = sendFailure;
    if (failure != null) throw failure;
    return r'$sent';
  }

  @override
  Future<List<MatrixEvent>?> getMembersByRoom(
    String roomId, {
    String? at,
    Membership? membership,
    Membership? notMembership,
  }) async => members;
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

Future<(_UploadClient, Room, _FileDatabase)> _setUpWithFiles() async {
  final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final database = _FileDatabase(raw);
  await database.open();
  final client = _UploadClient.current = _UploadClient(database);
  final room = Room(
    id: '!send-file-copy:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  return (client, room, database);
}

void main() {
  test('a failed final send keeps the copy for Retry (CC-04)', () async {
    final (client, room, database) = await _setUpWithFiles();
    client.sendFailure = MatrixException.fromJson({
      'errcode': 'M_UNKNOWN',
      'error': 'fixture',
    });
    final copy = Uri(scheme: 'cache', host: 'file', path: 'fixture-put');
    final sending = room.sendFileEvent(
      MatrixFile(
        bytes: Uint8List(64),
        name: 'doc.bin',
        mimeType: 'application/octet-stream',
      ),
      txid: 'fixture-put',
    );
    for (var i = 0; i < 200 && client.starts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    client.gates['doc.bin']!.complete(Uri.parse('mxc://example.invalid/f'));
    expect(await sending, isNull, reason: 'the final send failed');
    expect(client.sent, 1);
    expect(database.files[copy], hasLength(64), reason: 'Retry needs it');
    final echo = await database.getEventById('fixture-put', room);
    expect(echo?.status, EventStatus.error);
    expect(echo?.content['url'], 'mxc://example.invalid/f');

    // Retry from that copy; once accepted, the copy goes.
    client.sendFailure = null;
    final again = echo!.sendAgain();
    for (var i = 0; i < 200 && client.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    client.gates['doc.bin']!.complete(Uri.parse('mxc://example.invalid/g'));
    expect(await again, r'$sent');
    expect(database.files, isNot(contains(copy)));
  });

  test(
    'reading an unsent file without its copy never deletes it (CC-03)',
    () async {
      final (client, room, database) = await _setUpWithFiles();
      await database.transaction(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: '',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  timeline: TimelineUpdate(
                    events: [
                      MatrixEvent(
                        type: EventTypes.Message,
                        content: {
                          'msgtype': MessageTypes.File,
                          'body': 'gone.pdf',
                          'filename': 'gone.pdf',
                        },
                        eventId: 'fixture-gone',
                        senderId: client.userID,
                        originServerTs: DateTime.now(),
                        unsigned: {
                          messageSendingStatusKey: EventStatus.error.intValue,
                          'transaction_id': 'fixture-gone',
                        },
                      ),
                    ],
                  ),
                ),
              },
            ),
          ),
        ),
      );
      final echo = await database.getEventById('fixture-gone', room);
      expect(echo, isNotNull);
      await expectLater(echo!.downloadAndDecryptAttachment(), throwsA(anything));
      await expectLater(
        echo.sendAgain(),
        throwsA(isA<FileNoLongerInCacheException>()),
      );
      expect(
        await database.getEventById('fixture-gone', room),
        isNotNull,
        reason: 'the bubble stays, with Retry and Delete',
      );
    },
  );

  test('the member list is stored in one transaction (PF-04)', () async {
    final (client, room, database) = await _setUpWithFiles();
    client.members = [
      for (var i = 0; i < 30; i++)
        MatrixEvent(
          type: EventTypes.RoomMember,
          content: {'membership': 'join', 'displayname': 'Member $i'},
          stateKey: '@member$i:example.invalid',
          eventId: '\$member-$i',
          senderId: '@member$i:example.invalid',
          originServerTs: DateTime.utc(2026),
        ),
    ];
    final before = database.transactions;
    final users = await room.requestParticipants(
      const [Membership.join],
      true,
      true,
    );
    expect(users, hasLength(30));
    expect(database.transactions - before, 1);
    expect(await database.getUsers(room), hasLength(30));
  });

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

  test('a PNG re-encoded as JPEG is sent as .jpg (MD-01)', () async {
    final (client, room) = await _setUp();
    final sending = room.sendFileEvent(
      MatrixImageFile(
        bytes: Uint8List(4000),
        name: 'screenshot.png',
        mimeType: 'image/png',
      ),
      shrinkImageMaxDimension: 2048,
      txid: 'fixture-rename',
    );
    for (var i = 0; i < 200 && client.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(client.starts, contains('screenshot.jpg'));
    expect(client.starts, isNot(contains('screenshot.png')));
    for (final gate in client.pending) {
      gate.complete(Uri.parse('mxc://example.invalid/x'));
    }
    expect(await sending, r'$sent');
  });

  test(
    'a cancelled send stops its upload and sends no event (MD-17)',
    () async {
      final (client, room) = await _setUp();
      final cancelled = <String>{};
      client.fileSendCancelled = cancelled.contains;
      cancelled.add('fixture-cancel');
      final sending = room.sendFileEvent(
        MatrixFile(
          bytes: Uint8List(64),
          name: 'doc.bin',
          mimeType: 'application/octet-stream',
        ),
        txid: 'fixture-cancel',
      );
      // Not retried for the send timeout: the abort ends it at once.
      await expectLater(sending, completion(isNull));
      expect(client.starts, isEmpty, reason: 'cancelled before the upload');
      expect(client.sent, 0);

      cancelled.clear();
      final running = room.sendFileEvent(
        MatrixFile(
          bytes: Uint8List(64),
          name: 'doc.bin',
          mimeType: 'application/octet-stream',
        ),
        txid: 'fixture-cancel-2',
      );
      for (var i = 0; i < 200 && client.starts.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      cancelled.add('fixture-cancel-2');
      client.gates['doc.bin']!.completeError(StateError('fictional abort'));
      await expectLater(running, throwsA(isA<StateError>()));
      expect(client.starts, ['doc.bin'], reason: 'no retry after the abort');
      expect(client.sent, 0);
    },
  );
}
