// SPDX-License-Identifier: AGPL-3.0-or-later
// A sticker in the timeline never takes more than about half the screen:
// m.sticker with huge or missing dimensions (a local echo before the send
// completes), stickers sent or bridged as m.image / m.video, desktop windows.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/sticker_event.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _phone = Size(412, 915);

void main() {
  late Client client;
  late Room room;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    // The placeholder has the exact frame; nothing is downloaded.
    await AppSettings.showThumbnailsInTimeline.setItem(false);
  });

  setUp(() {
    client = Client('sticker size', database: _UnusedDatabase());
    room = Room(id: '!room:example.invalid', client: client);
  });

  Event event(
    Map<String, Object?> content, {
    String type = EventTypes.Message,
    EventStatus status = EventStatus.synced,
    String sender = '@sender:example.invalid',
  }) => Event(
    content: content,
    type: type,
    eventId: r'$sticker',
    senderId: sender,
    originServerTs: DateTime.utc(2026),
    status: status,
    room: room,
  );

  Map<String, Object?> sticker({num? w, num? h, String mime = 'image/webp'}) =>
      {
        'body': '😀',
        'url': 'mxc://example.invalid/sticker',
        'info': {'mimetype': mime, 'w': ?w, 'h': ?h},
      };

  /// Lays [e] out as the timeline does on a [screen]-sized window and
  /// returns the rendered sticker (image) frame.
  Future<Size> pumpSticker(
    WidgetTester tester,
    Event e, {
    Size screen = _phone,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = screen;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [e]),
    );
    addTearDown(timeline.cancelSubscriptions);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: screen),
          child: Align(
            alignment: Alignment.topLeft,
            child: MessageContent(
              e,
              timeline: timeline,
              textColor: Colors.white,
              linkColor: Colors.blue,
              borderRadius: BorderRadius.zero,
              selected: false,
              bigEmojis: const {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ImageBubble), findsOneWidget);
    return tester.getSize(find.byType(ImageBubble));
  }

  double side(Size screen) => ConversationMedia.stickerSideFor(
    screen,
    desktop: PlatformInfos.isDesktop,
  );

  void expectHalfScreen(Size frame, Size screen) {
    expect(frame.width, lessThanOrEqualTo(screen.width / 2 + .01));
    expect(frame.height, lessThanOrEqualTo(screen.height / 2 + .01));
    expect(frame.longestSide, lessThanOrEqualTo(256));
  }

  testWidgets('a huge m.sticker (2048 px) is capped at the sticker side', (
    tester,
  ) async {
    final frame = await pumpSticker(
      tester,
      event(sticker(w: 2048, h: 2048), type: EventTypes.Sticker),
    );
    expect(frame, Size.square(side(_phone)));
    expectHalfScreen(frame, _phone);
  });

  testWidgets('an own sticker without info (local echo while sending)', (
    tester,
  ) async {
    final frame = await pumpSticker(
      tester,
      event(
        {'body': '😀', 'url': 'mxc://example.invalid/sticker'},
        type: EventTypes.Sticker,
        status: EventStatus.sending,
        sender: '@me:example.invalid',
      ),
    );
    expect(frame, Size.square(side(_phone)));
    expectHalfScreen(frame, _phone);
  });

  testWidgets('a tall sticker keeps its aspect within the cap', (tester) async {
    final frame = await pumpSticker(
      tester,
      event(sticker(w: 300, h: 1200), type: EventTypes.Sticker),
    );
    expect(frame.height, side(_phone));
    expect(frame.width, closeTo(side(_phone) / 4, .01));
    expectHalfScreen(frame, _phone);
  });

  testWidgets('a desktop-wide window keeps stickers small', (tester) async {
    const desktop = Size(1440, 900);
    final frame = await pumpSticker(
      tester,
      event(sticker(w: 512, h: 512), type: EventTypes.Sticker),
      screen: desktop,
    );
    expect(frame.longestSide, ConversationMedia.stickerWideSide);
    expectHalfScreen(frame, desktop);
  });

  testWidgets('a short window: never more than half its height', (
    tester,
  ) async {
    const short = Size(800, 220);
    final frame = await pumpSticker(
      tester,
      event(sticker(w: 512, h: 512), type: EventTypes.Sticker),
      screen: short,
    );
    expect(frame, const Size.square(110));
    expectHalfScreen(frame, short);
  });

  testWidgets('a small sticker is not blown up', (tester) async {
    final frame = await pumpSticker(
      tester,
      event(sticker(w: 64, h: 64), type: EventTypes.Sticker),
    );
    expect(frame, const Size.square(ConversationMedia.stickerMinSide));
  });

  testWidgets('a sticker ChatLoom sent as m.image (Messenger) is a sticker', (
    tester,
  ) async {
    final e = event({
      'msgtype': MessageTypes.Image,
      'body': 'sticker.webp',
      'url': 'mxc://example.invalid/sticker',
      'info': {
        'mimetype': 'image/webp',
        'w': 512,
        'h': 512,
        StickerEvents.marker: true,
      },
    });
    final frame = await pumpSticker(tester, e);
    expect(frame, Size.square(side(_phone)));
    expectHalfScreen(frame, _phone);
    expect(MessageContent.rendersSticker(e), isTrue);
    expect(
      tester.widget<ImageBubble>(find.byType(ImageBubble)).fit,
      BoxFit.contain,
    );
  });

  testWidgets('older image stickers (body sticker.webp, no flag) too', (
    tester,
  ) async {
    final e = event({
      'msgtype': MessageTypes.Image,
      'body': 'sticker.webp',
      'url': 'mxc://example.invalid/sticker',
      'info': {'mimetype': 'image/webp', 'w': 512, 'h': 512},
    });
    final frame = await pumpSticker(tester, e);
    expect(frame, Size.square(side(_phone)));
    expect(MessageContent.rendersSticker(e), isTrue);
  });

  testWidgets('a bridged image tagged as a sticker is a sticker', (
    tester,
  ) async {
    final e = event({
      'msgtype': MessageTypes.Image,
      'body': 'image.webp',
      'url': 'mxc://example.invalid/sticker',
      'info': {
        'mimetype': 'image/webp',
        'w': 1024,
        'h': 1024,
        'fi.mau.bridged_sticker': {'network': 'whatsapp'},
      },
    });
    final frame = await pumpSticker(tester, e);
    expect(frame, Size.square(side(_phone)));
  });

  testWidgets('ordinary photos keep the media width', (tester) async {
    final e = event({
      'msgtype': MessageTypes.Image,
      'body': 'photo.jpg',
      'url': 'mxc://example.invalid/photo',
      'info': {'mimetype': 'image/jpeg', 'w': 4000, 'h': 3000},
    });
    final frame = await pumpSticker(tester, e);
    expect(frame.width, NotionBubble.mediaMaxWidth);
    expect(MessageContent.rendersSticker(e), isFalse);
    expect(StickerEvents.isImageSticker(e), isFalse);
  });

  test('a sticker sent as m.image never joins a photo album', () {
    final e = event({
      'msgtype': MessageTypes.Image,
      'body': 'sticker.webp',
      'url': 'mxc://example.invalid/sticker',
      'info': {StickerEvents.marker: true},
    });
    final photo = Event(
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'photo.jpg',
        'url': 'mxc://example.invalid/photo',
      },
      type: EventTypes.Message,
      eventId: r'$photo',
      senderId: '@sender:example.invalid',
      originServerTs: DateTime.utc(2026),
      room: room,
    );
    // Without the rule these two would be a two-item album.
    expect(MediaAlbums.of([e, photo]), [null, null]);
  });

  testWidgets('a sticker sent as a plain m.video loops at sticker size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _phone;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final e = event({
      'msgtype': MessageTypes.Video,
      'body': 'sticker.webm',
      'url': 'mxc://example.invalid/sticker',
      'info': {
        'mimetype': 'video/webm',
        'w': 1080,
        'h': 1920,
        StickerEvents.marker: true,
      },
    });
    expect(InlineLoopVideo.isVideoSticker(e), isTrue);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [e]),
    );
    addTearDown(timeline.cancelSubscriptions);
    late Widget rendered;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: _phone),
          child: Builder(
            builder: (context) {
              rendered = MessageContent(
                e,
                timeline: timeline,
                textColor: Colors.white,
                linkColor: Colors.blue,
                borderRadius: BorderRadius.zero,
                selected: false,
                bigEmojis: const {},
              ).build(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final builder = rendered as LayoutBuilder;
    late Widget loop;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: _phone),
          child: Builder(
            builder: (context) {
              loop = builder.builder(context, const BoxConstraints());
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final video = loop as InlineLoopVideo;
    expect(video.height, side(_phone));
    expect(video.width, closeTo(side(_phone) * 1080 / 1920, .01));
  });
}
