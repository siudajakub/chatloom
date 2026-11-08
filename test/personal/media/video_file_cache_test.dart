// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: synthetic bytes in a private temp folder; nothing is sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/encrypted_media_cache.dart';
import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:chatloom/personal/media/video_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqlite;

const _big = VideoFileCache.minBytes + 1;

Uint8List _bytes(int length, int seed) =>
    Uint8List(length)..fillRange(0, length, seed);

/// Answers every GET with [body]; counts requests.
class _Transport extends http.BaseClient {
  _Transport(this.body);

  Uint8List body;
  var requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(Stream.value(body), 200);
  }
}

class _Database implements DatabaseApi {
  final deleted = <Uri>[];

  @override
  Future<bool> deleteFile(Uri mxcUri) async {
    deleted.add(mxcUri);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

/// Uses the real short-lived BLOB cache without opening a Matrix account.
class _ProtectedDatabase implements ProtectedMatrixDatabase {
  _ProtectedDatabase(this.media);

  final EncryptedMediaCache media;
  final stored = <Uri>[];
  final deleted = <Uri>[];
  Future<void> Function()? afterStore;
  int generation = 0;

  @override
  int get mediaCacheGeneration => generation;

  @override
  Future<Uint8List?> getFile(Uri key) => media.getFile(key);

  @override
  Future<void> storeFile(Uri key, Uint8List bytes, int time) async {
    await media.storeFile(key, bytes, time);
    stored.add(key);
    await afterStore?.call();
  }

  @override
  Future<bool> deleteFile(Uri key) async {
    deleted.add(key);
    return media.deleteFile(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _PendingVideoCache implements VideoFileCache {
  final started = Completer<void>();
  final release = Completer<void>();
  final removed = <String>[];

  @override
  Future<Uint8List?> read(String key, {bool reel = false}) async => null;

  @override
  Future<bool> write(String key, Uint8List bytes, {bool reel = false}) async {
    started.complete();
    await release.future;
    return true;
  }

  @override
  Future<void> remove(String key, {bool reel = false}) async {
    removed.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected cache access');
}

/// "Decrypts" like the SDK: the bytes from the download callback must equal
/// the server's ciphertext (the hash check), then every byte is inverted.
class _EncryptedVideo extends Event {
  _EncryptedVideo(
    Room room, {
    required this.ciphertext,
    bool encrypted = true,
    Map<String, Object?> extra = const {},
  }) : super(
         room: room,
         eventId: r'$cached-video',
         type: EventTypes.Message,
         senderId: '@fixture:example.invalid',
         originServerTs: DateTime.utc(2026),
         content: {
           'msgtype': MessageTypes.Video,
           'body': 'clip.mp4',
           'info': {'mimetype': 'video/mp4', 'size': ciphertext.length},
           if (encrypted)
             'file': {'url': 'mxc://example.invalid/clip', 'v': 'v2'}
           else
             'url': 'mxc://example.invalid/clip',
           ...extra,
         },
       );

  final Uint8List ciphertext;
  var decrypts = 0;
  bool? usedSdkCache;

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    usedSdkCache = cacheAttachment;
    final data = await downloadCallback!(
      Uri.parse('https://example.invalid/m'),
    );
    if (!isAttachmentEncrypted) {
      return MatrixFile(bytes: data, name: 'clip.mp4', mimeType: 'video/mp4');
    }
    if (data.length != ciphertext.length ||
        data.first != ciphertext.first ||
        data.last != ciphertext.last) {
      throw Exception('sha256 mismatch');
    }
    decrypts++;
    return MatrixFile(
      bytes: Uint8List.fromList([for (final b in data) b ^ 0xff]),
      name: 'clip.mp4',
      mimeType: 'video/mp4',
    );
  }
}

/// Waits for the background store: one complete `.enc` file whose first
/// byte is [first], no partial write left.
Future<File> _stored(Directory directory, int first) async {
  for (var i = 0; i < 500; i++) {
    final files = directory.listSync().whereType<File>().toList();
    final partial = files.any(
      (f) => f.uri.pathSegments.last.startsWith('.partial_'),
    );
    final entries = files.where(
      (f) => f.uri.pathSegments.last.endsWith('.enc'),
    );
    if (!partial && entries.length == 1) {
      final bytes = entries.single.readAsBytesSync();
      if (bytes.isNotEmpty && bytes.first == first) return entries.single;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('the ciphertext was not stored');
}

void main() {
  late Directory temp;
  var now = DateTime.utc(2026, 10, 24, 9);

  setUp(() async {
    now = DateTime.utc(2026, 10, 24, 9);
    temp = await Directory.systemTemp.createTemp('video_file_cache_');
  });

  tearDown(() => temp.delete(recursive: true));

  Future<VideoFileCache> open({int maxBytes = 3 * _big}) => VideoFileCache.open(
    Directory('${temp.path}/${VideoFileCache.folderName}'),
    maxBytes: maxBytes,
    now: () => now,
  );

  List<String> names(Directory directory) =>
      [for (final item in directory.listSync()) item.uri.pathSegments.last]
        ..sort();

  group('keys', () {
    test('hash the account and the mxc; nothing readable on disk', () {
      final mxc = Uri.parse('mxc://example.invalid/clip');
      final key = VideoFileCache.keyFor('@a:example.invalid', mxc);
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(VideoFileCache.keyFor('@a:example.invalid', mxc), key);
      expect(VideoFileCache.keyFor('@b:example.invalid', mxc), isNot(key));
      expect(
        VideoFileCache.keyFor(
          '@a:example.invalid',
          Uri.parse('mxc://example.invalid/other'),
        ),
        isNot(key),
      );
      expect(key, isNot(contains('example')));
    });

    test('a key that is not a hash is refused', () async {
      final cache = await open();
      expect(() => cache.read('../escape'), throwsArgumentError);
    });
  });

  group('storage', () {
    test('creates an owner-only folder and round-trips a file', () async {
      final cache = await open();
      expect((await cache.directory.stat()).mode & 0x1ff, 0x1c0);
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/a'));
      expect(await cache.read(key), isNull);
      expect(await cache.write(key, _bytes(_big, 1)), isTrue);
      expect(names(cache.directory), ['$key.enc']);
      final read = await cache.read(key);
      expect(read!.length, _big);
      expect(read.first, 1);
    });

    test('small files (SQLCipher cache) and oversize files are not '
        'stored', () async {
      final cache = await open(maxBytes: _big + 10);
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/a'));
      expect(
        await cache.write(key, _bytes(VideoFileCache.minBytes, 1)),
        isFalse,
      );
      expect(await cache.write(key, _bytes(_big + 11, 1)), isFalse);
      expect(names(cache.directory), isEmpty);
    });

    test('evicts the least recently used file past the size limit', () async {
      final cache = await open(maxBytes: 2 * _big + 100);
      String key(String id) => VideoFileCache.keyFor('@a:x', Uri.parse(id));
      await cache.write(key('mxc://x/a'), _bytes(_big, 1));
      now = now.add(const Duration(minutes: 1));
      await cache.write(key('mxc://x/b'), _bytes(_big, 2));
      now = now.add(const Duration(minutes: 1));
      // Reading A makes B the least recently used.
      expect(await cache.read(key('mxc://x/a')), isNotNull);
      now = now.add(const Duration(minutes: 1));
      await cache.write(key('mxc://x/c'), _bytes(_big, 3));
      expect(await cache.read(key('mxc://x/b')), isNull);
      expect(await cache.read(key('mxc://x/a')), isNotNull);
      expect(await cache.read(key('mxc://x/c')), isNotNull);
      expect(names(cache.directory), hasLength(2));
    });

    test('the file just stored stays even when it alone fills the '
        'cache', () async {
      final cache = await open(maxBytes: _big + 100);
      String key(String id) => VideoFileCache.keyFor('@a:x', Uri.parse(id));
      await cache.write(key('mxc://x/a'), _bytes(_big, 1));
      now = now.add(const Duration(minutes: 1));
      await cache.write(key('mxc://x/b'), _bytes(_big, 2));
      expect(names(cache.directory), ['${key('mxc://x/b')}.enc']);
    });

    test('expired files are neither returned nor kept', () async {
      final cache = await open();
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/a'));
      await cache.write(key, _bytes(_big, 1));
      now = now.add(VideoFileCache.defaultRetention + const Duration(hours: 1));
      expect(await cache.read(key), isNull);
      expect(names(cache.directory), isEmpty);
    });

    test('small reels expire exactly one day after storing, even after '
        'repeated reads', () async {
      final cache = await open();
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/reel'));
      final savedAt = now;
      expect(await cache.write(key, _bytes(1024, 1), reel: true), isTrue);
      expect(names(cache.directory), ['$key.reel.enc']);
      now = now.add(const Duration(hours: 23));
      expect(await cache.read(key, reel: true), hasLength(1024));
      expect(
        (await File(
          '${cache.directory.path}/$key.reel.enc',
        ).stat()).modified.toUtc(),
        savedAt,
      );
      now = savedAt.add(VideoFileCache.reelRetention);
      expect(await cache.read(key, reel: true), isNull);
      expect(names(cache.directory), isEmpty);
    });

    test('eviction expires reels while ordinary videos keep their '
        'thirty-day retention', () async {
      final cache = await open();
      final video = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/video'));
      final reel = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/reel'));
      await cache.write(video, _bytes(_big, 1));
      await cache.write(reel, _bytes(1024, 2), reel: true);
      now = now.add(VideoFileCache.reelRetention);
      expect(await cache.evict(), _big);
      expect(names(cache.directory), ['$video.enc']);
      expect(await cache.read(video), isNotNull);
    });

    test('a legacy reel copy with unknown download time is dropped', () async {
      final cache = await open();
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/reel'));
      await cache.write(key, _bytes(_big, 1));
      expect(await cache.read(key, reel: true), isNull);
      expect(names(cache.directory), isEmpty);
    });

    test('clear removes only cache files', () async {
      final cache = await open();
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/a'));
      await cache.write(key, _bytes(_big, 1));
      await cache.write(key, _bytes(1024, 2), reel: true);
      File('${cache.directory.path}/unrelated').writeAsStringSync('keep');
      await cache.clear();
      expect(names(cache.directory), ['unrelated']);
    });

    test('a shared or linked folder is refused (fail closed)', () async {
      final shared = Directory('${temp.path}/shared')..createSync();
      await Process.run('chmod', ['0777', shared.path]);
      await expectLater(VideoFileCache.open(shared), throwsA(anything));

      final real = Directory('${temp.path}/real')..createSync();
      await Process.run('chmod', ['0700', real.path]);
      final link = Link('${temp.path}/link')..createSync(real.path);
      await expectLater(
        VideoFileCache.open(Directory(link.path)),
        throwsA(anything),
      );
    });
  });

  group('appliesTo', () {
    final client = Client('video cache applies', database: _Database());
    final room = Room(id: '!fixture:example.invalid', client: client);

    test('encrypted video over 10 MB', () {
      expect(
        VideoFileCache.appliesTo(
          _EncryptedVideo(room, ciphertext: _bytes(_big, 1)),
        ),
        isTrue,
      );
    });

    test('encrypted shared reels use the short cache even below 10 MB', () {
      expect(
        VideoFileCache.appliesTo(
          _EncryptedVideo(
            room,
            ciphertext: _bytes(1000, 1),
            extra: {'external_url': 'https://www.instagram.com/reel/fixture/'},
          ),
        ),
        isTrue,
      );
    });

    test('not unencrypted (plaintext), small or disappearing media', () {
      expect(
        VideoFileCache.appliesTo(
          _EncryptedVideo(room, ciphertext: _bytes(_big, 1), encrypted: false),
        ),
        isFalse,
      );
      expect(
        VideoFileCache.appliesTo(
          _EncryptedVideo(room, ciphertext: _bytes(1000, 1)),
        ),
        isFalse,
      );
      expect(
        VideoFileCache.appliesTo(
          _EncryptedVideo(
            room,
            ciphertext: _bytes(_big, 1),
            extra: {
              'com.beeper.disappearing_timer': {
                'type': 'after_read',
                'timer': 60000,
              },
            },
          ),
        ),
        isFalse,
      );
    });
  });

  group('download through the cache', () {
    late _Transport transport;
    late Client client;
    late Room room;
    late _Database database;

    setUp(() {
      transport = _Transport(_bytes(_big, 0x5a));
      database = _Database();
      client = Client(
        'video cache download',
        database: database,
        httpClient: transport,
      )..setUserId('@fixture:example.invalid');
      room = Room(id: '!fixture:example.invalid', client: client);
    });

    Future<MatrixFile> download(Event event, VideoFileCache cache) =>
        downloadAttachmentCancellable(
          event,
          token: MediaDownloadToken(),
          videoCache: () async => cache,
        );

    test('stores the ciphertext only and reopens without a download', () async {
      final cache = await open();
      final event = _EncryptedVideo(room, ciphertext: transport.body);
      final first = await download(event, cache);
      expect(first.bytes.first, 0x5a ^ 0xff);
      expect(transport.requests, 1);
      final stored = await _stored(cache.directory, 0x5a);
      final onDisk = stored.readAsBytesSync();
      // Exactly the downloaded ciphertext, never the decrypted video.
      expect(onDisk.first, 0x5a);
      expect(onDisk.length, transport.body.length);

      final second = await download(event, cache);
      expect(transport.requests, 1, reason: 'served from the cache');
      expect(second.bytes.first, 0x5a ^ 0xff);
      expect(event.decrypts, 2, reason: 'the SDK checks every cached read');
      expect(event.usedSdkCache, isTrue);
    });

    test('an immediate reel reopen uses ciphertext; after one day it '
        'downloads again and never uses the SDK thirty-day cache', () async {
      transport.body = _bytes(1024, 0x5a);
      final cache = await open();
      final event = _EncryptedVideo(
        room,
        ciphertext: transport.body,
        extra: {'external_url': 'https://www.instagram.com/reel/fixture/'},
      );
      final savedAt = now;
      await download(event, cache);
      // No settling/waiting for a background write before the second tap.
      final second = await download(event, cache);
      expect(transport.requests, 1);
      expect(second.bytes.first, 0x5a ^ 0xff);
      expect(event.usedSdkCache, isFalse);
      expect(database.deleted, [
        event.attachmentMxcUrl,
        event.attachmentMxcUrl,
      ]);
      final stored = await _stored(cache.directory, 0x5a);
      expect(stored.path, endsWith('.reel.enc'));
      expect(stored.readAsBytesSync(), transport.body);
      now = savedAt.add(const Duration(hours: 23));
      await download(event, cache);
      expect(transport.requests, 1);
      now = savedAt.add(VideoFileCache.reelRetention);
      await download(event, cache);
      expect(transport.requests, 2);
      expect(event.decrypts, 4);
    });

    test(
      'cancelling while ciphertext is being stored prevents playback',
      () async {
        final cache = _PendingVideoCache();
        final event = _EncryptedVideo(room, ciphertext: transport.body);
        final token = MediaDownloadToken();
        final future = downloadAttachmentCancellable(
          event,
          token: token,
          videoCache: () async => cache,
        );
        await cache.started.future;
        token.cancel();
        cache.release.complete();
        await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
      },
    );

    test('a damaged reel ciphertext is replaced after SDK verification '
        'fails', () async {
      transport.body = _bytes(1024, 0x5a);
      final cache = await open();
      final event = _EncryptedVideo(
        room,
        ciphertext: transport.body,
        extra: {'external_url': 'https://www.facebook.com/reel/fixture/'},
      );
      final key = VideoFileCache.keyFor(
        client.userID!,
        event.attachmentMxcUrl!,
      );
      await cache.write(key, _bytes(1024, 0x01), reel: true);
      final file = await download(event, cache);
      expect(file.bytes.first, 0x5a ^ 0xff);
      expect(transport.requests, 1);
      expect(await cache.read(key, reel: true), transport.body);
    });

    test('no decrypted bytes anywhere under the cache folder', () async {
      final cache = await open();
      final event = _EncryptedVideo(room, ciphertext: transport.body);
      await download(event, cache);
      await _stored(cache.directory, 0x5a);
      for (final file in temp.listSync(recursive: true).whereType<File>()) {
        final bytes = file.readAsBytesSync();
        expect(bytes.contains(0x5a ^ 0xff), isFalse);
      }
    });

    test('a damaged cached copy is dropped and downloaded again', () async {
      final cache = await open();
      final event = _EncryptedVideo(room, ciphertext: transport.body);
      final key = VideoFileCache.keyFor(
        client.userID!,
        event.attachmentMxcUrl!,
      );
      await cache.write(key, _bytes(_big, 0x01));
      final file = await download(event, cache);
      expect(file.bytes.first, 0x5a ^ 0xff);
      expect(transport.requests, 1);
      await _stored(cache.directory, 0x5a);
      final stored = await cache.read(key);
      expect(stored!.first, 0x5a);
    });

    test('unencrypted videos are never written to disk', () async {
      final cache = await open();
      final event = _EncryptedVideo(
        room,
        ciphertext: transport.body,
        encrypted: false,
      );
      await download(event, cache);
      await download(event, cache);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.requests, 2);
      expect(names(cache.directory), isEmpty);
    });

    test('unencrypted reels without SQLCipher stay uncached and bypass '
        'the SDK thirty-day cache', () async {
      transport.body = _bytes(1024, 0x5a);
      final cache = await open();
      final event = _EncryptedVideo(
        room,
        ciphertext: transport.body,
        encrypted: false,
        extra: {'external_url': 'https://www.instagram.com/reel/fixture/'},
      );
      await download(event, cache);
      await download(event, cache);
      expect(transport.requests, 2);
      expect(event.usedSdkCache, isFalse);
      expect(names(cache.directory), isEmpty);
    });
  });

  group('unencrypted native reels in SQLCipher', () {
    final factory = sqlite.createDatabaseFactoryFfi(noIsolate: true);
    late sqlite.Database sql;
    late EncryptedMediaCache media;
    late _ProtectedDatabase database;
    late _Transport transport;
    late Client client;
    late Room room;

    setUp(() async {
      sql = await factory.openDatabase(
        '${temp.path}/synthetic-cache.sqlite',
        options: sqlite.OpenDatabaseOptions(
          onConfigure: (db) => db.execute(
            "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 7))}'",
          ),
        ),
      );
      media = EncryptedMediaCache(sql, now: () => now);
      await media.initialize();
      database = _ProtectedDatabase(media);
      transport = _Transport(_bytes(_big, 0x5a));
      client = Client(
        'native reel encrypted cache',
        database: database,
        httpClient: transport,
      )..setUserId('@fixture:example.invalid');
      room = Room(id: '!fixture:example.invalid', client: client);
    });

    tearDown(() => sql.close());

    _EncryptedVideo reel({Map<String, Object?> extra = const {}}) =>
        _EncryptedVideo(
          room,
          ciphertext: transport.body,
          encrypted: false,
          extra: {
            'external_url': 'https://www.instagram.com/reel/fixture/',
            ...extra,
          },
        );

    Future<MatrixFile> download(Event event, {MediaDownloadToken? token}) =>
        downloadAttachmentCancellable(
          event,
          token: token ?? MediaDownloadToken(),
          videoCache: () async => throw StateError('plaintext disk cache'),
        );

    test('large unencrypted reel reopens from the encrypted BLOB cache '
        'with an opaque one-day key and no plaintext disk file', () async {
      final event = reel();
      await download(event);
      final second = await download(event);
      expect(second.bytes, transport.body);
      expect(transport.requests, 1);
      expect(event.usedSdkCache, isFalse);
      final key = database.stored.single;
      expect(
        key.toString(),
        matches(RegExp(r'^chatloom-media://instagram/native/[0-9a-f]{64}$')),
      );
      expect(await media.getFile(key), transport.body);
      expect(await media.getFile(event.attachmentMxcUrl!), isNull);
      expect(database.deleted, [
        event.attachmentMxcUrl,
        event.attachmentMxcUrl,
      ]);
      expect(
        Directory('${temp.path}/${VideoFileCache.folderName}').existsSync(),
        isFalse,
      );
    });

    test('native BLOB reads never extend the one-day lifetime', () async {
      transport.body = _bytes(1024, 0x5a);
      final event = reel();
      final savedAt = now;
      await download(event);
      now = savedAt.add(const Duration(hours: 23));
      await download(event);
      expect(transport.requests, 1);
      now = savedAt.add(EncryptedMediaCache.instagramRetention);
      await download(event);
      expect(transport.requests, 2);
    });

    test('local permalink adapters retain their own cache flow', () async {
      transport.body = _bytes(1024, 0x5a);
      final event = reel(extra: {'chatloom.local_media': true});
      await download(event);
      expect(event.usedSdkCache, isTrue);
      expect(database.stored, isEmpty);
      expect(database.deleted, isEmpty);
    });

    test('disappearing unencrypted reels are not stored', () async {
      transport.body = _bytes(1024, 0x5a);
      final event = reel(
        extra: {
          'com.beeper.disappearing_timer': {
            'type': 'after_read',
            'timer': 60000,
          },
        },
      );
      await download(event);
      await download(event);
      expect(transport.requests, 2);
      expect(database.stored, isEmpty);
      expect(event.usedSdkCache, isFalse);
      expect(await sql.query('personal_media_cache'), isEmpty);
    });

    test('cancelling during a BLOB store prevents playback', () async {
      transport.body = _bytes(1024, 0x5a);
      final started = Completer<void>();
      final release = Completer<void>();
      database.afterStore = () async {
        started.complete();
        await release.future;
      };
      final token = MediaDownloadToken();
      final future = download(reel(), token: token);
      await started.future;
      token.cancel();
      release.complete();
      await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
    });

    test('clear-cache revokes stale playback without deleting a newer '
        'same-key cache entry', () async {
      transport.body = _bytes(1024, 0x5a);
      final started = Completer<void>();
      final release = Completer<void>();
      database.afterStore = () async {
        started.complete();
        await release.future;
      };
      final future = download(reel());
      await started.future;
      database.generation++;
      await media.clear();
      final key = database.stored.single;
      final newerBytes = _bytes(1024, 0x7b);
      await media.storeFile(key, newerBytes, 0);
      release.complete();
      await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
      expect(await media.getFile(key), newerBytes);
    });

    test('clear-cache also revokes an encrypted native reel during its '
        'ciphertext-file store', () async {
      transport.body = _bytes(1024, 0x5a);
      final cache = _PendingVideoCache();
      final event = _EncryptedVideo(
        room,
        ciphertext: transport.body,
        extra: {'external_url': 'https://www.instagram.com/reel/fixture/'},
      );
      final future = downloadAttachmentCancellable(
        event,
        token: MediaDownloadToken(),
        videoCache: () async => cache,
      );
      await cache.started.future;
      database.generation++;
      cache.release.complete();
      await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
      expect(cache.removed, hasLength(1));
    });
  });
}
