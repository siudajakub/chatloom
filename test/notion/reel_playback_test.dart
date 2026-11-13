// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic bridge payloads and a fake native decoder. No real account/network.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/inline_reel_video.dart';
import 'package:chatloom/pages/chat/events/instagram_share_preview.dart';
import 'package:chatloom/pages/chat/events/reel_caption.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/reel_metadata.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Database implements DatabaseApi {
  final files = <Uri, Uint8List>{};
  @override
  int get maxFileSize => 1 << 24;
  @override
  Future<Uint8List?> getFile(Uri uri) async => files[uri];
  @override
  Future<bool> deleteFile(Uri uri) async {
    return files.remove(uri) != null;
  }

  @override
  Future<void> storeFile(Uri uri, Uint8List data, int time) async {
    files[uri] = data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Client extends Client {
  _Client() : super('reel fixture', database: _Database());
  @override
  String get userID => '@owner:example.invalid';
}

class _Platform extends VideoPlayerPlatform {
  int created = 0, disposed = 0;
  final streams = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  final positions = <int, Duration>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created++;
    streams[id] = StreamController<VideoEvent>.broadcast(
      onListen: () => scheduleMicrotask(() {
        streams[id]?.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 60),
            size: const Size(360, 640),
          ),
        );
      }),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed++;
    playing.remove(playerId);
    unawaited(streams.remove(playerId)?.close());
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
  @override
  Future<void> play(int playerId) async {
    playing.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    playing.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

void main() {
  late _Platform platform;
  late VideoPlayerPlatform previous;
  late Room room;
  late List<VideoPlayerController> controllers;
  Event video(String id) => Event(
    type: EventTypes.Message,
    room: room,
    eventId: '\$$id',
    senderId: '@anna:example.invalid',
    originServerTs: DateTime(2026),
    content: {
      'msgtype': MessageTypes.Video,
      'body': 'reel.mp4',
      'info': {'w': 360, 'h': 640},
      'url': 'mxc://example.invalid/$id',
    },
  );
  Widget host(Widget child) {
    RoundPlaybackCoordinator.shared.debugReset();
    return MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    );
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    room = Room(id: '!reels:example.invalid', client: _Client());
    controllers = [];
    RoundPlaybackCoordinator.shared.debugReset();
    InlineReelVideo.debugCreatePlayer = (_) async {
      final player = VideoPlayerController.networkUrl(
        Uri.https('example.invalid', '/fake.mp4'),
      );
      controllers.add(player);
      return player;
    };
  });
  tearDown(() {
    InlineReelVideo.debugCreatePlayer = null;
    InstagramSharePreview.debugRequest = null;
    VideoPlayerPlatform.instance = previous;
  });

  test('native Meta shares use the caption, not their raw URL', () {
    for (final url in [
      'https://www.instagram.com/reel/Fiction/',
      'https://www.facebook.com/reel/123456/',
    ]) {
      final metadata = ReelMetadata.fromContent({
        'external_url': url,
        'com.beeper.meta.caption_body_text': 'Original fictional caption',
      });
      expect(metadata?.caption, 'Original fictional caption');
      expect(metadata?.url.toString(), url);
    }
    expect(
      ReelMetadata.permalink('https://facebook.com.evil.invalid/reel/123/'),
      isNull,
    );
    expect(ReelMetadata.permalink('javascript:alert(1)'), isNull);
  });
  test('metadata never replaces a permalink with another post', () {
    final share = InstagramShare.fromUrl(
      'https://www.instagram.com/reel/Fiction/',
    )!;
    expect(
      () => ReelMetadata.fromInstagramResponse(share, {
        'canonical_url': 'https://www.instagram.com/reel/Other/',
      }),
      throwsFormatException,
    );
    expect(
      ReelMetadata.fromInstagramResponse(
        share,
        {},
        fallbackCaption: 'Cached caption',
      ).caption,
      'Cached caption',
    );
    expect(
      ReelMetadata.fromInstagramResponse(share, {}).linkLabel,
      'Open reel in Instagram',
    );
    expect(
      share.withoutLink(
        'Look https://instagram.com/reel/Fiction/?tracking=x and https://example.invalid/',
      ),
      'Look  and https://example.invalid/',
    );
  });

  testWidgets('caption is the link; expanding description does not open it', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: ReelCaption(
            metadata: ReelMetadata(
              url: Uri.https('www.instagram.com', '/reel/Fiction/'),
              caption: 'Fictional caption ' * 30,
            ),
            onOpen: () => opens++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show description'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('reel-caption-link'))) +
          const Offset(10, 10),
    );
    expect(opens, 1);
  });

  testWidgets(
    'no autoplay; full screen keeps decoder and position; background releases it',
    (tester) async {
      await tester.pumpWidget(host(InlineReelVideo(event: video('native'))));
      await tester.pumpAndSettle();
      expect(platform.created, 0);
      await tester.tap(find.byTooltip('Play reel'));
      await tester.pumpAndSettle();
      expect(platform.created, 1);
      expect(platform.playing.length, 1);
      await controllers.single.seekTo(const Duration(seconds: 12));
      await tester.tap(find.byTooltip('Full screen'));
      await tester.pumpAndSettle();
      expect(platform.created, 1);
      expect(controllers.single.value.position.inSeconds, 12);
      await tester.tap(find.byTooltip('Close video'));
      await tester.pumpAndSettle();
      expect(controllers.single.value.position.inSeconds, 12);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(platform.playing, isEmpty);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(platform.disposed, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(platform.created, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scrolling away releases a reel, starting another one pauses the first',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ListView(
            controller: scroll,
            children: [
              InlineReelVideo(event: video('first')),
              InlineReelVideo(event: video('second')),
              const SizedBox(height: 1200),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play reel').first);
      await tester.pumpAndSettle();
      expect(platform.playing.length, 1);
      final other = RoundPlaybackCoordinator.shared.register(
        pause: () async {},
        stop: () async {},
      );
      await other.acquireAudible();
      await tester.pumpAndSettle();
      expect(platform.playing, isEmpty);
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(platform.playing.length, 1);
      other.dispose();
      scroll.jumpTo(1300);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(platform.playing, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('closing while preparing never starts a stale decoder', (
    tester,
  ) async {
    final pending = Completer<VideoPlayerController>();
    InlineReelVideo.debugCreatePlayer = (_) => pending.future;
    await tester.pumpWidget(host(InlineReelVideo(event: video('pending'))));
    await tester.tap(find.byTooltip('Play reel'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(
      VideoPlayerController.networkUrl(
        Uri.https('example.invalid', '/fake.mp4'),
      ),
    );
    await tester.pumpAndSettle();
    expect(platform.created, 0);
  });

  testWidgets(
    'link resolves through bridge, caption links original, video plays inline',
    (tester) async {
      final requests = <bool>[];
      InstagramSharePreview.debugRequest = (url, download, index) async {
        requests.add(download);
        return download
            ? {
                'mime': 'video/mp4',
                'data': base64Encode([1, 2, 3, 4]),
              }
            : {
                'canonical_url': url,
                'caption': 'A fictional mountain walk',
                'assets': [
                  {'type': 'video', 'width': 360, 'height': 640},
                ],
              };
      };
      InlineReelVideo.debugCreatePlayer = (event) async {
        expect((await event.downloadAndDecryptAttachment()).bytes, [
          1,
          2,
          3,
          4,
        ]);
        final player = VideoPlayerController.networkUrl(
          Uri.https('example.invalid', '/fake.mp4'),
        );
        controllers.add(player);
        return player;
      };
      await tester.pumpWidget(
        host(
          InstagramSharePreview(
            share: InstagramShare.fromUrl(
              'https://www.instagram.com/reel/Fiction/',
            )!,
            event: Event(
              type: EventTypes.Message,
              room: room,
              eventId: r'$link',
              senderId: '@anna:example.invalid',
              originServerTs: DateTime(2026),
              content: {
                'msgtype': MessageTypes.Text,
                'body': 'https://www.instagram.com/reel/Fiction/',
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.text('Play reel'));
      await tester.pumpAndSettle();
      expect(requests, [false, true]);
      expect(find.text('A fictional mountain walk'), findsOneWidget);
      expect(find.byType(InlineReelVideo), findsOneWidget);
      expect(platform.playing.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
