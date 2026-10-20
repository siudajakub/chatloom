import 'dart:typed_data';

import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No account access');
}

class _Event extends Event {
  int downloads = 0;
  bool? thumbnailRequested;
  _Event(String messageType, {bool thumbnail = false})
    : super(
        room: Room(
          id: '!fixture:example.invalid',
          client: Client('thumbnail fixture', database: _NoDatabase()),
        ),
        eventId: r'$fixture',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': messageType,
          'body': 'fixture',
          'url': 'mxc://example.invalid/media',
          if (thumbnail)
            'info': {'thumbnail_url': 'mxc://example.invalid/thumbnail'},
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
  }) async {
    downloads++;
    thumbnailRequested = getThumbnail;
    return MatrixFile(bytes: Uint8List.fromList([1]), name: 'fixture.bin');
  }
}

void main() {
  for (final type in [
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.File,
  ]) {
    testWidgets(
      '$type without thumbnail never downloads full media from its preview',
      (tester) async {
        final event = _Event(type);
        await tester.pumpWidget(
          MaterialApp(home: MxcImage(event: event, width: 40, height: 40)),
        );
        await tester.pump();
        expect(event.downloads, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('video with thumbnail requests only the thumbnail', (
    tester,
  ) async {
    final event = _Event(MessageTypes.Video, thumbnail: true);
    await tester.pumpWidget(
      MaterialApp(home: MxcImage(event: event, width: 40, height: 40)),
    );
    await tester.pump();
    expect(event.downloads, 1);
    expect(event.thumbnailRequested, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('image without thumbnail keeps its normal image loader', (
    tester,
  ) async {
    final event = _Event(MessageTypes.Image);
    await tester.pumpWidget(
      MaterialApp(home: MxcImage(event: event, width: 40, height: 40)),
    );
    await tester.pump();
    expect(event.downloads, 1);
    expect(event.thumbnailRequested, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
