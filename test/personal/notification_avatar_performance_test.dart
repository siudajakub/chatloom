// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/utils/notification_avatar_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No database access');
}

class _Client extends Client {
  _Client(http.Client transport)
    : super(
        'notification fixture',
        database: _Database(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://example.invalid');
  }

  @override
  Future<bool> authenticatedMediaSupported() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AvatarCache.debugSetShared(null));
  tearDown(AvatarCache.debugResetShared);

  test(
    'notification rate limit never restarts the thumbnail request',
    () async {
      var requests = 0;
      final client = _Client(
        MockClient((_) async {
          requests++;
          return http.Response(
            '{"errcode":"M_LIMIT_EXCEEDED","error":"Wait"}',
            429,
          );
        }),
      );
      expect(
        await client.tryDownloadNotificationAvatar(
          Uri.parse('mxc://example.invalid/avatar'),
        ),
        isNull,
      );
      expect(requests, 1);
    },
  );

  test('failed thumbnail and original are attempted only once each', () async {
    var requests = 0;
    final client = _Client(
      MockClient((_) async {
        requests++;
        return http.Response(
          '{"errcode":"M_NOT_FOUND","error":"Missing"}',
          404,
        );
      }),
    );
    expect(
      await client.tryDownloadNotificationAvatar(
        Uri.parse('mxc://example.invalid/avatar'),
      ),
      isNull,
    );
    expect(requests, 2);
  });

  test(
    'bridge original fallback renders a bounded notification bitmap',
    () async {
      final pixel = image.encodePng(image.Image(width: 2, height: 2));
      var requests = 0;
      final client = _Client(
        MockClient((request) async {
          requests++;
          return request.url.path.contains('/thumbnail/')
              ? http.Response('{"errcode":"M_UNKNOWN","error":"Missing"}', 404)
              : http.Response.bytes(pixel, 200);
        }),
      );
      final bytes = await client.tryDownloadNotificationAvatar(
        Uri.parse('mxc://example.invalid/avatar'),
      );
      expect(bytes, isNotNull);
      final codec = await ui.instantiateImageCodec(bytes!);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, notificationAvatarDimension);
          expect(image.height, notificationAvatarDimension);
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
      expect(requests, 2);
    },
  );
}
