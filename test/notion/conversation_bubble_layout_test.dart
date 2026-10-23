// SPDX-License-Identifier: AGPL-3.0-or-later
// Bubble width: wrapped text shrink-wraps to its longest line, and every
// media kind (photos, videos, Instagram reels from the Meta bridge) uses one
// media width rule.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/html_message.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/instagram_share_preview.dart';
import 'package:chatloom/pages/chat/events/link_preview.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/video_player.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(
  Widget child, {
  double width = 390,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: TextScaler.linear(scale),
      ),
      child: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    ),
  ),
);

Finder _fill(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(ClipRRect));

/// Max fill width of an incoming bubble in [_host] (see ConversationBubble).
double _incomingMax(double width, {bool media = false, double scale = 1}) {
  final large = scale * 17 > 22;
  final fraction = media || large ? .88 : NotionBubble.maxWidthFraction;
  final byFraction = width * fraction;
  final bySlot = width - NotionBubble.avatarSlot;
  return byFraction < bySlot ? byFraction : bySlot;
}

/// The one media width: the media bubble's max width, capped.
double _standardMedia(double width) {
  final max = _incomingMax(width, media: true);
  return max < NotionBubble.mediaMaxWidth ? max : NotionBubble.mediaMaxWidth;
}

void main() {
  late Client client;
  late Room room;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() {
    client = Client('bubble layout', database: _UnusedDatabase());
    room = Room(id: '!room:example.invalid', client: client);
  });

  Widget html(String body, {double fontSize = 16}) => HtmlMessage(
    html: body,
    room: room,
    fontSize: fontSize,
    textColor: Colors.white,
    linkStyle: const TextStyle(color: Colors.lightBlue),
    onOpen: (_) {},
  );

  // Ten glyphs, then a sixteen-glyph word that does not fit after them:
  // two lines, the longer one well short of the bubble's text width.
  const ragged = 'aaaaaaaaaa bbbbbbbbbbbbbbbb';

  testWidgets('a wrapped plain message shrink-wraps to its longest line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ConversationBubble(
          key: Key('plain'),
          outgoing: false,
          body: Text(ragged, style: TextStyle(fontSize: 16)),
        ),
      ),
    );
    final fill = tester.getRect(_fill('plain'));
    final text = tester.getRect(find.text(ragged));
    expect(text.height, greaterThan(16 * 1.5), reason: 'wraps to two lines');
    expect(fill.width, lessThan(_incomingMax(390) - 16));
    expect(
      fill.width,
      closeTo(text.width + NotionBubble.padding.horizontal, 1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final direction in TextDirection.values) {
    testWidgets('a wrapped HTML message shrink-wraps in ${direction.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ConversationBubble(
            key: const Key('html'),
            outgoing: true,
            body: html(ragged),
          ),
          direction: direction,
        ),
      );
      final fill = tester.getRect(_fill('html'));
      final paragraph = tester.getRect(find.byType(RichText).first);
      expect(paragraph.height, greaterThan(16 * 1.5));
      expect(fill.width, lessThan(390 * NotionBubble.maxWidthFraction - 16));
      // Outgoing bubbles keep hugging their side.
      if (direction == TextDirection.ltr) {
        expect(fill.right, 390);
      } else {
        expect(fill.left, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('quotes, lists and code blocks contribute their longest line', (
    tester,
  ) async {
    // Shorter words: quotes and list items indent their text.
    const nested = 'aaaaaaaa bbbbbbbbbbbb';
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            ConversationBubble(
              key: const Key('quote'),
              outgoing: false,
              body: html('<blockquote>$nested</blockquote>'),
            ),
            ConversationBubble(
              key: const Key('list'),
              outgoing: false,
              body: html('<ul><li>$nested</li></ul>'),
            ),
            ConversationBubble(
              key: const Key('code'),
              outgoing: false,
              body: html('<pre><code>short\nlines</code></pre>'),
            ),
          ],
        ),
      ),
    );
    for (final key in ['quote', 'list', 'code']) {
      expect(
        tester.getRect(_fill(key)).width,
        lessThan(_incomingMax(390) - 16),
        reason: key,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single long word still stops at the max width', (
    tester,
  ) async {
    final word = 'x' * 120;
    final url = 'https://example.test/${'segment' * 20}';
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            ConversationBubble(
              key: const Key('word'),
              outgoing: false,
              body: html(word),
            ),
            ConversationBubble(
              key: const Key('url'),
              outgoing: false,
              body: html(url),
            ),
          ],
        ),
      ),
    );
    for (final key in ['word', 'url']) {
      final fill = tester.getRect(_fill(key));
      expect(fill.width, lessThanOrEqualTo(_incomingMax(390) + .01));
      expect(fill.width, greaterThan(_incomingMax(390) - 20));
      expect(fill.right, lessThanOrEqualTo(390));
    }
    expect(tester.takeException(), isNull);
  });

  for (final direction in TextDirection.values) {
    testWidgets(
      'no overflow at 200 percent text and 320dp, ${direction.name}',
      (tester) async {
        await tester.pumpWidget(
          _host(
            Column(
              children: [
                ConversationBubble(
                  key: const Key('mixed'),
                  outgoing: false,
                  heading: const Text('Anna · Instagram'),
                  body: html(
                    '<p>$ragged</p><blockquote>quoted words here</blockquote>'
                    '<pre><code>final x = 1;</code></pre>'
                    '<p>https://example.test/${'long' * 30}</p>',
                  ),
                  footer: const Text('Edited · 16:40'),
                ),
                ConversationBubble(
                  key: const Key('emoji'),
                  outgoing: true,
                  body: html('😀😀😀', fontSize: 16 * 5),
                ),
              ],
            ),
            width: 320,
            scale: 2,
            direction: direction,
          ),
        );
        for (final key in ['mixed', 'emoji']) {
          final fill = tester.getRect(_fill(key));
          expect(fill.left, greaterThanOrEqualTo(0), reason: key);
          expect(fill.right, lessThanOrEqualTo(320), reason: key);
        }
        expect(
          tester.getRect(_fill('mixed')).width,
          lessThanOrEqualTo(_incomingMax(320, scale: 2) + .01),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  group('media width', () {
    Event media(Map<String, Object?> content) => Event(
      content: content,
      type: EventTypes.Message,
      // Not a server id: keeps the transcript slot (and its worker) out.
      eventId: 'local-media',
      senderId: '@sender:example.invalid',
      originServerTs: DateTime.utc(2026),
      room: room,
    );

    Future<void> pumpMedia(
      WidgetTester tester,
      Event event, {
      double width = 390,
      bool compact = false,
    }) async {
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(timeline.cancelSubscriptions);
      await tester.pumpWidget(
        _host(
          ConversationBubble(
            key: const Key('media'),
            compactMedia: compact,
            outgoing: false,
            media: true,
            body: MessageContent(
              event,
              timeline: timeline,
              textColor: Colors.white,
              linkColor: Colors.lightBlue,
              borderRadius: NotionRadius.mdAll,
              selected: false,
              bigEmojis: const {},
            ),
          ),
          width: width,
        ),
      );
    }

    // A reel shared from Instagram through mautrix-meta: an m.video whose
    // body is the reel link (the caption) and whose file name is the clip.
    Map<String, Object?> reel({int? w = 1080, int? h = 1920}) => {
      'msgtype': MessageTypes.Video,
      'body': 'https://www.instagram.com/reel/Cexample/',
      'filename': 'reel.mp4',
      'external_url': 'https://www.instagram.com/reel/Cexample/',
      'url': 'mxc://example.invalid/reel',
      'info': {'mimetype': 'video/mp4', 'w': ?w, 'h': ?h},
    };

    testWidgets(
      'text shares keep their caption and respect disabled thumbnails',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final old = AppSettings.showThumbnailsInTimeline.value;
        await AppSettings.showThumbnailsInTimeline.setItem(false);
        addTearDown(() => AppSettings.showThumbnailsInTimeline.setItem(old));
        await pumpMedia(
          tester,
          media({
            'msgtype': MessageTypes.Text,
            'body':
                'Watch this https://instagram.com/reel/Cexample/?igsh=tracking',
          }),
          compact: true,
        );
        expect(find.byType(InstagramSharePreview), findsOneWidget);
        expect(find.text('Open in Instagram'), findsOneWidget);
        expect(
          tester.widget<HtmlMessage>(find.byType(HtmlMessage)).html,
          contains('Watch this'),
        );
        expect(tester.takeException(), isNull);
        await pumpMedia(
          tester,
          media({
            'msgtype': MessageTypes.Text,
            'body': '> https://instagram.com/reel/Cexample/\n\nJust a reply',
          }),
        );
        expect(find.byType(InstagramSharePreview), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'preserves ordinary bridged previews and avoids duplicate Instagram cards',
      (tester) async {
        Map<String, Object?> linked(String url) => {
          'msgtype': MessageTypes.Text,
          'body': 'Look $url',
          BridgedLinkPreview.contentKey: [
            {'matched_url': url, 'og:title': 'Fictional shared article'},
          ],
        };
        await pumpMedia(
          tester,
          media(linked('https://example.invalid/article')),
        );
        expect(find.byType(LinkPreviewAttachment), findsOneWidget);
        expect(find.byType(InstagramSharePreview), findsNothing);
        expect(tester.takeException(), isNull);

        await pumpMedia(
          tester,
          media(linked('https://instagram.com/reel/Example/')),
          compact: true,
        );
        expect(find.byType(InstagramSharePreview), findsOneWidget);
        expect(find.byType(LinkPreviewAttachment), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('compact bridged reel keeps its caption and frame', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 620);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fonts = FontLoader('Roboto');
      for (final name in ['Regular', 'Medium', 'Bold']) {
        fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
      }
      await fonts.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      await pumpMedia(tester, media(reel()), compact: true);
      expect(
        tester.getSize(find.byType(EventVideoPlayer)).width,
        closeTo(_standardMedia(390) * 2 / 3, .01),
      );
      expect(find.byType(HtmlMessage), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/instagram-share-compact.png'),
      );
    });

    testWidgets('a reel fills the standard media width, cropped to 3:4', (
      tester,
    ) async {
      await pumpMedia(tester, media(reel()));
      final standard = _standardMedia(390);
      final frame = tester.getSize(
        find
            .descendant(
              of: find.byType(EventVideoPlayer),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(frame.width, closeTo(standard, .01));
      expect(
        frame.height,
        closeTo(standard * NotionBubble.mediaMaxAspect, .01),
      );
      // The bubble is the frame's width: the caption sits inside it.
      expect(tester.getRect(_fill('media')).width, closeTo(standard, .01));
      expect(
        find.textContaining('instagram.com/reel', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('videos and photos share that width', (tester) async {
      final standard = _standardMedia(390);
      await pumpMedia(tester, media(reel(w: 1920, h: 1080)));
      expect(tester.getRect(_fill('media')).width, closeTo(standard, .01));
      await pumpMedia(tester, media(reel(w: null, h: null)));
      expect(tester.getRect(_fill('media')).width, closeTo(standard, .01));
      await pumpMedia(
        tester,
        media({
          'msgtype': MessageTypes.Image,
          'body': 'photo.jpg',
          'url': 'mxc://example.invalid/photo',
          'info': {'mimetype': 'image/jpeg', 'w': 4000, 'h': 3000},
        }),
      );
      expect(find.byType(ImageBubble), findsOneWidget);
      final fill = tester.getRect(_fill('media'));
      expect(fill.width, closeTo(standard, .01));
      expect(fill.height, closeTo(standard * .75, .01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide screens cap media at the media max width', (
      tester,
    ) async {
      await pumpMedia(tester, media(reel()), width: 900);
      expect(
        tester.getRect(_fill('media')).width,
        closeTo(NotionBubble.mediaMaxWidth, .01),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('HTML bodies are parsed once per content, not per rebuild', (
    tester,
  ) async {
    InlineSpan span() {
      final root = tester.widget<RichText>(find.byType(RichText).first).text;
      return (root as TextSpan).children!.single;
    }

    var opened = 0;
    Widget build(String body, {Color color = Colors.white}) => _host(
      HtmlMessage(
        html: body,
        room: room,
        fontSize: 16,
        textColor: color,
        linkStyle: const TextStyle(color: Colors.lightBlue),
        // A new closure and a new reaction set on every row rebuild.
        onOpen: (_) => opened++,
        checkboxCheckedEvents: <Event>{},
      ),
    );

    await tester.pumpWidget(build('<b>bold</b> <code>x</code>'));
    final first = span();
    await tester.pumpWidget(build('<b>bold</b> <code>x</code>'));
    expect(identical(span(), first), isTrue);
    await tester.pumpWidget(build('<b>bold</b> <code>y</code>'));
    final second = span();
    expect(identical(second, first), isFalse);
    await tester.pumpWidget(
      build('<b>bold</b> <code>y</code>', color: Colors.grey),
    );
    expect(identical(span(), second), isFalse);
    expect(opened, 0);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 720.0]) {
    for (final outgoing in [false, true]) {
      testWidgets(
        'Instagram share uses two thirds at $width, outgoing=$outgoing',
        (tester) async {
          await tester.pumpWidget(
            _host(
              ConversationBubble(
                key: const Key('compact-share'),
                outgoing: outgoing,
                media: true,
                compactMedia: true,
                body: const SizedBox(width: 360, height: 240),
              ),
              width: width,
            ),
          );
          final standard = (width * .88).clamp(0, NotionBubble.mediaMaxWidth);
          expect(
            tester.getSize(_fill('compact-share')).width,
            closeTo(standard * 2 / 3, .01),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test('frame rule clamps aspect and height', () {
    expect(
      ConversationMedia.frame(maxWidth: 300, width: 1080, height: 1920),
      const Size(300, 400),
    );
    expect(
      ConversationMedia.frame(maxWidth: 300, width: 3000, height: 500),
      const Size(300, 120),
    );
    expect(ConversationMedia.frame(maxWidth: 300), const Size(300, 300));
    expect(
      ConversationMedia.frame(maxWidth: 1000, width: 1, height: 1),
      const Size(NotionBubble.mediaMaxWidth, NotionBubble.mediaMaxWidth),
    );
    expect(
      ConversationMedia.frame(
        maxWidth: 300,
        width: 9,
        height: 16,
        maxHeight: 200,
      ),
      const Size(300, 200),
    );
  });
}
