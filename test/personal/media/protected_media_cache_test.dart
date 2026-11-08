// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/instagram_media.dart';
import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart'
    show Client, Event, EventTypes, MessageTypes, Room;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Client extends Client {
  _Client(ProtectedMatrixDatabase database)
    : super('Instagram encrypted fixture', database: database) {
    homeserver = Uri.parse('https://example.invalid');
  }

  @override
  String? get userID => '@owner:example.invalid';
}

InstagramMediaAsset _asset(
  ProtectedMatrixDatabase database,
  Future<Object?> Function() request,
) {
  final url = Uri.parse('https://www.instagram.com/reel/Fixture/');
  final original = Event(
    type: EventTypes.Message,
    room: Room(id: '!fixture:example.invalid', client: _Client(database)),
    eventId: r'$reel',
    senderId: '@sender:example.invalid',
    originServerTs: DateTime.utc(2026),
    content: {'msgtype': MessageTypes.Text, 'body': url.toString()},
  );
  return InstagramMediaAsset(
    original: original,
    url: url,
    index: 0,
    info: const {'type': 'video', 'width': 720, 'height': 1280},
    request: request,
  );
}

Object _response(int byte) => {
  'mime': 'video/mp4',
  'data': base64Encode([byte]),
};

Future<void> _withDatabase(
  Future<void> Function(ProtectedMatrixDatabase database, Database raw) run,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'instagram_encrypted_cache_',
  );
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  final raw = await factory.openDatabase(
    '${directory.path}/cache.sqlite',
    options: OpenDatabaseOptions(
      onConfigure: (db) => db.execute(
        "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 13))}'",
      ),
    ),
  );
  final database = ProtectedMatrixDatabase(
    'fixture',
    database: raw,
    factory: factory,
  );
  try {
    await database.open();
    await run(database, raw);
  } finally {
    await raw.close();
    await directory.delete(recursive: true);
  }
}

void main() {
  for (final operation in ['clearCache', 'clear']) {
    test(
      'Instagram load spanning $operation rejects, then mounted adapter retries',
      () async {
        await _withDatabase((database, raw) async {
          final pending = Completer<Object?>();
          final started = Completer<void>();
          var requests = 0;
          var delivered = false;
          final media = _asset(database, () {
            requests++;
            if (requests == 1) {
              started.complete();
              return pending.future;
            }
            return Future<Object?>.value(_response(2));
          });
          final loading = media.downloadAndDecryptAttachment(
            onDownloadProgress: (_) => delivered = true,
          );
          final rejected = expectLater(loading, throwsStateError);
          await started.future;
          if (operation == 'clearCache') {
            await database.clearCache();
          } else {
            await database.clear();
          }
          pending.complete(_response(1));
          await rejected;
          expect(delivered, isFalse);
          expect(
            await raw.query('personal_media_cache', columns: ['media_key']),
            isEmpty,
            reason: 'late bytes must not repopulate the cleared cache',
          );

          expect((await media.downloadAndDecryptAttachment()).bytes, [2]);
          expect(requests, 2);
          expect(
            await raw.query('personal_media_cache', columns: ['media_key']),
            hasLength(1),
          );
          expect((await media.downloadAndDecryptAttachment()).bytes, [2]);
          expect(
            requests,
            2,
            reason: 'the explicit retry was encrypted and cached',
          );
        });
      },
    );
  }

  test('mounted Instagram adapter rereads SQLCipher cache after 24h', () async {
    await _withDatabase((database, raw) async {
      var requests = 0;
      final media = _asset(database, () async => _response(++requests));
      expect((await media.downloadAndDecryptAttachment()).bytes, [1]);
      expect((await media.downloadAndDecryptAttachment()).bytes, [1]);
      expect(requests, 1);
      await raw.update('personal_media_cache', {
        'saved_at': DateTime.now()
            .subtract(const Duration(days: 1))
            .millisecondsSinceEpoch,
      });
      expect((await media.downloadAndDecryptAttachment()).bytes, [2]);
      expect(
        requests,
        2,
        reason: 'a completed future must not outlive cache TTL',
      );
    });
  });

  test(
    'clear removes an already submitted media store in SQL queue order',
    () async {
      await _withDatabase((database, raw) async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final holding = raw.transaction((_) async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final key = Uri.parse('chatloom-media://instagram/queued-store');
        final storing = database.storeFile(
          key,
          Uint8List.fromList([1, 2, 3]),
          0,
        );
        final clearing = database.clearCache();
        release.complete();
        await Future.wait([holding, storing, clearing]);
        expect(await database.getFile(key), isNull);
        expect(
          await raw.query('personal_media_cache', columns: ['media_key']),
          isEmpty,
        );
      });
    },
  );

  test(
    'cache clear and logout revoke downloads before asynchronous cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'protected_media_cache_',
      );
      final factory = createDatabaseFactoryFfi(noIsolate: true);
      final raw = await factory.openDatabase(
        '${directory.path}/cache.sqlite',
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute(
            "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 9))}'",
          ),
        ),
      );
      var cleanupGate = Completer<void>();
      final database = ProtectedMatrixDatabase(
        'fixture',
        database: raw,
        factory: factory,
        clearFileCaches: () => cleanupGate.future,
      );
      try {
        await database.open();
        final key = Uri.parse('chatloom-media://instagram/fixture');
        for (final clear in [database.clearCache, database.clear]) {
          await database.storeFile(key, Uint8List.fromList([1, 2, 3]), 0);
          final generation = database.mediaCacheGeneration;
          final clearing = clear();
          expect(database.mediaCacheGeneration, generation + 1);
          expect(await database.getFile(key), [1, 2, 3]);
          cleanupGate.complete();
          await clearing;
          expect(await database.getFile(key), isNull);
          expect(await database.hasFile(key), isFalse);
          cleanupGate = Completer<void>();
        }
      } finally {
        await raw.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
