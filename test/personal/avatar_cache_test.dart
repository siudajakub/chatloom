// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/media/avatar_cache.dart';
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

  for (final status in [404, 503]) {
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
}
