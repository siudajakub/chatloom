// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixture: one synthetic 1x1 PNG, no network or account storage.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

class _ImageEvent extends Event {
  _ImageEvent(Room room)
    : super(
        room: room,
        eventId: r'$cached-avatar',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {'msgtype': MessageTypes.Image},
      );
  int requests = 0;
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
    return MatrixImageFile(bytes: _pixel, name: 'fixture.png');
  }
}

Widget _image(Event event) => MaterialApp(
  home: MxcImage(
    event: event,
    cacheKey: 'inbox-avatar',
    cacheName: 'mxc-image-cache-test',
    width: 40,
    height: 40,
    placeholder: (_) => const Text('placeholder'),
  ),
);

void main() {
  tearDown(() => MxcImage.clearCache('mxc-image-cache-test'));

  testWidgets('a memory-cache hit renders on the first frame without fading', (
    tester,
  ) async {
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
