// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: a fixture homeserver in memory and a private temp folder.
// A sticker cell loads the original once (no thumbnail round trip); a later
// build, with the memory cache gone, is served from the disk cache.
import 'dart:convert';
import 'dart:io';

import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_tile.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _Transport extends http.BaseClient {
  final media = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/versions')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"versions":["v1.11"]}')),
        200,
      );
    }
    media.add(request.url);
    return http.StreamedResponse(Stream.value(_png), 200);
  }
}

/// The SQLCipher media cache must not be used by the sticker path.
class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sticker_cell_test');
  });

  tearDown(() async {
    StickerMediaCache.debugResetShared();
    MxcImage.clearCache(stickerCacheName);
    await temp.delete(recursive: true);
  });

  testWidgets('a sticker cell loads the original once, then from disk', (
    tester,
  ) async {
    final transport = _Transport();
    final client = Client(
      'sticker cell cache',
      database: _Database(),
      httpClient: transport,
    )..setUserId('@fixture:example.invalid');
    client.homeserver = Uri.parse('https://example.invalid');
    final cache = (await tester.runAsync(
      () => StickerMediaCache.open(
        Directory('${temp.path}/cache'),
        key: List<int>.generate(32, (i) => i),
      ),
    ))!;
    StickerMediaCache.debugSetShared(cache);
    final item = StickerItem.fromPackImage(
      ImagePackImageContent.fromJson({
        'url': 'mxc://example.invalid/cell',
        'info': {'mimetype': 'image/png', 'size': _png.length},
      }),
      shortcode: 'cell',
    );

    Future<void> show(Key key) async {
      await tester.pumpWidget(
        MaterialApp(
          key: key,
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: StickerImage(item: item, client: client, size: 64),
            ),
          ),
        ),
      );
      // Real I/O (disk, crypto, the fixture server) runs outside fake time.
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(Image), findsOneWidget);
    }

    await show(const ValueKey(1));
    expect(transport.media, hasLength(1));
    expect(transport.media.single.path, contains('/media/download/'));
    expect(transport.media.single.path, isNot(contains('thumbnail')));

    // Let the sealed write finish (its continuations run in the test zone),
    // then forget the memory copy and rebuild.
    for (var i = 0; i < 50 && cache.directory.listSync().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(cache.directory.listSync(), hasLength(1));
    MxcImage.clearCache(stickerCacheName);
    await tester.pumpWidget(const SizedBox());
    await show(const ValueKey(2));
    expect(transport.media, hasLength(1), reason: 'served from disk');
  });
}
