// SPDX-License-Identifier: AGPL-3.0-or-later
// GIF search via Telegram's @gif through the bridge fork (wave 5b, ST-10 D3):
// the provisioning source and the GIF tab. Fake transport and source,
// fictional media only; nothing leaves the test.
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/events/inline_loop_slots.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/stickers/gif_result_tile.dart';
import 'package:chatloom/personal/stickers/gif_search.dart';
import 'package:chatloom/personal/stickers/gif_tab.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

const _telegram = BridgeEndpoint(
  botId: '@sh-telegrambot:beeper.local',
  network: 'telegram',
  label: 'Telegram',
);

/// The smallest JPEG-like bytes; only passed through.
final _preview = [0xFF, 0xD8, 0xFF, 0xD9];

Map<String, Object?> _resultJson(String id) => {
  'id': id,
  'mimetype': 'video/mp4',
  'w': 320,
  'h': 180,
  'duration': 2500,
  'size': 200000,
  'thumb': base64.encode(_preview),
};

Map<String, Object?> _mediaJson(String id, {bool video = true}) => {
  'thumbnail_url': 'mxc://example.invalid/thumb$id',
  'thumbnail_info': {'mimetype': 'image/jpeg', 'w': 320, 'h': 180},
  if (video) 'url': 'mxc://example.invalid/gif$id',
  if (video)
    'info': {
      'mimetype': 'video/mp4',
      'size': 200000,
      'w': 320,
      'h': 180,
      'duration': 2500,
      'thumbnail_url': 'mxc://example.invalid/thumb$id',
      'thumbnail_info': {'mimetype': 'image/jpeg', 'w': 320, 'h': 180},
      'fi.mau.gif': true,
      'fi.mau.loop': true,
      'fi.mau.autoplay': true,
      'fi.mau.hide_controls': true,
      'fi.mau.no_audio': true,
    },
};

class _Transport implements BridgeProvisioningTransport {
  final requests = <BridgeProvisioningRequest>[];
  Future<Object?> Function(BridgeProvisioningRequest request)? answer;

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) {
    requests.add(request);
    return answer!(request);
  }
}

class _SendingRoom extends ConversationRoom {
  _SendingRoom(super.client, super.id, {super.network});
  final sent = <(String, Map<String, Object?>)>[];

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
    sent.add((type, Map<String, Object?>.of(content)));
    return r'$sent';
  }
}

class _Host implements ConversationComposerHost {
  _Host(this.room);

  @override
  final Room room;
  @override
  final FocusNode inputFocus = FocusNode();
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  bool showEmojiPicker = true;
  @override
  Event? replyEvent;

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() => replyEvent = null;
  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {}
  @override
  void emojiPickerBackspace() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A source with scripted answers.
class _FakeSource extends ChangeNotifier implements GifSearchSource {
  GifSearchAvailability current = const GifSearchAvailability.enabled(
    'Search GIFs via Telegram',
  );
  final searches = <(String, String?)>[];
  final mediaRequests = <(String, bool)>[];
  Object? searchError;
  Object? mediaError;
  int prepared = 0;
  int forgotten = 0;
  int pageSize = 3;
  String? next = 'next';

  @override
  GifSearchAvailability availability(Room room) => current;
  @override
  Listenable get changes => this;
  @override
  void prepare(Room room) => prepared++;
  @override
  String get privacyNote => 'Searches go to Telegram’s @gif bot.';
  @override
  void forget(Room room) => forgotten++;

  @override
  Future<GifSearchPage> search(
    Room room,
    String query, {
    String? offset,
  }) async {
    searches.add((query, offset));
    final error = searchError;
    if (error != null) throw error;
    final base = offset == null ? 0 : 100;
    return GifSearchPage([
      for (var i = 0; i < pageSize; i++)
        GifSearchResult.fromJson(_resultJson('${base + i}'))!,
    ], nextOffset: offset == null ? next : null);
  }

  @override
  Future<GifMedia> media(
    Room room,
    GifSearchResult result, {
    bool video = false,
  }) async {
    mediaRequests.add((result.id, video));
    final error = mediaError;
    if (error != null && video) throw error;
    // No thumbnail in widget tests: the blurred inline preview stays.
    if (!video) return const GifMedia();
    return GifMedia.fromJson(_mediaJson(result.id));
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: SizedBox(height: 360, child: child)),
);

void main() {
  group('TelegramGifSearch', () {
    late _Transport transport;
    late ConversationClient client;
    late Room room;
    late BridgeDirectory directory;
    late TelegramGifSearch source;

    setUp(() {
      transport = _Transport();
      client = ConversationClient();
      room = ConversationRoom(client, '!chat:example.invalid');
      directory = BridgeDirectory(BridgeProvisioningApi(transport));
      source = TelegramGifSearch(
        transport: (_, {required media}) => transport,
        bridges: (_) => const [_telegram],
        directory: (_) => directory,
      );
    });

    test(
      'search posts the query (never in the URL) and parses results',
      () async {
        transport.answer = (request) async => {
          'results': [
            _resultJson('1'),
            _resultJson('2'),
            {'id': ''},
            'junk',
          ],
          'next_offset': 'n1',
        };
        final page = await source.search(room, '  Synthetic cats ');
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.path, '/v3/gif/search');
        expect(request.query, isEmpty);
        expect(request.body, {'query': 'Synthetic cats', 'offset': ''});
        expect(page.results.map((r) => r.id), ['1', '2']);
        expect(page.nextOffset, 'n1');
        final first = page.results.first;
        expect(first.preview, _preview);
        expect(first.aspectRatio, closeTo(320 / 180, 1e-9));
        expect(first.durationMs, 2500);

        // The same query (case, spacing) comes from the page cache.
        await source.search(room, 'synthetic   CATS');
        expect(transport.requests, hasLength(1));
        await source.search(room, 'synthetic cats', offset: 'n1');
        expect(transport.requests.last.body, {
          'query': 'synthetic cats',
          'offset': 'n1',
        });
        source.forget(room);
        await source.search(room, 'synthetic cats');
        expect(transport.requests, hasLength(3));
      },
    );

    test('media: thumbnail first, then a sendable m.video GIF', () async {
      transport.answer = (request) async =>
          _mediaJson('7', video: request.body!['video'] == true);
      final result = GifSearchResult.fromJson(_resultJson('7'))!;
      final thumb = await source.media(room, result);
      expect(thumb.thumbnail, Uri.parse('mxc://example.invalid/thumb7'));
      expect(thumb.item, isNull);
      expect(transport.requests.single.path, '/v3/gif/media');
      expect(transport.requests.single.body, {'id': '7', 'video': false});

      final media = await source.media(room, result, video: true);
      final item = media.item!;
      expect(item.kind, StickerKind.gif);
      expect(item.msgtype, MessageTypes.Video);
      expect(item.url, 'mxc://example.invalid/gif7');
      expect(item.info['fi.mau.gif'], isTrue);
      expect(item.info['fi.mau.loop'], isTrue);
      expect(item.info['thumbnail_url'], 'mxc://example.invalid/thumb7');
      expect(item.syncable, isTrue, reason: 'public media can be saved');

      // Cached (and the full answer also serves thumbnail requests).
      await source.media(room, result, video: true);
      await source.media(room, result);
      expect(transport.requests, hasLength(2));
    });

    test(
      'concurrent media requests share one call; failures are retried',
      () async {
        final gate = Completer<Object?>();
        transport.answer = (_) => gate.future;
        final result = GifSearchResult.fromJson(_resultJson('8'))!;
        final a = source.media(room, result, video: true);
        final b = source.media(room, result, video: true);
        expect(transport.requests, hasLength(1));
        gate.completeError(const BridgeProvisioningException(502));
        await expectLater(a, throwsA(isA<GifSearchException>()));
        await expectLater(b, throwsA(isA<GifSearchException>()));
        await Future<void>.delayed(Duration.zero);
        transport.answer = (_) async => _mediaJson('8');
        expect((await source.media(room, result, video: true)).item, isNotNull);
        expect(transport.requests, hasLength(2));
      },
    );

    test('errors become sentences, never codes or bridge text', () async {
      Future<String> messageFor(BridgeProvisioningException e) async {
        transport.answer = (_) async => throw e;
        try {
          source.forget(room);
          await source.search(room, 'synthetic');
        } on GifSearchException catch (error) {
          expect(error.message, isNot(contains('_')));
          expect(error.message, isNot(contains('secret bridge text')));
          return error.message;
        }
        fail('expected an error');
      }

      expect(
        await messageFor(
          const BridgeProvisioningException(
            429,
            errcode: 'M_LIMIT_EXCEEDED',
            message: 'secret bridge text',
          ),
        ),
        'Telegram asked to slow down. Try again in a moment.',
      );
      expect(
        await messageFor(const BridgeProvisioningException(0)),
        contains('didn’t answer'),
      );
      expect(
        await messageFor(
          const BridgeProvisioningException(
            400,
            errcode: 'FI.MAU.NOT_LOGGED_IN',
          ),
        ),
        'Sign in to Telegram to search GIFs.',
      );
      transport.answer = (_) async =>
          throw const BridgeProvisioningException(404, errcode: 'M_NOT_FOUND');
      await expectLater(
        source.media(room, GifSearchResult.fromJson(_resultJson('9'))!),
        throwsA(
          isA<GifSearchException>().having(
            (e) => e.searchAgain,
            'searchAgain',
            true,
          ),
        ),
      );
    });

    test('availability explains why search is off', () async {
      final none = TelegramGifSearch(
        transport: (_, {required media}) => transport,
        bridges: (_) => const [],
        directory: (_) => directory,
      );
      expect(none.availability(room).enabled, isFalse);
      expect(none.availability(room).note, contains('Connect Telegram'));

      final noRoute = TelegramGifSearch(
        transport: (_, {required media}) => null,
        bridges: (_) => const [_telegram],
        directory: (_) => BridgeDirectory.disabled('Not a Beeper account.'),
      );
      expect(noRoute.availability(room).enabled, isFalse);
      expect(noRoute.availability(room).note, contains('Beeper'));

      expect(source.availability(room).enabled, isTrue);
      directory.stateOf(_telegram).status = BridgeRemoteStatus.notLoggedIn;
      expect(
        source.availability(room).note,
        'Sign in to Telegram to search GIFs.',
      );
      directory.stateOf(_telegram).status = BridgeRemoteStatus.ready;

      // An old bridge without the route: off for the session.
      var notified = 0;
      source.changes.addListener(() => notified++);
      transport.answer = (_) async => throw const BridgeProvisioningException(
        404,
        errcode: 'M_UNRECOGNIZED',
      );
      await expectLater(
        source.search(room, 'synthetic'),
        throwsA(isA<GifSearchException>()),
      );
      expect(notified, 1);
      expect(source.availability(room).enabled, isFalse);
      expect(
        source.availability(room).note,
        'Your Telegram bridge can’t search GIFs yet.',
      );
    });

    test('prepare probes the bridge without sending a query', () async {
      transport.answer = (request) async => request.path == '/v3/whoami'
          ? {
              'bridge_bot': _telegram.botId,
              'network': {'displayname': 'Telegram', 'network_id': 'telegram'},
              'logins': <Object?>[],
            }
          : <String, Object?>{};
      source.prepare(room);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        transport.requests.map((r) => r.path),
        isNot(contains('/v3/gif/search')),
      );
      expect(
        source.availability(room).note,
        'Sign in to Telegram to search GIFs.',
      );
    });
  });

  group('GIF tab search', () {
    late _SendingRoom room;
    late _Host host;
    late StickerLibrary library;
    late _FakeSource source;

    setUp(() {
      final client = ConversationClient();
      room = _SendingRoom(client, '!chat:example.invalid', network: 'telegram');
      host = _Host(room);
      library = fakeLibrary(FakeStickerBackend());
      StickerLibrary.debugSet(client, library);
      source = _FakeSource();
      GifResultTile.debugSupportsPlayback = false;
    });
    tearDown(() {
      library.dispose();
      source.dispose();
      host.inputFocus.dispose();
      host.sendController.dispose();
      GifResultTile.debugSupportsPlayback = null;
      InlineLoopSlots.debugReset();
    });

    Widget tab({FocusNode? focus}) => GifTab(
      host: host,
      library: library,
      source: source,
      searchFocus: focus,
    );

    testWidgets('unavailable: the field is off and says why', (tester) async {
      source.current = const GifSearchAvailability.disabled(
        'Search GIFs via Telegram',
        'Sign in to Telegram to search GIFs.',
      );
      await tester.pumpWidget(_app(tab()));
      await tester.pump();
      expect(source.prepared, 1);
      expect(find.text('Sign in to Telegram to search GIFs.'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('gif-search-field')),
      );
      expect(field.enabled, isFalse);
      expect(find.text('No saved GIFs yet'), findsOneWidget);

      // A login appears: the field turns on without a rebuild from outside.
      source
        ..current = const GifSearchAvailability.enabled(
          'Search GIFs via Telegram',
        )
        ..notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('gif-search-field')))
            .enabled,
        isTrue,
      );
    });

    testWidgets('the privacy note shows while the empty field has focus', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_app(tab(focus: focus)));
      expect(find.text(source.privacyNote), findsNothing);
      focus.requestFocus();
      await tester.pump();
      expect(find.text(source.privacyNote), findsOneWidget);
    });

    testWidgets('typing is debounced into one search; results send as GIFs', (
      tester,
    ) async {
      await tester.pumpWidget(_app(tab()));
      final field = find.byKey(const ValueKey('gif-search-field'));
      await tester.enterText(field, 'c');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'ca');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'cat');
      await tester.pump(const Duration(milliseconds: 200));
      expect(source.searches, isEmpty);
      await tester.pump(GifTab.debounce);
      await tester.pump();
      expect(source.searches.first, ('cat', null));
      expect(find.text('Results from Telegram'), findsOneWidget);
      expect(find.byType(GifResultTile), findsWidgets);
      // Visible cells ask for their thumbnail only (no mp4 without a player).
      expect(source.mediaRequests.where((r) => r.$2), isEmpty);
      expect(
        source.mediaRequests.map((r) => r.$1),
        containsAll(['0', '1', '2']),
      );

      // Near the end, the next page loads once (and only once).
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(source.searches, [('cat', null), ('cat', 'next')]);
      expect(find.byType(GifResultTile), findsNWidgets(6));

      await tester.tap(find.byKey(const ValueKey('gif-result-1')));
      await tester.pump();
      await tester.pump();
      final (type, content) = room.sent.single;
      expect(type, EventTypes.Message);
      expect(content['msgtype'], MessageTypes.Video);
      expect(content['url'], 'mxc://example.invalid/gif1');
      final info = content['info'] as Map;
      expect(info['fi.mau.gif'], isTrue, reason: 'Telegram supports GIFs');
      await tester.pump();
      expect(library.recentGifs.single.url, 'mxc://example.invalid/gif1');

      // Clearing the field goes back to the library at once.
      await tester.enterText(field, '');
      await tester.pump();
      expect(find.byType(GifResultTile), findsNothing);
      expect(find.text('Recent'), findsOneWidget);
    });

    testWidgets('errors read as sentences with Try again', (tester) async {
      source.searchError = const GifSearchException(
        'Telegram asked to slow down. Try again in a moment.',
      );
      await tester.pumpWidget(_app(tab()));
      final field = find.byKey(const ValueKey('gif-search-field'));
      await tester.enterText(field, 'cat');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Telegram asked to slow down. Try again in a moment.'),
        findsOneWidget,
      );
      source.searchError = null;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(GifResultTile), findsWidgets);
    });

    testWidgets('an expired result says so and searches again', (tester) async {
      source
        ..mediaError = const GifSearchException(
          'This GIF is no longer available. Search again.',
          searchAgain: true,
        )
        ..next = null;
      await tester.pumpWidget(_app(tab()));
      await tester.enterText(
        find.byKey(const ValueKey('gif-search-field')),
        'cat',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gif-result-0')));
      await tester.pump();
      await tester.pump();
      expect(room.sent, isEmpty);
      expect(
        find.text('This GIF is no longer available. Search again.'),
        findsOneWidget,
      );
      expect(source.forgotten, 1);
      expect(source.searches, hasLength(2));
    });
  });

  test('inline loop slots: the oldest owner gives way', () {
    InlineLoopSlots.debugReset();
    final evicted = <int>[];
    for (var i = 0; i < InlineLoopSlots.max + 2; i++) {
      InlineLoopSlots.acquire(i, () => evicted.add(i));
    }
    expect(InlineLoopSlots.live, InlineLoopSlots.max);
    expect(evicted, [0, 1]);
    InlineLoopSlots.release(4);
    InlineLoopSlots.release(4);
    expect(InlineLoopSlots.live, InlineLoopSlots.max - 1);
    InlineLoopSlots.debugReset();
  });
}
