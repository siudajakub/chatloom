// SPDX-License-Identifier: AGPL-3.0-or-later
// Instagram view-once ("raven") media (J, 2026-10-31): "Tap to view" until
// opened on this device, then the ordinary media with a "Not marked as
// opened on Instagram" badge. Fictional offline fixtures: no account, no
// network, nothing sent.
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/view_once_message.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/view_once_openings.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('view-once fixture', database: _NoDatabase());
  @override
  String get userID => '@owner:example.invalid';
}

/// In-memory stand-in for the encrypted private store.
class _Store implements ViewOnceOpeningsStorage {
  Map<String, dynamic>? value;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    this.value = {
      ...value,
      'keys': List<String>.of(value['keys'] as List<String>),
    };
  }
}

/// An event whose attachment downloads are counted, never performed.
class _Event extends Event {
  _Event({required super.room, required super.eventId, required super.content})
    : super(
        type: EventTypes.Message,
        senderId: '@instagram_1:example.invalid',
        originServerTs: DateTime.utc(2026, 10, 31, 12),
      );

  final requests = <bool>[];

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    requests.add(getThumbnail);
    // Not an image: nothing is decoded in the test.
    return MatrixFile(bytes: Uint8List.fromList([1]), name: 'fixture.bin');
  }
}

Map<String, Object?> _content(
  String msgtype, {
  int? viewMode = 0,
  Map<String, Object?> extra = const {},
}) => {
  'msgtype': msgtype,
  'body': msgtype == MessageTypes.Video ? 'raven.mp4' : 'raven.jpg',
  'url': 'mxc://example.invalid/raven',
  'info': {
    'mimetype': msgtype == MessageTypes.Video ? 'video/mp4' : 'image/jpeg',
    'w': 720,
    'h': 1280,
    'size': 1000,
  },
  if (viewMode != null)
    instagramRavenKey: {'version': 1, 'view_mode': viewMode},
  ...extra,
};

Widget _host(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late _Client client;
  late Room room;
  late Timeline timeline;
  var counter = 0;

  setUp(() {
    client = _Client();
    room = Room(id: '!raven:example.invalid', client: client);
    timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: []),
    );
  });

  _Event raven(String msgtype, {int viewMode = 0}) => _Event(
    room: room,
    eventId: '\$raven-${counter++}',
    content: _content(msgtype, viewMode: viewMode),
  );

  Widget message(
    Event event,
    ViewOnceOpenings openings, {
    List<Event>? opened,
  }) => ViewOnceMessage(
    event,
    mode: RoundMediaPolicy.fromContent(event.content).viewOnceMode!,
    timeline: timeline,
    borderRadius: NotionRadius.mdAll,
    textColor: const Color(0xFFFFFFFF),
    linkColor: const Color(0xFFFFFFFF),
    openings: openings,
    onOpen: (context, event, timeline) => opened?.add(event),
  );

  group('ViewOnceOpenings', () {
    test(
      'an opening persists in the private store and survives a reload',
      () async {
        final store = _Store();
        final first = ViewOnceOpenings(storageFor: (_) => store);
        final event = raven(MessageTypes.Image);
        expect(first.isOpened(event), isFalse);
        await Future<void>.delayed(Duration.zero);
        first.markOpened(event);
        expect(first.isOpened(event), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(store.writes, 1);
        expect(store.value!['v'], 1);
        expect(store.value!['keys'], hasLength(1));

        // The app restarts: a new registry reads the same store.
        final second = ViewOnceOpenings(storageFor: (_) => store);
        var notified = 0;
        second.addListener(() => notified++);
        expect(second.isOpened(event), isFalse); // still loading
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(second.isOpened(event), isTrue);
        expect(notified, 1);
        // Another message of the same chat is still sealed.
        expect(second.isOpened(raven(MessageTypes.Image)), isFalse);
      },
    );

    test('opening twice writes once', () async {
      final store = _Store();
      final openings = ViewOnceOpenings(storageFor: (_) => store);
      final event = raven(MessageTypes.Video);
      openings.load(client);
      await Future<void>.delayed(Duration.zero);
      openings
        ..markOpened(event)
        ..markOpened(event);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
    });
  });

  group('ViewOnceMessage', () {
    testWidgets('sealed: a Tap to view card, nothing of the media shown', (
      tester,
    ) async {
      final openings = ViewOnceOpenings(storageFor: (_) => _Store());
      final event = raven(MessageTypes.Image);
      await tester.pumpWidget(_host(message(event, openings)));
      await tester.pump();
      expect(find.byType(NotionViewOnceCard), findsOneWidget);
      expect(find.text('Photo · View once'), findsOneWidget);
      expect(find.text('Tap to view'), findsOneWidget);
      expect(find.bySemanticsLabel('View-once photo. Tap to view'), findsOne);
      // The photo bubble exists only offstage: not painted, hit or read out.
      expect(find.byType(ImageBubble), findsNothing);
      expect(find.byType(ImageBubble, skipOffstage: false), findsOneWidget);
      expect(find.byType(NotionViewOnceBadge), findsNothing);
      expect(
        find.bySemanticsLabel('Not marked as opened on Instagram'),
        findsNothing,
      );
    });

    testWidgets('allow replay video reads "Video · Replay allowed"', (
      tester,
    ) async {
      final openings = ViewOnceOpenings(storageFor: (_) => _Store());
      final event = raven(MessageTypes.Video, viewMode: 1);
      await tester.pumpWidget(_host(message(event, openings)));
      await tester.pump();
      expect(find.text('Video · Replay allowed'), findsOneWidget);
      expect(find.bySemanticsLabel('View-once video. Tap to view'), findsOne);
    });

    testWidgets('sealed media is fetched and cached like an ordinary photo', (
      tester,
    ) async {
      final openings = ViewOnceOpenings(storageFor: (_) => _Store());
      final sealed = raven(MessageTypes.Image);
      await tester.pumpWidget(_host(message(sealed, openings)));
      await tester.pump();
      await tester.pump();
      // The same request an ordinary photo bubble makes for this event.
      final ordinary = _Event(
        room: room,
        eventId: r'$ordinary',
        content: _content(MessageTypes.Image, viewMode: null),
      );
      await tester.pumpWidget(
        _host(
          ImageBubble(
            ordinary,
            width: 360,
            height: 640,
            fit: BoxFit.cover,
            sticker: false,
            timeline: timeline,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(sealed.requests, isNotEmpty, reason: 'raven is prefetched');
      expect(sealed.requests, ordinary.requests);
      // Through the timeline's MxcImage, with the bubble's cache identity.
      await tester.pumpWidget(_host(message(sealed, openings)));
      final image = tester.widget<MxcImage>(
        find.byType(MxcImage, skipOffstage: false),
      );
      expect(image.event, same(sealed));
      expect(image.isThumbnail, isTrue);
      expect(image.cacheKey, sealed.eventId);
      expect(image.cacheName, room.id);
    });

    testWidgets('a tap opens the viewer and leaves the badge', (tester) async {
      final store = _Store();
      final openings = ViewOnceOpenings(storageFor: (_) => store);
      final event = raven(MessageTypes.Image);
      final opened = <Event>[];
      await tester.pumpWidget(_host(message(event, openings, opened: opened)));
      await tester.pump();
      await tester.tap(find.byType(NotionViewOnceCard));
      // A tap waits out the double-tap window of the message.
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();
      expect(opened, [event]);
      expect(openings.isOpened(event), isTrue);
      expect(find.byType(NotionViewOnceCard), findsNothing);
      expect(find.byType(ImageBubble), findsOneWidget);
      expect(find.byType(NotionViewOnceBadge), findsOneWidget);
      expect(
        find.bySemanticsLabel('Not marked as opened on Instagram'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              w.message == 'Not marked as opened on Instagram' &&
              w.triggerMode == TooltipTriggerMode.tap,
        ),
        findsOne,
      );
      expect(store.writes, 1);
    });

    testWidgets('the opened state persists across a reload', (tester) async {
      final store = _Store();
      final event = raven(MessageTypes.Image);
      final before = ViewOnceOpenings(storageFor: (_) => store);
      await tester.pumpWidget(_host(message(event, before, opened: [])));
      await tester.pump();
      await tester.tap(find.byType(NotionViewOnceCard));
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();
      expect(find.byType(NotionViewOnceBadge), findsOneWidget);

      // Restart: a fresh registry over the same private store.
      await tester.pumpWidget(const SizedBox());
      final after = ViewOnceOpenings(storageFor: (_) => store);
      await tester.pumpWidget(_host(message(event, after)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(NotionViewOnceCard), findsNothing);
      expect(find.byType(ImageBubble), findsOneWidget);
      expect(
        find.bySemanticsLabel('Not marked as opened on Instagram'),
        findsOneWidget,
      );
    });

    testWidgets('MessageContent shows raven media as ViewOnceMessage', (
      tester,
    ) async {
      final event = raven(MessageTypes.Image);
      await tester.pumpWidget(
        _host(
          MessageContent(
            event,
            timeline: timeline,
            textColor: const Color(0xFFFFFFFF),
            linkColor: const Color(0xFFFFFFFF),
            borderRadius: NotionRadius.mdAll,
            selected: false,
            bigEmojis: const {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ViewOnceMessage), findsOneWidget);
      expect(MessageContent.rendersRound(event), isFalse);
    });
  });

  group('elsewhere', () {
    test('inbox and notification previews name view-once media', () {
      expect(
        personalPreviewLabel(raven(MessageTypes.Image)),
        '📷 View-once photo',
      );
      expect(
        personalPreviewLabel(raven(MessageTypes.Video, viewMode: 1)),
        '📹 View-once video',
      );
      final ordinary = _Event(
        room: room,
        eventId: r'$plain',
        content: _content(MessageTypes.Image, viewMode: null),
      );
      expect(personalPreviewLabel(ordinary), 'Photo');
    });

    test('save, share and forward stay hidden', () {
      final event = raven(MessageTypes.Image);
      expect(isViewLimited(event), isTrue);
      final policy = RoundMediaPolicy.fromContent(event.content);
      expect(policy.canForward, isFalse);
      expect(policy.canExport, isFalse);
      final ordinary = _Event(
        room: room,
        eventId: r'$plain2',
        content: _content(MessageTypes.Image, viewMode: null),
      );
      expect(isViewLimited(ordinary), isFalse);
    });

    test('raven media never joins a photo album', () {
      Event plain(String id) => _Event(
        room: room,
        eventId: id,
        content: _content(MessageTypes.Image, viewMode: null),
      );
      // Two ordinary photos of one sender make an album...
      expect(
        MediaAlbums.of([plain(r'$a'), plain(r'$b')]),
        everyElement(isNotNull),
      );
      // ...a raven between or next to them never does.
      expect(
        MediaAlbums.of([raven(MessageTypes.Image), plain(r'$c')]),
        everyElement(isNull),
      );
    });
  });
}
