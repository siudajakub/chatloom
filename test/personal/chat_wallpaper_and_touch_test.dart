// SPDX-License-Identifier: AGPL-3.0-or-later
// A blurred wallpaper is blurred once, not per frame (review PF-12); a
// touched message row does not depend on the whole MediaQuery (PF-14).
// Synthetic pixels and fictional fixtures only.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A small synthetic PNG (two colour bands).
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 64, 32),
    Paint()..color = const Color(0xFF3366CC),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 32, 64, 32),
    Paint()..color = const Color(0xFFCC6633),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('PF-12 blurred wallpaper', () {
    tearDown(BlurredWallpaper.debugClearCache);

    testWidgets('is drawn from one pre-blurred bitmap, no live filter', (
      tester,
    ) async {
      final bytes = await tester.runAsync(_png);
      var loads = 0;
      Widget wallpaper() => MaterialApp(
        home: BlurredWallpaper(
          cacheKey: 'fixture-wallpaper',
          blur: 12,
          opacity: .5,
          load: () async {
            loads++;
            return bytes!;
          },
        ),
      );
      await tester.pumpWidget(wallpaper());
      // Decoding and the one blur pass run off the frame.
      for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.opacity?.value, .5);
      // A blurred bitmap needs few pixels: well under the screen's.
      final size = tester.view.physicalSize;
      expect(raw.image!.width, lessThan(size.width));
      expect(loads, 1);
      expect(BlurredWallpaper.debugCachedBitmaps, 1);

      // Reopening (a new chat page) draws it in the first frame.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(wallpaper());
      expect(find.byType(RawImage), findsOneWidget);
      expect(loads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('raster scale follows the blur and never exceeds the screen', () {
      expect(BlurredWallpaper.rasterScale(1, 3), 3);
      expect(BlurredWallpaper.rasterScale(8, 3), .5);
      expect(BlurredWallpaper.rasterScale(40, 3), .25);
      expect(BlurredWallpaper.rasterScale(1, 1), 1);
    });
  });

  testWidgets('PF-14: a touched row ignores keyboard inset changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    final client = ConversationClient();
    final room = ConversationRoom(client, '!touch:example.invalid');
    final event = room.message(r'$touch', 'Fictional touched message');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    final scroll = ScrollController();
    addTearDown(timeline.cancelSubscriptions);
    addTearDown(scroll.dispose);
    final inset = ValueNotifier(0.0);
    addTearDown(inset.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: ValueListenableBuilder<double>(
          valueListenable: inset,
          builder: (context, bottom, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: EdgeInsets.only(bottom: bottom)),
            child: child!,
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Center(
              child: Message(
                event,
                bigEmojis: const {},
                onInfoTab: (_) {},
                scrollToEventId: (_) {},
                onSwipe: () {},
                timeline: timeline,
                onMention: () {},
                scrollController: scroll,
                enterThread: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A touch (the start of every scroll) used to subscribe the row to the
    // whole MediaQuery.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Fictional touched message')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    final touched = find.byType(ConversationMessageGestures).evaluate().toSet();
    expect(touched, isNotEmpty);
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (touched.contains(element)) rebuilds++;
    };
    try {
      for (final bottom in [120.0, 240.0, 300.0, 0.0]) {
        inset.value = bottom;
        await tester.pump();
      }
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
    expect(rebuilds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
