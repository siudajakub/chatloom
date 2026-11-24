// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No database access');
}

class _MediaClient extends Client {
  _MediaClient(http.Client transport)
    : super(
        'offline avatar fixture',
        database: _NoDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://example.invalid');
  }
  @override
  Future<bool> authenticatedMediaSupported() async => true;
}

const _png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

void main() {
  setUp(() => AvatarCache.debugSetShared(null));
  tearDown(AvatarCache.debugResetShared);
  test('avatar sizes share a few physical buckets', () {
    expect(AvatarCache.bucketFor(null), 96);
    expect(AvatarCache.bucketFor(42 * 2.625), 256);
    expect(AvatarCache.bucketFor(24 * 3), 96);
    expect(AvatarCache.bucketFor(120 * 3), 640);
    expect(AvatarCache.bucketFor(5000), 640);
  });

  test(
    'expired bridge photo uses another thumbnail for the same account',
    () async {
      final directory = await Directory.systemTemp.createTemp('avatar-bucket');
      addTearDown(() => directory.delete(recursive: true));
      final cache = await StickerMediaCache.open(
        Directory('${await directory.resolveSymbolicLinks()}/cache'),
        key: List.filled(32, 1),
      );
      AvatarCache.debugSetShared(cache);
      final uri = Uri.parse('mxc://example.invalid/expired');
      const owner = '@fixture:example.invalid';
      await cache.write(
        StickerMediaCache.keyFor(owner, uri, 'avatar:256'),
        Uint8List.fromList(_png),
      );
      final client = _MediaClient(
        MockClient(
          (_) async =>
              http.Response('{"errcode":"M_NOT_FOUND","error":"Expired"}', 404),
        ),
      )..setUserId(owner);
      Future<Uint8List> thumbnail() => AvatarCache.loadAvatar(
        client,
        uri,
        width: 40,
        height: 40,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      );
      expect(await thumbnail(), _png);
      client.setUserId('@other:example.invalid');
      await expectLater(thumbnail(), throwsA(isA<MatrixException>()));
    },
  );

  for (final status in [404]) {
    test('thumbnail $status still loads the bridge original', () async {
      final requests = <String>[];
      final client = _MediaClient(
        MockClient((request) async {
          requests.add(request.url.path);
          return request.url.path.contains('/thumbnail/')
              ? http.Response(
                  '{"errcode":"M_UNKNOWN","error":"Unavailable"}',
                  status,
                )
              : http.Response.bytes(_png, 200);
        }),
      );
      final bytes = await AvatarCache.loadAvatar(
        client,
        Uri.parse('mxc://example.invalid/photo'),
        width: 40,
        height: 40,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      );
      expect(bytes, _png);
      expect(requests, hasLength(2));
      expect(requests.last, contains('/download/'));
    });
  }

  test(
    'a thumbnail outage does not trigger a second original download',
    () async {
      var requests = 0;
      final client = _MediaClient(
        MockClient((_) async {
          requests++;
          return http.Response(
            '{"errcode":"M_UNKNOWN","error":"Unavailable"}',
            503,
          );
        }),
      );
      await expectLater(
        AvatarCache.loadAvatar(
          client,
          Uri.parse('mxc://example.invalid/outage'),
          width: 40,
          height: 40,
          isThumbnail: true,
          animated: false,
          thumbnailMethod: ThumbnailMethod.crop,
        ),
        throwsA(isA<MatrixException>()),
      );
      expect(requests, 1);
    },
  );

  test('a missing thumbnail never buffers an oversized original', () async {
    var requests = 0;
    final client = _MediaClient(
      MockClient((request) async {
        requests++;
        return request.url.path.contains('/thumbnail/')
            ? http.Response('{"errcode":"M_UNKNOWN","error":"Missing"}', 404)
            : http.Response.bytes(
                List.filled(AvatarCache.previewDownloadMaxBytes + 1, 7),
                200,
              );
      }),
    );
    await expectLater(
      AvatarCache.loadAvatar(
        client,
        Uri.parse('mxc://example.invalid/oversized'),
        width: 40,
        height: 40,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      ),
      throwsA(isA<MediaDownloadLimitExceeded>()),
    );
    expect(requests, 2);
  });

  test(
    'full photo viewer requests the original without a crop thumbnail',
    () async {
      final requests = <Uri>[];
      final client = _MediaClient(
        MockClient((request) async {
          requests.add(request.url);
          return http.Response.bytes(_png, 200);
        }),
      );
      await AvatarCache.loadAvatar(
        client,
        Uri.parse('mxc://example.invalid/photo'),
        isThumbnail: false,
        animated: false,
        thumbnailMethod: ThumbnailMethod.scale,
      );
      expect(requests.single.path, contains('/download/'));
      expect(requests.single.queryParameters, isEmpty);
    },
  );

  test('rate limit does not fan out into an original download', () async {
    var requests = 0;
    final client = _MediaClient(
      MockClient((_) async {
        requests++;
        return http.Response(
          '{"errcode":"M_LIMIT_EXCEEDED","error":"Wait"}',
          429,
        );
      }),
    );
    await expectLater(
      AvatarCache.loadAvatar(
        client,
        Uri.parse('mxc://example.invalid/photo'),
        width: 40,
        height: 40,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      ),
      throwsA(isA<MatrixException>()),
    );
    expect(requests, 1);
  });

  test(
    'HTTP 429 backs off even with a nonstandard Matrix error code',
    () async {
      var requests = 0;
      final client = _MediaClient(
        MockClient((_) async {
          requests++;
          return http.Response('{"errcode":"M_UNKNOWN","error":"Wait"}', 429);
        }),
      );
      await expectLater(
        AvatarCache.loadAvatar(
          client,
          Uri.parse('mxc://example.invalid/rate-limit'),
          width: 40,
          height: 40,
          isThumbnail: true,
          animated: false,
          thumbnailMethod: ThumbnailMethod.crop,
        ),
        throwsA(isA<MatrixException>()),
      );
      expect(requests, 1);
    },
  );

  test('same bucket shares fallback work even without disk cache', () async {
    var requests = 0;
    final gate = Completer<void>();
    final client = _MediaClient(
      MockClient((request) async {
        requests++;
        await gate.future;
        return request.url.path.contains('/thumbnail/')
            ? http.Response(
                '{"errcode":"M_UNKNOWN","error":"Unavailable"}',
                404,
              )
            : http.Response.bytes(_png, 200);
      }),
    );
    Future<List<int>> load(int size) => AvatarCache.loadAvatar(
      client,
      Uri.parse('mxc://example.invalid/shared'),
      width: size,
      height: size,
      isThumbnail: true,
      animated: false,
      thumbnailMethod: ThumbnailMethod.crop,
    );
    final first = load(40), second = load(80);
    gate.complete();
    expect(await first, _png);
    expect(await second, _png);
    expect(requests, 2, reason: 'one thumbnail and one original for both rows');
  });

  test('account change discards late avatar data', () async {
    final started = Completer<void>(), gate = Completer<void>();
    final client = _MediaClient(
      MockClient((_) async {
        started.complete();
        await gate.future;
        return http.Response.bytes(_png, 200);
      }),
    )..setUserId('@first:example.invalid');
    final pending = AvatarCache.loadAvatar(
      client,
      Uri.parse('mxc://example.invalid/late'),
      isThumbnail: false,
      animated: false,
      thumbnailMethod: ThumbnailMethod.scale,
    );
    final rejected = expectLater(pending, throwsStateError);
    await started.future;
    client.setUserId('@second:example.invalid');
    gate.complete();
    await rejected;
  });

  test(
    'prefetch queue stays bounded and drops obsolete account work',
    () async {
      final gate = Completer<void>();
      var requests = 0;
      final client = _MediaClient(
        MockClient((_) async {
          requests++;
          await gate.future;
          return http.Response.bytes(_png, 200);
        }),
      )..setUserId('@first:example.invalid');
      AvatarCache.prefetch(client, [
        for (var i = 0; i < 1000; i++) Uri.parse('mxc://example.invalid/a$i'),
      ], 96);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(requests, 2);
      expect(AvatarCache.queuedCount, lessThanOrEqualTo(AvatarCache.maxQueued));
      client.setUserId('@second:example.invalid');
      gate.complete();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(requests, 2);
      expect(AvatarCache.queuedCount, 0);
      expect(AvatarCache.rememberedCount, 0);
    },
  );

  test('completed avatar prefetch history has a fixed memory bound', () async {
    var requests = 0;
    final client = _MediaClient(
      MockClient((_) async {
        requests++;
        return http.Response.bytes(_png, 200);
      }),
    )..setUserId('@fixture:example.invalid');
    for (var batch = 0; batch < 17; batch++) {
      AvatarCache.prefetch(client, [
        for (var i = 0; i < 32; i++)
          Uri.parse('mxc://example.invalid/b$batch-$i'),
      ], 96);
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, 17 * 32);
    expect(AvatarCache.queuedCount, 0);
    expect(AvatarCache.rememberedCount, AvatarCache.maxRemembered);
  });

  test('image signatures accept platform formats only', () {
    bool ok(List<int> b) => AvatarCache.looksLikeImage(Uint8List.fromList(b));
    expect(ok(_png), isTrue);
    expect(ok([0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
    expect(ok([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x68]), isTrue);
    expect(ok('RIFF\x00\x00\x00\x00WEBPVP8'.codeUnits), isTrue);
    expect(ok('<html>error</html>'.codeUnits), isFalse);
    expect(ok('{"errcode":"M_UNKNOWN"}'.codeUnits), isFalse);
    expect(ok(const []), isFalse);
  });

  test('undecodable thumbnail falls back to the original', () async {
    final requests = <String>[];
    final client = _MediaClient(
      MockClient((request) async {
        requests.add(request.url.path);
        return request.url.path.contains('/thumbnail/')
            ? http.Response('<html>not an image</html>', 200)
            : http.Response.bytes(_png, 200);
      }),
    );
    final bytes = await AvatarCache.loadAvatar(
      client,
      Uri.parse('mxc://example.invalid/undecodable'),
      width: 40,
      height: 40,
      isThumbnail: true,
      animated: false,
      thumbnailMethod: ThumbnailMethod.crop,
    );
    expect(bytes, _png);
    expect(requests.last, contains('/download/'));
  });

  test('undecodable original fails so a later retry asks again', () async {
    final client = _MediaClient(
      MockClient((_) async => http.Response('not an image', 200)),
    );
    await expectLater(
      AvatarCache.loadAvatar(
        client,
        Uri.parse('mxc://example.invalid/broken'),
        width: 40,
        height: 40,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      ),
      throwsFormatException,
    );
  });
}
