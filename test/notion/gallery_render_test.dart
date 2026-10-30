// SPDX-License-Identifier: AGPL-3.0-or-later
// MSC4274 gallery messages in the timeline: an album grid that pages
// through the gallery's own items, file rows, and a line for what cannot be
// shown. Thumbnails are off, so nothing is downloaded or decrypted.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/gallery_message.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/message_download_content.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('gallery render fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

/// Records forwarded sends; the send number [failAt] fails once.
class _ForwardRoom extends Room {
  _ForwardRoom(Client client)
    : super(
        id: '!forward:example.invalid',
        client: client,
        membership: Membership.join,
      );

  final sent = <({String? txid, Map<String, dynamic> content})>[];
  int? failAt;

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    sent.add((txid: txid, content: content));
    if (sent.length == failAt) return null;
    return '\$forwarded-${sent.length}';
  }
}

Map<String, Object?> _item(String type, String id) => {
  'itemtype': type,
  'body': id,
  'url': 'mxc://example.invalid/$id',
  'info': {'w': 400, 'h': 300, 'size': 1000},
};

void main() {
  final client = _Client();
  final room = Room(id: '!gallery-render:example.invalid', client: client);

  Event gallery(String id, List<Object?> items, {String body = ''}) => Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: DateTime.utc(2026, 1, 1, 12),
    content: {
      'msgtype': 'dm.filament.gallery',
      'body': body,
      'itemtypes': items,
    },
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      AppSettings.showThumbnailsInTimeline.key: false,
    });
    await AppSettings.init(loadWebConfigFile: false);
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  GalleryMessage message(Event event) => GalleryMessage(
    event,
    gallery: GalleryContent.of(event)!,
    borderRadius: const BorderRadius.all(Radius.circular(18)),
    textColor: const Color(0xFFFFFFFF),
    linkColor: const Color(0xFF88AAFF),
  );

  testWidgets('photos and videos form one grid that pages the gallery', (
    tester,
  ) async {
    final event = gallery(r'$three', [
      _item(MessageTypes.Image, 'a'),
      _item(MessageTypes.Video, 'b'),
      _item(MessageTypes.Image, 'c'),
    ]);
    await pump(tester, message(event));
    final grid = tester.widget<MediaAlbumGrid>(find.byType(MediaAlbumGrid));
    expect(
      [for (final e in grid.events) e.eventId],
      [r'$three/gallery/0', r'$three/gallery/1', r'$three/gallery/2'],
    );
    // The viewer pages through the gallery, not the chat's media.
    expect(grid.viewerEvents, same(grid.events));
    expect(find.byType(BlurHash), findsNWidgets(3));
    expect(find.bySemanticsLabel('Album, 3 items'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(MessageDownloadContent), findsNothing);
  });

  testWidgets('more than ten items show ten tiles and count the rest', (
    tester,
  ) async {
    final event = gallery(r'$many', [
      for (var i = 0; i < 12; i++) _item(MessageTypes.Image, 'p$i'),
    ]);
    await pump(tester, message(event));
    expect(find.byType(BlurHash), findsNWidgets(MediaAlbums.maxItems));
    expect(find.text('+2'), findsOneWidget);
    final grid = tester.widget<MediaAlbumGrid>(find.byType(MediaAlbumGrid));
    expect(grid.viewerEvents, hasLength(12));
  });

  testWidgets('files are rows and unknown entries are named, not dropped', (
    tester,
  ) async {
    final event = gallery(r'$mixed', [
      _item(MessageTypes.Image, 'a'),
      _item(MessageTypes.File, 'report.pdf'),
      {'itemtype': 'm.location', 'body': 'Here'},
    ]);
    await pump(tester, message(event));
    expect(find.byType(BlurHash), findsOneWidget);
    expect(find.byType(MessageDownloadContent), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('1 item of this album cannot be shown.'), findsOneWidget);
  });

  testWidgets('a gallery without an item list says so', (tester) async {
    final event = Event(
      room: room,
      eventId: r'$broken',
      type: EventTypes.Message,
      senderId: '@anna:example.invalid',
      originServerTs: DateTime.utc(2026),
      content: {'msgtype': 'dm.filament.gallery', 'body': 'Caption only'},
    );
    await pump(tester, message(event));
    expect(find.byType(MediaAlbumGrid), findsNothing);
    expect(find.text('This album could not be shown.'), findsOneWidget);
  });

  testWidgets('the timeline draws a gallery with its caption below', (
    tester,
  ) async {
    final event = gallery(r'$timeline', [
      _item(MessageTypes.Image, 'a'),
      _item(MessageTypes.Image, 'b'),
    ], body: 'Holiday');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    addTearDown(timeline.cancelSubscriptions);
    await pump(
      tester,
      MessageContent(
        event,
        timeline: timeline,
        textColor: const Color(0xFFFFFFFF),
        linkColor: const Color(0xFF88AAFF),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        selected: false,
        bigEmojis: const {},
      ),
    );
    expect(find.byType(GalleryMessage), findsOneWidget);
    expect(find.byType(BlurHash), findsNWidgets(2));
    expect(find.text('Holiday'), findsOneWidget);
  });

  testWidgets('a forwarded gallery goes out item by item, never twice', (
    tester,
  ) async {
    final target = _ForwardRoom(client)..failAt = 2;
    final items = [
      for (final content in GalleryContent.forwardContents({
        'msgtype': 'dm.filament.gallery',
        'body': 'Holiday',
        'itemtypes': [
          _item(MessageTypes.Image, 'a'),
          _item(MessageTypes.Image, 'b'),
          _item(MessageTypes.Video, 'c'),
        ],
      }))
        ContentShareItem(content),
    ];
    await pump(tester, const SizedBox(key: ValueKey('host')));
    final context = tester.element(find.byKey(const ValueKey('host')));
    // The second item fails: the first is already in the chat.
    expect(await debugSendForwardItems(context, target, items), isNotNull);
    // Try again: the first two reuse their transactions (the server keeps
    // one message per transaction), then the third goes out.
    expect(await debugSendForwardItems(context, target, items), isNull);
    final txids = [for (final send in target.sent) send.txid];
    expect(txids, hasLength(5));
    expect(txids[2], txids[0]);
    expect(txids[3], txids[1]);
    expect(txids.toSet(), hasLength(3));
    expect(
      [for (final send in target.sent.skip(2)) send.content['body']],
      ['a', 'b', 'Holiday'],
    );
  });
}
