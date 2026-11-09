// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/media/avatar_cache.dart';
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
              : http.Response.bytes([1, 2, 3], 200);
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
      expect(bytes, [1, 2, 3]);
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
          return http.Response.bytes([1, 2, 3], 200);
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
            : http.Response.bytes([1, 2, 3], 200);
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
    expect(await first, [1, 2, 3]);
    expect(await second, [1, 2, 3]);
    expect(requests, 2, reason: 'one thumbnail and one original for both rows');
  });

  test('account change discards late avatar data', () async {
    final started = Completer<void>(), gate = Completer<void>();
    final client = _MediaClient(
      MockClient((_) async {
        started.complete();
        await gate.future;
        return http.Response.bytes([1, 2, 3], 200);
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
          return http.Response.bytes([1, 2, 3], 200);
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
        return http.Response.bytes([1, 2, 3], 200);
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
}
