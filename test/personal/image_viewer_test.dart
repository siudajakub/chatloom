// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixture: synthetic photo events whose downloads never finish; no
// network, account or message data.
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/pages/image_viewer/image_viewer_chrome.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  /// The header asks for the sender's profile; none is stored.
  @override
  Future<User?> getUser(String userId, Room room) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _PhotoEvent extends Event {
  _PhotoEvent(Room room, int i, {String? caption})
    : super(
        room: room,
        eventId: '\$viewer-photo-$i',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime(2026, 3, 4, 12, 30),
        content: {
          'msgtype': MessageTypes.Image,
          'body': caption ?? 'photo$i.png',
          if (caption != null) 'filename': 'photo$i.png',
          'url': 'mxc://example.invalid/full$i',
          'info': {'w': 400, 'h': 300, 'mimetype': 'image/png'},
        },
      );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) => Completer<MatrixFile>().future;
}

List<Event> _album() {
  final room = Room(
    id: '!fixture:example.invalid',
    client: Client('image viewer test', database: _Database()),
  );
  return [
    _PhotoEvent(room, 0),
    _PhotoEvent(room, 1, caption: 'Sunset over the lake'),
    _PhotoEvent(room, 2),
  ];
}

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => unawaited(open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  // The deferred localizations load on fake time (never inside runAsync).
  for (var i = 0; i < 20 && find.text('open').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text('open'));
  await _settleRoute(tester);
}

/// The route and page animations without waiting on the photo loaders.
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(NotionMotion.long);
  await tester.pump(NotionMotion.long);
}

void main() {
  testWidgets('header shows the position and the caption follows the page', (
    tester,
  ) async {
    final album = _album();
    await _open(
      tester,
      (context) => showImageViewer(context, album[1], mediaEvents: album),
    );
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.textContaining('2 of 3'), findsOneWidget);
    expect(find.text('Sunset over the lake'), findsOneWidget);

    // Arrow keys page (the viewer takes focus itself, MD-09).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleRoute(tester);
    expect(find.textContaining('3 of 3'), findsOneWidget);
    expect(find.text('Sunset over the lake'), findsNothing);

    // No page past the last one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleRoute(tester);
    expect(find.textContaining('3 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _settleRoute(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _settleRoute(tester);
    expect(find.textContaining('1 of 3'), findsOneWidget);

    // Esc closes the viewer.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleRoute(tester);
    expect(find.byType(ImageViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Space asks the page to play or pause', (tester) async {
    final album = _album();
    await _open(
      tester,
      (context) => showImageViewer(context, album[0], mediaEvents: album),
    );
    final controller = tester.state<ImageViewerController>(
      find.byType(ImageViewer),
    );
    expect(controller.playPauseRequests.value, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.playPauseRequests.value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleRoute(tester);
  });

  testWidgets('ImageViewer.open starts at the index with the grid hero tags', (
    tester,
  ) async {
    final album = _album();
    Object tag(Event event) => ('grid', event.eventId);
    await _open(
      tester,
      (context) => ImageViewer.open(
        context,
        events: album,
        initialIndex: 2,
        heroTagFor: tag,
        sourceRadius: NotionRadius.smAll,
      ),
    );
    expect(find.textContaining('3 of 3'), findsOneWidget);
    final controller = tester.state<ImageViewerController>(
      find.byType(ImageViewer),
    );
    expect(controller.heroTagFor(album[0]), ('grid', album[0].eventId));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Hero && widget.tag == ('grid', album[2].eventId),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleRoute(tester);
    expect(find.byType(ImageViewer), findsNothing);
  });

  test('position label', () {
    expect(imageViewerPosition(0, 1), isNull);
    expect(imageViewerPosition(2, 12), '3 of 12');
  });
}
