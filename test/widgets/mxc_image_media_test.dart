// SPDX-License-Identifier: AGPL-3.0-or-later
// MxcImage: TGS / Lottie-JSON stickers render (ST-01, ST-14), failures end in
// a static fallback instead of an endless spinner (PF-02).
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/lottie_sticker_data.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Media comes from the client's file cache; anything else is not expected.
class _FileDatabase implements DatabaseApi {
  _FileDatabase(this.file);

  Uint8List? Function() file;
  Object? error;

  @override
  int get maxFileSize => 1 << 24;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async {
    final error = this.error;
    if (error != null) throw error;
    return file();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access ${invocation.memberName}');
}

const _lottie =
    '{"v":"5.5.2","fr":30,"ip":0,"op":30,"w":64,"h":64,"nm":"t",'
    '"ddd":0,"assets":[],"layers":[]}';

Uint8List _tgs() =>
    Uint8List.fromList(GZipEncoder().encodeBytes(utf8.encode(_lottie)));

Event _sticker(Client client, {required String mimetype, int size = 100}) =>
    Event(
      room: Room(id: '!stickers:example.invalid', client: client),
      eventId: r'$sticker',
      senderId: '@fixture:example.invalid',
      type: EventTypes.Sticker,
      originServerTs: DateTime.utc(2026),
      content: {
        'body': 'sticker',
        'url': 'mxc://example.invalid/sticker',
        'info': {'mimetype': mimetype, 'size': size, 'w': 64, 'h': 64},
      },
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reducedMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUp(MxcImage.clearLottieCache);

  group('LottieStickerData', () {
    test('reads TGS and Lottie JSON, nothing else', () {
      expect(LottieStickerData.jsonBytes(_tgs()), isNotNull);
      expect(
        LottieStickerData.jsonBytes(Uint8List.fromList(utf8.encode(_lottie))),
        isNotNull,
      );
      expect(
        LottieStickerData.jsonBytes(
          Uint8List.fromList(utf8.encode('{"name":"not lottie"}')),
        ),
        isNull,
      );
      // A PNG signature.
      expect(
        LottieStickerData.jsonBytes(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]),
        ),
        isNull,
      );
      expect(LottieStickerData.parse(_tgs()), isNotNull);
      expect(LottieStickerData.isLottieMime('application/x-tgsticker'), isTrue);
      expect(LottieStickerData.isLottieMime('image/webp'), isFalse);
    });

    test('the composition cache is bounded', () {
      final cache = LottieCompositionCache<int>(capacity: 2);
      final composition = LottieStickerData.parse(_tgs())!;
      for (var i = 0; i < 5; i++) {
        cache.put(i, composition);
      }
      expect(cache.length, 2);
      expect(cache.get(0), isNull);
      expect(cache.get(4), same(composition));
    });
  });

  testWidgets('a TGS sticker renders as Lottie, not a spinner', (tester) async {
    final client = Client('tgs', database: _FileDatabase(_tgs));
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'application/x-tgsticker'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Lottie), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a Lottie JSON sticker renders; reduced motion is still', (
    tester,
  ) async {
    final json = Uint8List.fromList(utf8.encode(_lottie));
    final client = Client('json', database: _FileDatabase(() => json));
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'video/lottie+json'),
        width: 128,
        height: 128,
      ),
      reducedMotion: true,
    );
    await tester.pump();
    await tester.pump();
    final lottie = tester.widget<Lottie>(find.byType(Lottie));
    expect(lottie.animate, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('unavailable media ends in a static fallback', (tester) async {
    final database = _FileDatabase(() => null)
      ..error = MatrixException.fromJson({'errcode': 'M_NOT_FOUND'});
    final client = Client('missing', database: database);
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'image/webp'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('unsupported bytes end in a static fallback', (tester) async {
    final client = Client(
      'unsupported',
      database: _FileDatabase(() => Uint8List.fromList(List.filled(64, 7))),
    );
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'application/octet-stream'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
