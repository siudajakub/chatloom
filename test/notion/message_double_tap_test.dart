// SPDX-License-Identifier: AGPL-3.0-or-later
// Double tap to react on message content (wave 13): text under the
// timeline's SelectionArea, links, media, stickers and round videos share
// their taps with the double tap (their single tap waits out the window);
// controls stay instant. Synthetic widgets and events only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/pages/chat/events/video_player.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Log {
  var likes = 0;
  var presses = 0;
  var replies = 0;
  String? selected;
}

const _short = Duration(milliseconds: 30);

/// A message surface as the timeline builds it: inside the list-wide
/// SelectionArea, with reply, quick like and the menu.
Future<_Log> _mount(
  WidgetTester tester,
  Widget child, {
  bool quickLike = true,
  bool scrollable = false,
  Widget? below,
}) async {
  final log = _Log();
  final message = Center(
    child: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConversationMessageGestures(
            identity: 'fictional-event',
            quickLikeEnabled: quickLike,
            onReply: () => log.replies++,
            onLike: () async {
              log.likes++;
              return true;
            },
            likePreview: () => (emoji: '❤️', adds: true),
            onLongPress: (press) {
              log.presses++;
              press.snapshot?.dispose();
            },
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
          ?below,
        ],
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SelectionArea(
          onSelectionChanged: (content) => log.selected = content?.plainText,
          child: scrollable
              ? ListView(
                  key: const ValueKey('fictional-timeline'),
                  children: [
                    const SizedBox(height: 200),
                    message,
                    const SizedBox(height: 1200),
                  ],
                )
              : message,
        ),
      ),
    ),
  );
  return log;
}

/// Taps at [at], one per hold, [gap] apart: the way a finger taps, with
/// time between touch and lift.
Future<void> _taps(
  WidgetTester tester,
  Offset at,
  List<Duration> holds, {
  Duration gap = const Duration(milliseconds: 90),
}) async {
  for (var i = 0; i < holds.length; i++) {
    if (i > 0) await tester.pump(gap);
    final finger = await tester.startGesture(at);
    await tester.pump(holds[i]);
    await finger.up();
  }
  await tester.pump();
}

/// A tap target that shares its taps, like a photo or a video thumbnail.
Widget _media(VoidCallback onTap) => ConversationMessageChromeTap(
  child: Material(
    child: InkWell(
      key: const ValueKey('fictional-media'),
      onTap: onTap,
      child: const SizedBox(width: 240, height: 140),
    ),
  ),
);

void main() {
  testWidgets('a held second tap on text reacts instead of selecting a word', (
    tester,
  ) async {
    final log = await _mount(tester, const Text('Fictional words to tap'));
    final at = tester.getCenter(find.text('Fictional words to tap'));
    // The second touch rests longer than the selection's press timeout.
    await _taps(tester, at, [
      const Duration(milliseconds: 40),
      const Duration(milliseconds: 160),
    ]);
    expect(log.likes, 1);
    expect(log.selected ?? '', isEmpty);
    expect(find.text('❤️'), findsOneWidget);
    await tester.pumpAndSettle();
    // A quick one too, and a slow gap between the taps.
    await tester.pump(const Duration(milliseconds: 400));
    await _taps(tester, at, [
      _short,
      _short,
    ], gap: const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(log.likes, 2);
    expect(log.selected ?? '', isEmpty);
  });

  testWidgets(
    'a first tap just off the bubble pairs with a second on it: a reaction, '
    'not a selected word',
    (tester) async {
      final log = await _mount(
        tester,
        const Text('Fictional words to tap'),
        // The time under a bubble: text of the row, outside its surface.
        below: const Text('12:30'),
      );
      final off = tester.getTopLeft(find.text('12:30')) + const Offset(8, 6);
      final on =
          tester.getTopLeft(find.text('Fictional words to tap')) +
          const Offset(8, 8);
      expect((on - off).distance, lessThan(kDoubleTapSlop));
      // Real pointers carry timestamps; the pairing reads them.
      final first = await tester.createGesture();
      await first.down(off, timeStamp: const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 40));
      await first.up(timeStamp: const Duration(milliseconds: 10040));
      await tester.pump(const Duration(milliseconds: 90));
      final second = await tester.createGesture();
      await second.down(on, timeStamp: const Duration(milliseconds: 10130));
      await tester.pump(const Duration(milliseconds: 160));
      await second.up(timeStamp: const Duration(milliseconds: 10290));
      await tester.pump();
      expect(log.selected ?? '', isEmpty);
      expect(log.likes, 1);
      await tester.pumpAndSettle();
      // Too slow a second tap is a tap of its own.
      await tester.pump(const Duration(milliseconds: 400));
      await first.down(off, timeStamp: const Duration(seconds: 20));
      await first.up(timeStamp: const Duration(milliseconds: 20030));
      await tester.pump(const Duration(milliseconds: 470));
      await second.down(on, timeStamp: const Duration(milliseconds: 20500));
      await second.up(timeStamp: const Duration(milliseconds: 20530));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(log.likes, 1);
    },
  );

  testWidgets('a link opens after the window; a double tap only reacts', (
    tester,
  ) async {
    var opened = 0;
    final link = TapGestureRecognizer()..onTap = () => opened++;
    addTearDown(link.dispose);
    final log = await _mount(
      tester,
      Text.rich(
        TextSpan(
          text: 'Fictional ',
          children: [TextSpan(text: 'link', recognizer: link)],
        ),
      ),
    );
    final rect = tester.getRect(
      find.text('Fictional link', findRichText: true),
    );
    final onLink = rect.centerRight - const Offset(8, 0);
    await _taps(tester, onLink, [_short, const Duration(milliseconds: 150)]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(log.likes, 1);
    expect(opened, 0);
    await tester.pumpAndSettle();
    await tester.tapAt(onLink);
    await tester.pump();
    expect(opened, 0);
    await tester.pump(kDoubleTapTimeout);
    expect(opened, 1);
    expect(log.likes, 1);
  });

  testWidgets('media taps once after the window; a double tap only reacts', (
    tester,
  ) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++));
    final at = tester.getCenter(find.byKey(const ValueKey('fictional-media')));
    await tester.tapAt(at);
    await tester.pump();
    expect(opened, 0);
    await tester.pump(kDoubleTapTimeout);
    expect(opened, 1);
    await tester.pump(const Duration(milliseconds: 100));
    await _taps(tester, at, [_short, const Duration(milliseconds: 120)]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(log.likes, 1);
    expect(opened, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('a quick third tap is absorbed: one reaction, nothing opens', (
    tester,
  ) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++));
    final at = tester.getCenter(find.byKey(const ValueKey('fictional-media')));
    await _taps(tester, at, [_short, _short, _short]);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(log.likes, 1);
    expect(opened, 0);
  });

  testWidgets('with quick reactions off media opens at once', (tester) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++), quickLike: false);
    final at = tester.getCenter(find.byKey(const ValueKey('fictional-media')));
    await tester.tapAt(at);
    await tester.pump();
    expect(opened, 1);
    await _taps(tester, at, [_short, _short]);
    expect(opened, 3);
    expect(log.likes, 0);
  });

  testWidgets('controls stay instant and keep their double taps', (
    tester,
  ) async {
    var plays = 0;
    final log = await _mount(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: TextButton(onPressed: () => plays++, child: const Text('Play')),
      ),
    );
    final at = tester.getCenter(find.text('Play'));
    await tester.tapAt(at);
    await tester.pump();
    expect(plays, 1);
    await tester.pump(const Duration(milliseconds: 400));
    await _taps(tester, at, [_short, _short]);
    await tester.pumpAndSettle();
    expect(plays, 3);
    expect(log.likes, 0);
  });

  testWidgets('a long-press on media opens the menu, not the media', (
    tester,
  ) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++));
    final finger = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('fictional-media'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await finger.up();
    await tester.pumpAndSettle();
    expect(log.presses, 1);
    expect(opened, 0);
    expect(log.likes, 0);
  });

  testWidgets('a second touch that scrolls stays a scroll', (tester) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++), scrollable: true);
    final at = tester.getCenter(find.byKey(const ValueKey('fictional-media')));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    final finger = await tester.startGesture(at);
    await finger.moveBy(const Offset(0, -12));
    await finger.moveBy(const Offset(0, -60));
    await finger.moveBy(const Offset(0, -60));
    await finger.up();
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(log.likes, 0);
    // Nothing waits any more: no late reaction, no late open.
    await tester.pump(const Duration(milliseconds: 500));
    expect(log.likes, 0);
    expect(opened, lessThanOrEqualTo(1));
  });

  testWidgets('swipe to reply still starts on shared media', (tester) async {
    var opened = 0;
    final log = await _mount(tester, _media(() => opened++));
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('fictional-media'))),
    );
    await drag.moveBy(const Offset(24, 0));
    await drag.moveBy(const Offset(70, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(log.replies, 1);
    expect(opened, 0);
  });

  testWidgets('round video: the circle and its play button share taps', (
    tester,
  ) async {
    var toggles = 0;
    final log = await _mount(
      tester,
      RoundVideoView(
        circleKey: const Key('fictional-circle'),
        diameter: 200,
        duration: const Duration(seconds: 20),
        onToggle: () => toggles++,
      ),
    );
    final circle = tester.getRect(find.byKey(const Key('fictional-circle')));
    final play = tester.getCenter(find.byTooltip('Play round video'));
    final edge = circle.topCenter + const Offset(0, 36);
    for (final at in [play, edge]) {
      await _taps(tester, at, [_short, const Duration(milliseconds: 140)]);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }
    expect(log.likes, 2);
    expect(toggles, 0);
    await tester.tapAt(play);
    await tester.pump();
    expect(toggles, 0);
    await tester.pump(kDoubleTapTimeout);
    expect(toggles, 1);
  });

  group('timeline media', () {
    late Room room;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
      // The placeholder has the exact frame; nothing is downloaded.
      await AppSettings.showThumbnailsInTimeline.setItem(false);
      BlurHash.decoder = BlurHash.decodeInline;
    });

    setUp(() {
      final client = Client('double tap', database: _UnusedDatabase());
      room = Room(id: '!room:example.invalid', client: client);
    });

    // Local ids: no transcript slot, nothing that would reach the network.
    Event media(String type, {Map<String, Object?> info = const {}}) => Event(
      content: {
        'msgtype': type,
        'body': 'fictional',
        'url': 'mxc://example.invalid/media',
        'info': {'w': 320, 'h': 200, ...info},
      },
      type: EventTypes.Message,
      eventId: 'fictional-local-media',
      senderId: '@sender:example.invalid',
      originServerTs: DateTime.utc(2026),
      room: room,
    );

    for (final sticker in [false, true]) {
      testWidgets(
        'a ${sticker ? 'sticker' : 'photo'} reacts on a double tap and '
        'opens after a single tap',
        (tester) async {
          var opened = 0;
          final log = await _mount(
            tester,
            ImageBubble(
              media(MessageTypes.Image),
              width: 200,
              height: 140,
              sticker: sticker,
              onTap: () => opened++,
            ),
          );
          final at = tester.getCenter(find.byType(ImageBubble));
          await _taps(tester, at, [_short, const Duration(milliseconds: 130)]);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          expect(log.likes, 1);
          expect(opened, 0);
          await tester.tapAt(at);
          await tester.pump(kDoubleTapTimeout);
          expect(opened, 1);
        },
      );
    }

    for (final gif in [false, true]) {
      testWidgets('a ${gif ? 'GIF' : 'video'} reacts on a double tap', (
        tester,
      ) async {
        final log = await _mount(
          tester,
          gif
              ? InlineLoopVideo(
                  media(MessageTypes.Video, info: {'fi.mau.gif': true}),
                  width: 200,
                  height: 140,
                )
              : EventVideoPlayer(media(MessageTypes.Video)),
        );
        final target = find.byType(gif ? InlineLoopVideo : EventVideoPlayer);
        final at = tester.getCenter(target);
        await _taps(tester, at, [_short, const Duration(milliseconds: 130)]);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(log.likes, 1);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
