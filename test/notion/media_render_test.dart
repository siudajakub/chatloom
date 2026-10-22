// SPDX-License-Identifier: AGPL-3.0-or-later
// Timeline media rendering (wave 5 media-render): bridged link previews,
// photo albums and inline GIF / video-sticker loops. Synthetic events only;
// nothing is downloaded, decrypted or sent.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/link_preview.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('media render fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

/// Players that initialise at once and record play/pause.
class _FakePlatform extends VideoPlayerPlatform {
  final players = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  var created = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created++;
    players[id] = StreamController<VideoEvent>.broadcast(
      onListen: () => scheduleMicrotask(
        () => players[id]?.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 2),
            size: const Size(320, 180),
          ),
        ),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => players[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    playing.remove(playerId);
    unawaited(players.remove(playerId)?.close());
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: ValueKey('fake-texture'));

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async => playing.add(playerId);
  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

void main() {
  final client = _Client();
  final room = Room(id: '!media:example.invalid', client: client);
  var clock = 0;

  Event event(
    String id,
    Map<String, Object?> content, {
    String sender = '@anna:example.invalid',
    String type = EventTypes.Message,
    int? seconds,
  }) => Event(
    room: room,
    eventId: id,
    type: type,
    senderId: sender,
    originServerTs: DateTime.utc(2026, 1, 1, 12, 0, seconds ?? clock++),
    content: content,
  );

  Event photo(String id, {int? seconds, String? caption, String? sender}) =>
      event(
        id,
        {
          'msgtype': MessageTypes.Image,
          'body': caption ?? 'photo.jpg',
          if (caption != null) 'filename': 'photo.jpg',
          'url': 'mxc://example.invalid/$id',
          'info': {'w': 400, 'h': 300},
        },
        seconds: seconds,
        sender: sender ?? '@anna:example.invalid',
      );

  Event gif(String id) => event(id, {
    'msgtype': MessageTypes.Video,
    'body': 'gif.mp4',
    'url': 'mxc://example.invalid/$id',
    'info': {
      'mimetype': 'video/mp4',
      'w': 320,
      'h': 180,
      'fi.mau.gif': true,
      'fi.mau.loop': true,
      'fi.mau.autoplay': true,
    },
  });

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('BridgedLinkPreview', () {
    test('parses MSC4095 previews and skips unusable ones', () {
      final previews = BridgedLinkPreview.fromContent({
        'body': 'look https://www.example.org/a',
        BridgedLinkPreview.contentKey: [
          {
            'matched_url': 'https://www.example.org/a',
            'og:title': 'Fictional article',
            'og:description': 'About nothing',
            'og:image': 'mxc://example.invalid/image',
            'og:image:width': '1200',
            'og:image:height': 630,
            'beeper:image:encryption': {'v': 'v2'},
            'matrix:image:blurhash': 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
          },
          {'matched_url': 'javascript:alert(1)', 'og:title': 'No'},
          {'matched_url': 'https://example.org/empty'},
          'not a map',
        ],
      });
      expect(previews, hasLength(1));
      final preview = previews.single;
      expect(preview.title, 'Fictional article');
      expect(preview.site, 'example.org');
      expect(preview.image.toString(), 'mxc://example.invalid/image');
      expect(preview.imageEncryption, isNotNull);
      expect(preview.imageAspectRatio, closeTo(1200 / 630, .001));
      expect(BridgedLinkPreview.fromContent({'body': 'x'}), isEmpty);
    });

    testWidgets('the card shows site, title and description and opens', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: NotionLinkPreviewCard(
                  title: 'Fictional article',
                  description: 'About nothing',
                  site: 'example.org',
                  fill: const Color(0xFF333333),
                  textColor: const Color(0xFFFFFFFF),
                  mutedColor: const Color(0xFFAAAAAA),
                  onTap: () => taps++,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('example.org'), findsOneWidget);
      expect(find.text('Fictional article'), findsOneWidget);
      expect(find.text('About nothing'), findsOneWidget);
      expect(tester.getSize(find.byType(NotionLinkPreviewCard)).width, 260);
      await tester.tap(find.text('Fictional article'));
      expect(taps, 1);
    });
  });

  group('MediaAlbums', () {
    test('groups a burst of one sender, oldest first, lead is newest', () {
      clock = 0;
      final a = photo(r'$a', seconds: 0);
      final b = photo(r'$b', seconds: 2);
      final c = photo(r'$c', seconds: 3, caption: 'Holiday');
      final text = event(r'$t', {'msgtype': 'm.text', 'body': 'Hi'});
      // Newest first, like the reversed timeline.
      final slots = MediaAlbums.of([text, c, b, a]);
      expect(slots[0], isNull);
      expect(slots[1]!.lead, isTrue);
      expect(
        [for (final e in slots[1]!.members) e.eventId],
        [r'$a', r'$b', r'$c'],
      );
      expect(slots[2]!.lead, isFalse);
      expect(slots[3]!.lead, isFalse);
      expect(slots[1]!.olderIndexOffset, 3);
    });

    test('a caption, another sender, a gap or a GIF ends the run', () {
      final captioned = photo(r'$cap', seconds: 0, caption: 'First');
      final plain = photo(r'$plain', seconds: 1);
      // Only the newest member may carry a caption.
      expect(MediaAlbums.of([plain, captioned]), [null, null]);
      final other = photo(
        r'$other',
        seconds: 2,
        sender: '@bob:example.invalid',
      );
      expect(MediaAlbums.of([other, plain]), [null, null]);
      final late = photo(r'$late', seconds: 59);
      expect(MediaAlbums.of([late, plain]), [null, null]);
      expect(MediaAlbums.of([gif(r'$gif'), plain]), [null, null]);
      // A member with reactions stays visible on its own.
      final a = photo(r'$x', seconds: 3);
      final b = photo(r'$y', seconds: 4);
      expect(MediaAlbums.of([b, a], standalone: (e) => e.eventId == r'$x'), [
        null,
        null,
      ]);
    });

    test('albums hold at most ten', () {
      final events = [for (var i = 11; i >= 0; i--) photo('\$p$i', seconds: i)];
      final slots = MediaAlbums.of(events);
      expect(slots.first!.members, hasLength(MediaAlbums.maxItems));
      expect(slots[10]!.lead, isTrue);
      expect(slots[10]!.members, hasLength(2));
    });

    test('grid rows', () {
      expect(MediaAlbums.rows(2), [2]);
      expect(MediaAlbums.rows(3), [3]);
      expect(MediaAlbums.rows(4), [2, 2]);
      expect(MediaAlbums.rows(5), [2, 3]);
      expect(MediaAlbums.rows(7), [1, 3, 3]);
      expect(MediaAlbums.rows(10).fold<int>(0, (a, b) => a + b), 10);
    });
  });

  group('InlineLoopVideo', () {
    late _FakePlatform platform;
    late VideoPlayerPlatform original;

    setUp(() {
      original = VideoPlayerPlatform.instance;
      platform = _FakePlatform();
      VideoPlayerPlatform.instance = platform;
      InlineLoopVideo.debugSupportsPlayback = true;
      InlineLoopVideo.debugCreatePlayer = (event) async =>
          VideoPlayerController.networkUrl(
            Uri.parse('data:video/mp4;base64,AAAA'),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
    });

    tearDown(() {
      VideoPlayerPlatform.instance = original;
      InlineLoopVideo.debugSupportsPlayback = null;
      InlineLoopVideo.debugCreatePlayer = null;
    });

    test('bridged GIF flags and video stickers loop inline', () {
      expect(InlineLoopVideo.applies(gif(r'$g')), isTrue);
      final sticker = event(r'$s', {
        'msgtype': MessageTypes.Video,
        'body': 'sticker',
        'url': 'mxc://example.invalid/s',
        'info': {
          'mimetype': 'video/webm',
          'fi.mau.gif': true,
          'fi.mau.telegram.animated_sticker': {'id': 1},
          'w': 512,
          'h': 256,
        },
      });
      expect(InlineLoopVideo.applies(sticker), isTrue);
      expect(InlineLoopVideo.isVideoSticker(sticker), isTrue);
      expect(InlineLoopVideo.stickerBox(sticker), const Size(128, 64));
      final video = event(r'$v', {
        'msgtype': MessageTypes.Video,
        'body': 'clip.mp4',
        'info': {'mimetype': 'video/mp4'},
      });
      expect(InlineLoopVideo.applies(video), isFalse);
      final round = event(r'$r', {
        'msgtype': MessageTypes.Video,
        'body': 'round.mp4',
        'info': {'fi.mau.telegram.round_message': true, 'fi.mau.gif': true},
      });
      expect(InlineLoopVideo.applies(round), isFalse);
    });

    Widget app(Widget child, {bool reduced = false}) => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: app!,
      ),
      home: Scaffold(body: Center(child: child)),
    );

    testWidgets('plays muted while visible and pauses under TickerMode off', (
      tester,
    ) async {
      final loop = InlineLoopVideo(gif(r'$play'), width: 320, height: 180);
      await tester.pumpWidget(app(TickerMode(enabled: true, child: loop)));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(platform.created, 1);
      expect(platform.playing, isNotEmpty);
      expect(find.byKey(const ValueKey('fake-texture')), findsOneWidget);

      // Hidden tab, offstage route or an unfocused macOS window.
      await tester.pumpWidget(app(TickerMode(enabled: false, child: loop)));
      await tester.pump();
      expect(platform.playing, isEmpty);
      expect(platform.players, hasLength(1));

      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      expect(InlineLoopVideo.debugLivePlayers, 0);
    });

    testWidgets('reduced motion shows the still with a GIF mark', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          InlineLoopVideo(gif(r'$still'), width: 320, height: 180),
          reduced: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(platform.created, 0);
      expect(find.text('GIF'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('at most a few players live at once', (tester) async {
      await tester.pumpWidget(
        app(
          SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  InlineLoopVideo(gif('\$many$i'), width: 80, height: 45),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(
        InlineLoopVideo.debugLivePlayers,
        lessThanOrEqualTo(InlineLoopVideo.maxPlayers),
      );
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
    });
  });
}
