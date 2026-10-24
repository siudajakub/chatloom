// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: synthetic bytes in a private temp folder; nothing is sent.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/video_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

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
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
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

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
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

    test('clear removes only cache files', () async {
      final cache = await open();
      final key = VideoFileCache.keyFor('@a:x', Uri.parse('mxc://x/a'));
      await cache.write(key, _bytes(_big, 1));
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

    setUp(() {
      transport = _Transport(_bytes(_big, 0x5a));
      client = Client(
        'video cache download',
        database: _Database(),
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
  });
}
