// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixture: synthetic 1x1 PNGs, no network or account storage.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/image_viewer/progressive_photo.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

final _thumbnail = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
final _full = Uint8List.fromList(_thumbnail);

class _PhotoEvent extends Event {
  _PhotoEvent(Room room)
    : super(
        room: room,
        eventId: r'$progressive-photo',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': MessageTypes.Image,
          'body': 'photo.png',
          'url': 'mxc://example.invalid/full',
          'info': {
            'w': 400,
            'h': 300,
            'thumbnail_url': 'mxc://example.invalid/thumb',
          },
        },
      );

  int thumbnailRequests = 0;
  final List<Completer<MatrixFile>> fullRequests = [];

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    if (getThumbnail) {
      thumbnailRequests++;
      return MatrixImageFile(bytes: _thumbnail, name: 'thumb.png');
    }
    final request = Completer<MatrixFile>();
    fullRequests.add(request);
    return request.future;
  }
}

const _cacheName = 'progressive-photo-test';

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);

/// The bubble in the timeline: caches its thumbnail bytes.
Widget _bubble(Event event) => MxcImage(
  event: event,
  cacheKey: event.eventId,
  cacheName: _cacheName,
  width: 200,
  height: 150,
  fit: BoxFit.cover,
);

Widget _viewer(Event event) => ProgressivePhoto(
  event: event,
  size: const Size(400, 300),
  frame: (context, photo) => Center(child: photo),
);

/// The thumbnail layer: an image decoded from the bubble's exact bytes.
Finder _cachedThumbnail() => find.byWidgetPredicate((widget) {
  if (widget is! Image) return false;
  final provider = widget.image;
  return provider is ResizeImage &&
      provider.imageProvider is MemoryImage &&
      identical((provider.imageProvider as MemoryImage).bytes, _thumbnail);
});

double _thumbnailOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: _cachedThumbnail(),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

/// Shows the bubble, then swaps to the viewer inside the same app (the
/// deferred localizations load once, before the viewer's first frame).
Future<_PhotoEvent> _openFromTimeline(WidgetTester tester) async {
  final room = Room(
    id: '!fixture:example.invalid',
    client: Client('progressive photo', database: _Database()),
  );
  final event = _PhotoEvent(room);
  final viewer = ValueNotifier(false);
  addTearDown(viewer.dispose);
  await tester.pumpWidget(
    _app(
      ValueListenableBuilder<bool>(
        valueListenable: viewer,
        builder: (_, open, _) => open ? _viewer(event) : _bubble(event),
      ),
    ),
  );
  for (var i = 0; i < 10 && event.thumbnailRequests == 0; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
  expect(event.thumbnailRequests, 1);
  viewer.value = true;
  await tester.pump();
  return event;
}

void main() {
  tearDown(() => MxcImage.clearCache(_cacheName));

  testWidgets('opens on the cached timeline thumbnail, then sharpens', (
    tester,
  ) async {
    final event = await _openFromTimeline(tester);
    // First frame: the bubble's bytes at the photo's final size, no new
    // thumbnail download, no spinner yet.
    expect(_cachedThumbnail(), findsOneWidget);
    expect(tester.getSize(_cachedThumbnail()), const Size(400, 300));
    expect(_thumbnailOpacity(tester), 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump();
    expect(event.thumbnailRequests, 1);
    expect(event.fullRequests, hasLength(1));

    // A slow download shows the small loader, the thumbnail stays.
    await tester.pump(NotionMotion.loaderGrace + NotionMotion.short);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(_thumbnailOpacity(tester), 1);

    event.fullRequests.single.complete(
      MatrixImageFile(bytes: _full, name: 'photo.png'),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    // Let the engine decode the first frame of the full image.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(NotionMotion.long);
    await tester.pump(NotionMotion.long);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(_thumbnailOpacity(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed download keeps the thumbnail and offers a retry', (
    tester,
  ) async {
    final event = await _openFromTimeline(tester);
    await tester.pump();
    event.fullRequests.single.completeError(StateError('no key'));
    await tester.pump();
    await tester.pump();
    await tester.pump(NotionMotion.medium);
    expect(find.text('Try again'), findsOneWidget);
    expect(_cachedThumbnail(), findsOneWidget);
    expect(_thumbnailOpacity(tester), 1);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(event.fullRequests, hasLength(2));
    expect(_cachedThumbnail(), findsOneWidget);
    await tester.pump(NotionMotion.medium);
    expect(find.text('Try again'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
