// SPDX-License-Identifier: AGPL-3.0-or-later
// A multi-pick goes out as separate messages, in order, each photo/video
// carrying one album marker. Fictional offline media; no picker, no server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/personal/media/gallery_batch.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../personal/outgoing_media_support.dart';
import 'conversation_test_support.dart';

class _MediaClient extends ConversationClient {
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig(mUploadSize: 1024 * 1024);
}

class _MediaRoom extends ConversationRoom {
  final sent = <({String name, String msgtype, Map<String, dynamic>? extra})>[];
  _MediaRoom(super.client, [super.id = '!fictional-album:example.invalid']);

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    sent.add((name: file.name, msgtype: file.msgType, extra: extraContent));
    return '\$fictional-${sent.length}';
  }
}

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';

XFile _photo(String name) => XFile.fromData(
  base64Decode(_pixelPng),
  name: name,
  path: name,
  mimeType: 'image/png',
);

XFile _text(String name) => XFile.fromData(
  Uint8List.fromList([1, 2, 3]),
  name: name,
  path: name,
  mimeType: 'text/plain',
);

void main() {
  Future<void> send(
    WidgetTester tester,
    _MediaRoom room,
    List<XFile> files, {
    bool asFiles = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSendFileDialog(
                context,
                SendFileDialog(
                  room: room,
                  files: files,
                  outerContext: context,
                  initialCaption: 'Fictional caption',
                  sendAsFiles: asFiles,
                  threadRootEventId: null,
                  threadLastEventId: null,
                ),
              ),
              child: const Text('Open attachments'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open attachments'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  testWidgets('photos picked together share one album marker, in order', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await send(tester, room, [
      _photo('a.png'),
      _text('notes.txt'),
      _photo('b.png'),
      _photo('c.png'),
    ]);
    expect(room.sent.map((s) => s.name), [
      'a.png',
      'notes.txt',
      'b.png',
      'c.png',
    ]);
    final markers = [for (final s in room.sent) s.extra?[MediaAlbumBatch.key]];
    // The file is no album member.
    expect(markers[1], isNull);
    final album = [markers[0], markers[2], markers[3]].cast<Map>();
    expect(album.map((m) => m['id']).toSet(), hasLength(1));
    expect(album.map((m) => m['index']), [0, 1, 2]);
    expect(album.map((m) => m['count']), [3, 3, 3]);
    // The caption stays on the newest item only.
    expect(room.sent.map((s) => s.extra?['body']), [
      null,
      null,
      null,
      'Fictional caption',
    ]);
  });

  testWidgets('one photo, or photos sent as files, carry no marker', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final single = _MediaRoom(_MediaClient());
    await send(tester, single, [_photo('a.png')]);
    expect(
      single.sent.single.extra?.containsKey(MediaAlbumBatch.key) ?? false,
      isFalse,
    );

    final files = _MediaRoom(
      _MediaClient(),
      '!fictional-files:example.invalid',
    );
    await send(tester, files, [
      _photo('a.png'),
      _photo('b.png'),
    ], asFiles: true);
    expect(files.sent, hasLength(2));
    expect(
      files.sent.any((s) => s.extra?.containsKey(MediaAlbumBatch.key) ?? false),
      isFalse,
    );
  });
}
