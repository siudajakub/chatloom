// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixture: one synthetic 2x2 PNG, no network or account storage.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _AccountClient extends Client {
  _AccountClient() : super('account cache fixture', database: _Database());

  String? account = '@first:example.invalid';
  DatabaseApi? currentDatabase;

  @override
  String? get userID => account;

  @override
  DatabaseApi get database => currentDatabase ?? super.database;
}

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGP4z8DwHwohFABFzAf5Zsv/OQAAAABJRU5ErkJggg==',
);

class _ImageEvent extends Event {
  _ImageEvent(Room room, {bool limited = false})
    : super(
        room: room,
        eventId: r'$cached-avatar',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': MessageTypes.Image,
          if (limited) 'ttl_seconds': 60,
        },
      );
  int requests = 0;
  Completer<void>? gate;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    requests++;
    if (gate != null) await gate!.future;
    return MatrixImageFile(bytes: _pixel, name: 'fixture.png');
  }
}

Widget _image(Event event, {double size = 40}) => MaterialApp(
  home: MxcImage(
    event: event,
    cacheKey: 'inbox-avatar',
    cacheName: 'mxc-image-cache-test',
    width: size,
    height: size,
    placeholder: (_) => const Text('placeholder'),
  ),
);

void main() {
  tearDown(() => MxcImage.clearCache('mxc-image-cache-test'));

  testWidgets('ten simultaneous event previews download and decrypt once', (
    tester,
  ) async {
    final room = Room(
      id: '!fixture:example.invalid',
      client: Client('shared event', database: _Database()),
    );
    final event = _ImageEvent(room)..gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: List.generate(
            10,
            (_) => MxcImage(event: event, width: 40, height: 40),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(event.requests, 1);
    event.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(10));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resizing an event preview keeps its loaded bytes and frame', (
    tester,
  ) async {
    final event = _ImageEvent(
      Room(
        id: '!fixture:example.invalid',
        client: Client('resize event', database: _Database()),
      ),
    );
    await tester.pumpWidget(_image(event));
    await tester.pump();
    await tester.pump();
    expect(event.requests, 1);
    await tester.pumpWidget(_image(event, size: 80));
    expect(find.byType(Image), findsOneWidget);
    await tester.pump();
    expect(event.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_image(event, size: 120));
    expect(find.byType(Image), findsOneWidget);
    await tester.pump();
    expect(
      event.requests,
      1,
      reason: 'event bytes do not depend on dimensions',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('restricted media cannot reuse another event memory hit', (
    tester,
  ) async {
    final room = Room(
      id: '!fixture:example.invalid',
      client: Client('restricted event', database: _Database()),
    );
    final allowed = _ImageEvent(room);
    await tester.pumpWidget(_image(allowed));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(MxcImage.cachedPreviewOf(allowed), isNotNull);
    final limited = _ImageEvent(room, limited: true);
    expect(MxcImage.cachedPreviewOf(limited), isNull);
    final redacted = _ImageEvent(room)
      ..setRedactionEvent(
        Event(
          room: room,
          eventId: r'$redacted',
          type: EventTypes.Redaction,
          senderId: '@fixture:example.invalid',
          originServerTs: DateTime.utc(2026),
          content: {},
        ),
      );
    expect(MxcImage.cachedPreviewOf(redacted), isNull);
    await tester.pumpWidget(_image(limited));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(limited.requests, 0);

    await tester.pumpWidget(_image(allowed));
    expect(find.byType(Image), findsOneWidget);
    // The SDK may add protective metadata to the existing event object.
    allowed.content['ttl_seconds'] = 60;
    await tester.pumpWidget(_image(allowed));
    expect(find.byType(Image), findsNothing);
    expect(allowed.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'memory hits follow account, server and database on the same Client',
    (tester) async {
      final client = _AccountClient();
      final event = _ImageEvent(
        Room(id: '!fixture:example.invalid', client: client),
      );
      await tester.pumpWidget(_image(event));
      await tester.pump();
      await tester.pump();
      expect(event.requests, 1);
      expect(MxcImage.cachedPreviewOf(event), isNotNull);

      client.account = '@second:example.invalid';
      expect(MxcImage.cachedPreviewOf(event), isNull);
      await tester.pumpWidget(_image(event));
      await tester.pump();
      await tester.pump();
      expect(event.requests, 2);

      client.homeserver = Uri.parse('https://other.example.invalid');
      expect(MxcImage.cachedPreviewOf(event), isNull);
      await tester.pumpWidget(_image(event));
      await tester.pump();
      await tester.pump();
      expect(event.requests, 3);

      client.currentDatabase = _Database();
      expect(MxcImage.cachedPreviewOf(event), isNull);
      await tester.pumpWidget(_image(event));
      await tester.pump();
      await tester.pump();
      expect(event.requests, 4);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('thumbnail method and custom loader are part of source identity', (
    tester,
  ) async {
    final client = Client('thumbnail source', database: _Database());
    final methods = <ThumbnailMethod>[];
    Future<Uint8List> load(
      Client client,
      Uri uri, {
      num? width,
      num? height,
      required bool isThumbnail,
      required bool animated,
      required ThumbnailMethod thumbnailMethod,
    }) async {
      methods.add(thumbnailMethod);
      return _pixel;
    }

    Widget image(ThumbnailMethod method, MxcBytesLoader loader) => MaterialApp(
      home: MxcImage(
        client: client,
        uri: Uri.parse('mxc://example.invalid/photo'),
        cacheKey: 'photo',
        cacheName: 'mxc-image-cache-test',
        width: 40,
        height: 40,
        thumbnailMethod: method,
        loadBytes: loader,
      ),
    );
    await tester.pumpWidget(image(ThumbnailMethod.crop, load));
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(image(ThumbnailMethod.scale, load));
    await tester.pump();
    await tester.pump();
    expect(methods, [ThumbnailMethod.crop, ThumbnailMethod.scale]);
    // Returning to a cached crop reuses its own bytes, not the scale rendition.
    await tester.pumpWidget(image(ThumbnailMethod.crop, load));
    await tester.pump();
    expect(methods, hasLength(2));
    var replacementLoads = 0;
    Future<Uint8List> replacement(
      Client client,
      Uri uri, {
      num? width,
      num? height,
      required bool isThumbnail,
      required bool animated,
      required ThumbnailMethod thumbnailMethod,
    }) async {
      replacementLoads++;
      return _pixel;
    }

    await tester.pumpWidget(image(ThumbnailMethod.crop, replacement));
    await tester.pump();
    await tester.pump();
    expect(replacementLoads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a memory-cache hit renders on the first frame without fading', (
    tester,
  ) async {
    // Other tests decode the same pixel fixture. Start with a cold decoder
    // cache so this test actually exercises the first-load fade.
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    final room = Room(
      id: '!fixture:example.invalid',
      client: Client('mxc cache', database: _Database()),
    );
    final event = _ImageEvent(room);
    await tester.pumpWidget(_image(event));
    expect(find.byType(Image), findsNothing);
    await tester.pump();
    await tester.pump();
    expect(event.requests, 1);
    // A loaded (not cached) image fades its first frame in over the
    // placeholder.
    expect(
      find.descendant(
        of: find.byType(Image),
        matching: find.byType(AnimatedOpacity),
      ),
      findsNWidgets(2),
    );

    // Remount (list reorder / page rebuild): bytes come from memory now.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_image(event));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('placeholder'), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(event.requests, 1);
    expect(tester.takeException(), isNull);
  });
}
