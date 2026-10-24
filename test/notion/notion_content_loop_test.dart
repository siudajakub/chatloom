// SPDX-License-Identifier: AGPL-3.0-or-later
// Content loops play only while visible (BP-01, DESIGN.md motion rule 4):
// the shared gate, the animated-image sniff and MxcImage's use of the gate.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/rendering.dart'
    show RenderConstrainedBox, ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A loop that repeats forever while its ticker is on.
class _Loop extends StatefulWidget {
  const _Loop();

  @override
  State<_Loop> createState() => _LoopState();
}

class _LoopState extends State<_Loop> with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  @override
  void initState() {
    super.initState();
    controller.repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 100);
}

bool _gateOn(WidgetTester tester) => tester
    .widget<TickerMode>(
      find.descendant(
        of: find.byType(NotionContentLoopGate, skipOffstage: false),
        matching: find.byType(TickerMode, skipOffstage: false),
      ),
    )
    .enabled;

Widget _list(ScrollController controller, {bool enabled = true}) => MaterialApp(
  home: Scaffold(
    body: ListView(
      controller: controller,
      // Off-screen rows within one viewport stay mounted (the timeline).
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      children: [
        NotionContentLoopGate(enabled: enabled, child: const _Loop()),
        for (var i = 0; i < 20; i++) const SizedBox(height: 100),
      ],
    ),
  ),
);

class _FileDatabase implements DatabaseApi {
  _FileDatabase(this.bytes);

  final Uint8List bytes;

  @override
  int get maxFileSize => 1 << 24;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access ${invocation.memberName}');
}

final _gif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

Uint8List _webp({required bool animated}) => Uint8List.fromList([
  ...ascii.encode('RIFF'),
  0, 0, 0, 0, //
  ...ascii.encode('WEBPVP8X'),
  10, 0, 0, 0, //
  animated ? 0x02 : 0x00,
  0, 0, 0, 0, 0, 0, 0, 0, 0,
]);

Uint8List _apng() => Uint8List.fromList([
  ..._png.sublist(0, 33), // signature + IHDR
  0, 0, 0, 8, ...ascii.encode('acTL'), 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0,
]);

Event _image(Client client, String mimetype) => Event(
  room: Room(id: '!media:example.invalid', client: client),
  eventId: r'$image',
  senderId: '@fixture:example.invalid',
  type: EventTypes.Sticker,
  originServerTs: DateTime.utc(2026),
  content: {
    'body': 'sticker',
    'url': 'mxc://example.invalid/sticker',
    'info': {'mimetype': mimetype, 'size': 100, 'w': 1, 'h': 1},
  },
);

void main() {
  group('NotionContentLoopGate', () {
    // Active, unmuted tickers register a transient frame callback; a muted
    // (gated) ticker registers none and draws no frames.
    testWidgets('loops on screen, rests off screen, resumes on return', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      await tester.pump();
      expect(_gateOn(tester), isTrue, reason: 'visible');
      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: 'visible',
      );

      // Scrolled out of the viewport but still mounted in the cache extent.
      controller.jumpTo(300);
      await tester.pump();
      await tester.pump();
      expect(find.byType(_Loop, skipOffstage: false), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);

      controller.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: 'back in view',
      );
    });

    testWidgets('less than half visible does not play', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      controller.jumpTo(60);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('disabled (autoplay off) never plays', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller, enabled: false));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('reduced motion and ancestor TickerMode off stop it', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _list(controller),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(
        TickerMode(enabled: false, child: _list(controller)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });

    test('visible share is clipped by the screen', () {
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      expect(NotionContentLoop.visibleShare(box, const Size(800, 600)), 0);
    });
  });

  group('MxcImage.isAnimatedImage', () {
    test('GIF, animated WebP and APNG loop; PNG, still WebP do not', () {
      expect(MxcImage.isAnimatedImage(_gif), isTrue);
      expect(MxcImage.isAnimatedImage(_webp(animated: true)), isTrue);
      expect(MxcImage.isAnimatedImage(_webp(animated: false)), isFalse);
      expect(MxcImage.isAnimatedImage(_apng()), isTrue);
      expect(MxcImage.isAnimatedImage(_png), isFalse);
      expect(MxcImage.isAnimatedImage(Uint8List(3)), isFalse);
    });
  });

  group('MxcImage gate', () {
    Future<void> pump(WidgetTester tester, Client client, String mime) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MxcImage(
                event: _image(client, mime),
                width: 64,
                height: 64,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an animated sticker image is gated', (tester) async {
      await pump(
        tester,
        Client('gif', database: _FileDatabase(_gif)),
        'image/gif',
      );
      expect(find.byType(NotionContentLoopGate), findsOneWidget);
    });

    testWidgets('a Lottie sticker is gated', (tester) async {
      const lottie =
          '{"v":"5.5.2","fr":30,"ip":0,"op":30,"w":64,"h":64,"nm":"t",'
          '"ddd":0,"assets":[],"layers":[]}';
      final tgs = Uint8List.fromList(
        GZipEncoder().encodeBytes(utf8.encode(lottie)),
      );
      MxcImage.clearLottieCache();
      await pump(
        tester,
        Client('tgs', database: _FileDatabase(tgs)),
        'application/x-tgsticker',
      );
      expect(find.byType(NotionContentLoopGate), findsOneWidget);
    });

    testWidgets('a still image is not gated', (tester) async {
      await pump(
        tester,
        Client('png', database: _FileDatabase(_png)),
        'image/png',
      );
      expect(find.byType(NotionContentLoopGate), findsNothing);
    });
  });
}
