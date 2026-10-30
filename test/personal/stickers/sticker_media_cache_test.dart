// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: synthetic bytes in a private temp folder; nothing is sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

List<int> _key(int seed) => List<int>.generate(32, (i) => (i * 7 + seed) & 255);

Uint8List _bytes(int length, int seed) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) & 255));

/// A readable marker: it must never appear in a cached file.
final _marker = Uint8List.fromList(utf8.encode('PLAINTEXT-STICKER-MARKER' * 8));

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Answers `/versions` and every media GET with [body]; counts media
/// requests and how many run at once.
class _Transport extends http.BaseClient {
  _Transport(this.body);

  Uint8List body;
  final media = <Uri>[];
  int running = 0, peak = 0;
  Completer<void>? gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/versions')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"versions":["v1.11"]}')),
        200,
      );
    }
    media.add(request.url);
    running++;
    peak = max(peak, running);
    try {
      await gate?.future;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return http.StreamedResponse(Stream.value(body), 200);
    } finally {
      running--;
    }
  }
}

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

StickerItem _sticker(int i, {int? size, String mime = 'image/webp'}) =>
    StickerItem.fromPackImage(
      ImagePackImageContent.fromJson({
        'url': 'mxc://example.invalid/sticker$i',
        'info': {'mimetype': mime, 'size': ?size, 'w': 512, 'h': 512},
      }),
      shortcode: 's$i',
    );

void main() {
  late Directory temp;
  var clock = DateTime.utc(2026, 10, 29);
  DateTime now() => clock;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sticker_cache_test');
    clock = DateTime.utc(2026, 10, 29);
  });

  tearDown(() async {
    StickerMediaCache.debugResetShared();
    await temp.delete(recursive: true);
  });

  Future<StickerMediaCache> open({
    int seed = 1,
    int maxBytes = StickerMediaCache.defaultMaxBytes,
  }) => StickerMediaCache.open(
    Directory('${temp.path}/cache'),
    key: _key(seed),
    maxBytes: maxBytes,
    now: now,
  );

  String key(String name) => StickerMediaCache.keyFor(
    '@fixture:example.invalid',
    Uri.parse('mxc://example.invalid/$name'),
    StickerMediaCache.original,
  );

  List<File> files(StickerMediaCache cache) =>
      cache.directory.listSync().whereType<File>().toList();

  group('StickerMediaCache', () {
    test('round trip; only sealed bytes under hashed names', () async {
      final cache = await open();
      expect(cache.directory.statSync().mode & 0x1ff, 0x1c0);
      expect(await cache.write(key('a'), _marker), isTrue);
      expect(await cache.read(key('a')), _marker);
      final stored = files(cache).single;
      expect(
        stored.uri.pathSegments.last,
        matches(RegExp(r'^[0-9a-f]{64}\.enc$')),
      );
      final onDisk = stored.readAsBytesSync();
      expect(_contains(onDisk, _marker), isFalse);
      expect(_contains(onDisk, utf8.encode('example.invalid')), isFalse);
      // Reopening (another process start) reads it back.
      expect(await (await open()).read(key('a')), _marker);
    });

    test('another key, a tampered or a renamed file is a miss', () async {
      final cache = await open();
      await cache.write(key('a'), _bytes(300, 1));
      await cache.write(key('b'), _bytes(300, 2));

      final other = await open(seed: 9);
      expect(await other.read(key('a')), isNull);
      expect(
        File('${cache.directory.path}/${key('a')}.enc').existsSync(),
        isFalse,
        reason: 'an unreadable file is dropped',
      );

      final b = File('${cache.directory.path}/${key('b')}.enc');
      final sealed = b.readAsBytesSync();
      // Moved to another name: the name is authenticated.
      File('${cache.directory.path}/${key('c')}.enc').writeAsBytesSync(sealed);
      expect(await cache.read(key('c')), isNull);
      sealed[sealed.length - 3] ^= 1;
      b.writeAsBytesSync(sealed);
      expect(await cache.read(key('b')), isNull);
      b.writeAsBytesSync(sealed.sublist(0, 20));
      expect(await cache.read(key('b')), isNull);
    });

    test('least recently used files go past the cap', () async {
      // Each sealed entry is 1000 + 32 bytes: three fit, four do not.
      final cache = await open(maxBytes: 3200);
      await cache.write(key('a'), _bytes(1000, 1));
      clock = clock.add(const Duration(hours: 2));
      await cache.write(key('b'), _bytes(1000, 2));
      clock = clock.add(const Duration(hours: 2));
      await cache.write(key('c'), _bytes(1000, 3));
      clock = clock.add(const Duration(hours: 2));
      // A read marks a as used (after the touch interval).
      expect(await cache.read(key('a')), isNotNull);
      clock = clock.add(const Duration(hours: 2));
      await cache.write(key('d'), _bytes(1000, 4));
      expect(await cache.read(key('b')), isNull);
      for (final name in ['a', 'c', 'd']) {
        expect(await cache.read(key(name)), isNotNull, reason: name);
      }
      expect(await cache.write(key('big'), _bytes(4000, 5)), isFalse);
    });

    test('files unused for a year expire', () async {
      final cache = await open();
      await cache.write(key('old'), _bytes(100, 1));
      clock = clock.add(const Duration(days: 200));
      await cache.write(key('new'), _bytes(100, 2));
      expect(await cache.contains(key('old')), isTrue);
      clock = clock.add(const Duration(days: 200));
      expect(await cache.contains(key('old')), isFalse);
      expect(await cache.read(key('old')), isNull);
      expect(await cache.read(key('new')), isNotNull);
      await cache.evict();
      expect(files(cache), hasLength(1));
    });

    test('clear removes only its own files', () async {
      final cache = await open();
      await cache.write(key('a'), _bytes(100, 1));
      await cache.write(key('b'), _bytes(100, 2));
      final foreign = File('${cache.directory.path}/notes.txt')
        ..writeAsStringSync('keep');
      await cache.clear();
      expect(files(cache).map((f) => f.path), [foreign.path]);
      expect(await cache.read(key('a')), isNull);
    });

    test('concurrent requests share one download; then disk', () async {
      final cache = await open();
      final download = Completer<Uint8List>();
      var downloads = 0;
      Future<Uint8List> fetch() => cache.fetch(key('a'), () {
        downloads++;
        return download.future;
      });
      final first = fetch(), second = fetch();
      download.complete(_bytes(200, 3));
      expect(await first, _bytes(200, 3));
      expect(await second, _bytes(200, 3));
      expect(downloads, 1);
      // The write ends the flight; a later request reads the disk.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fetch(), _bytes(200, 3));
      expect(downloads, 1);
    });

    test('a failed download is not cached and may be retried', () async {
      final cache = await open();
      await expectLater(
        cache.fetch(key('a'), () async => throw const SocketException('x')),
        throwsA(isA<SocketException>()),
      );
      expect(
        await cache.fetch(key('a'), () async => _bytes(10, 1)),
        _bytes(10, 1),
      );
    });

    test('no usable key or folder: the cache is off', () async {
      Future<Directory> base() async => temp;
      expect(
        await StickerMediaCache.openShared(
          base: base,
          key: () async => throw StateError('keystore locked'),
        ),
        isNull,
      );
      expect(
        await StickerMediaCache.openShared(base: base, key: () async => 'x'),
        isNull,
      );
      // A world-readable folder is refused, not used.
      final open = Directory('${temp.path}/${StickerMediaCache.folderName}')
        ..createSync();
      await Process.run('chmod', ['755', open.path]);
      expect(
        await StickerMediaCache.openShared(
          base: base,
          key: () async => base64Url.encode(_key(1)),
        ),
        isNull,
      );
      await Process.run('chmod', ['700', open.path]);
      expect(
        await StickerMediaCache.openShared(
          base: base,
          key: () async => base64Url.encode(_key(1)),
        ),
        isNotNull,
      );
    });
  });

  group('loaders', () {
    late _Transport transport;
    late Client client;

    setUp(() {
      transport = _Transport(_bytes(500, 4));
      client = Client(
        'sticker cache loaders',
        database: _Database(),
        httpClient: transport,
      )..setUserId('@fixture:example.invalid');
      client.homeserver = Uri.parse('https://example.invalid');
    });

    test('the original is fetched once, without the database', () async {
      StickerMediaCache.debugSetShared(await open());
      final uri = Uri.parse('mxc://example.invalid/sticker');
      Future<Uint8List> load() => StickerMediaCache.loadOriginal(
        client,
        uri,
        width: 100,
        height: 100,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.scale,
      );
      expect(await Future.wait([load(), load()]), [
        transport.body,
        transport.body,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await load(), transport.body);
      expect(transport.media, hasLength(1));
      expect(transport.media.single.path, contains('/media/download/'));
    });

    test('prefetch: bounded, skips cached and non-stickers', () async {
      StickerMediaCache.debugSetShared(await open());
      final items = [
        for (var i = 0; i < 12; i++) _sticker(i),
        _sticker(99, size: 5 * 1024 * 1024),
        _sticker(1),
      ];
      final prefetch = StickerPrefetch(client, allowed: () async => true);
      await prefetch.run(items);
      expect(transport.media, hasLength(12));
      expect(transport.peak, lessThanOrEqualTo(4));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await StickerPrefetch(client, allowed: () async => true).run(items);
      expect(transport.media, hasLength(12), reason: 'all on disk');
    });

    test('prefetch stops when cancelled or not allowed', () async {
      StickerMediaCache.debugSetShared(await open());
      final items = [for (var i = 0; i < 20; i++) _sticker(i)];
      await StickerPrefetch(client, allowed: () async => false).run(items);
      expect(transport.media, isEmpty);
      transport.gate = Completer();
      final prefetch = StickerPrefetch(client, allowed: () async => true);
      final run = prefetch.run(items);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      prefetch.cancel();
      transport.gate!.complete();
      await run;
      expect(transport.media, hasLength(4));
    });
  });

  test('prefetch order: recents, then packs from the browsed one', () {
    StickerSection section(
      String key,
      List<StickerItem> items, {
      bool pack = true,
    }) => StickerSection(
      key: key,
      title: key,
      items: items,
      pack: pack
          ? StickerPack.fromContent(
              ImagePackContent.fromJson({}),
              key: key,
              source: StickerPackSource.room,
              fallbackTitle: key,
            )
          : null,
    );
    final recent = section('recent', [_sticker(0)], pack: false);
    final a = section('a', [for (var i = 10; i < 20; i++) _sticker(i)]);
    final b = section('b', [for (var i = 20; i < 30; i++) _sticker(i)]);
    final order = stickerPrefetchOrder(
      [recent, a, b],
      columns: 2,
      rows: 2,
      first: 2,
    );
    expect(order.map((i) => i.key.split('sticker').last), [
      '0',
      '20',
      '21',
      '22',
      '23',
      '10',
      '11',
      '12',
      '13',
    ]);
  });
}
