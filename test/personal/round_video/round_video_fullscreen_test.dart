// SPDX-License-Identifier: AGPL-3.0-or-later
// Enlarged ("fullscreen") round playback against a fake platform that behaves
// like video_player_android: building a VideoPlayer for a disposed player
// throws, which a release build renders as a grey ErrorWidget.
import 'dart:async';

import 'package:chatloom/pages/chat/events/round_mini_player.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/chat/events/round_video_stage.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

/// Mirrors video_player_android 2.12: `dispose` forgets the player first and
/// `buildViewWithOptions` throws for a player it does not know.
class _AndroidLikePlatform extends VideoPlayerPlatform {
  final players = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  var _next = 0;
  bool hangInitialize = false;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    players[id] = StreamController<VideoEvent>.broadcast(
      onListen: () {
        if (hangInitialize) return;
        scheduleMicrotask(() => initialized(id));
      },
    );
    positions[id] = Duration.zero;
    return id;
  }

  void initialized(int id) => players[id]?.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(240, 240),
    ),
  );

  void fail(int id) => players[id]?.addError(
    PlatformException(code: 'VideoError', message: 'decoder failed'),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => players[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    final events = players.remove(playerId);
    unawaited(events?.close());
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    if (!players.containsKey(options.playerId)) {
      throw StateError('No active player with ID ${options.playerId}.');
    }
    return const SizedBox.expand(key: ValueKey('fake-texture'));
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      positions[playerId] = position;
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

/// Like [RoundMediaLoader]: the source is re-validated after the download.
class _Loader extends RoundMediaLoader {
  Completer<void>? gate;
  @override
  Future<RoundLoadedMedia> load(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) async {
    await gate?.future;
    if (cancellation?.valid == false) {
      throw const RoundMediaUnavailable('cancelled');
    }
    return RoundLoadedMedia.web(Uri.parse('data:video/mp4;base64,AAAA'));
  }
}

final _client = Client('fullscreen fixture', database: _UnusedDatabase());

/// A new instance per call, like a rebuilt display event of one message.
Event _event({String id = r'$fullscreen-round'}) => Event(
  room: Room(id: '!fullscreen:example.invalid', client: _client),
  eventId: id,
  senderId: '@fixture:example.invalid',
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': 'm.video',
    'body': 'fixture.mp4',
    'info': {'fi.mau.telegram.round_message': true, 'duration': 10000},
  },
);

void main() {
  late _AndroidLikePlatform platform;
  late VideoPlayerPlatform original;

  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _AndroidLikePlatform();
    VideoPlayerPlatform.instance = platform;
    RoundVideoMessage.debugCreatePlayer = (media, {required muted}) =>
        VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/round.mp4'),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: muted),
        );
  });
  tearDown(() {
    RoundVideoMessage.debugCreatePlayer = null;
    VideoPlayerPlatform.instance = original;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Ends with no stage or mini session left behind.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(RoundMiniPlayerController.shared.stop());
    await settle(tester);
    expect(RoundStageController.shared.isOpen, isFalse);
    expect(tester.takeException(), isNull);
  }

  Widget host({
    required Event Function() event,
    required RoundMediaLoader loader,
    required RoundPlaybackCoordinator coordinator,
    bool show = true,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: show
            ? RoundVideoMessage(
                event(),
                loader: loader,
                coordinator: coordinator,
                showThumbnail: false,
              )
            : const SizedBox.shrink(),
      ),
    ),
  );

  testWidgets(
    'a fresh Event instance for the same source does not cancel the load',
    (tester) async {
      // An edited round's display event is rebuilt on every timeline build;
      // the SDK also swaps instances on sync/decryption updates.
      final loader = _Loader()..gate = Completer<void>();
      final coordinator = RoundPlaybackCoordinator();
      await tester.pumpWidget(
        host(event: _event, loader: loader, coordinator: coordinator),
      );
      await tester.tap(find.byTooltip('Play round video'));
      await tester.pump();
      expect(find.byTooltip('Cancel download'), findsOneWidget);
      // Timeline rebuild while downloading: same message, new instance.
      await tester.pumpWidget(
        host(event: _event, loader: loader, coordinator: coordinator),
      );
      loader.gate!.complete();
      await settle(tester);
      expect(find.text('Playback failed. Try again.'), findsNothing);
      expect(find.byType(RoundVideoStage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardownTree(tester);
    },
  );

  testWidgets('a throwing source rect never replaces the stage with an '
      'ErrorWidget', (tester) async {
    final stage = RoundStageController();
    final video = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/round.mp4'),
    );
    addTearDown(video.dispose);
    video.value = const VideoPlayerValue(
      duration: Duration(seconds: 10),
      size: Size(240, 240),
      isInitialized: true,
      isPlaying: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => stage.present(
                context,
                video: video,
                actions: RoundStageActions(
                  toggle: () async {},
                  seek: (_) async {},
                  setSpeed: (_) async {},
                  stop: () async {},
                  // A row mid-relayout can throw from localToGlobal.
                  sourceRect: () => throw StateError('row not laid out'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.bySemanticsLabel('Round video, enlarged'), findsOneWidget);
    stage.release(video);
    await tester.pumpAndSettle();
  });

  testWidgets('the stage shows a poster and spinner, then an error state, '
      'and never embeds a player that is not ready', (tester) async {
    final stage = RoundStageController();
    final video = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/round.mp4'),
    );
    addTearDown(video.dispose);
    // 1×1 transparent PNG.
    final poster = Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => stage.present(
                context,
                video: video,
                actions: RoundStageActions(
                  toggle: () async {},
                  seek: (_) async {},
                  setSpeed: (_) async {},
                  stop: () async {},
                  thumbnail: () => poster,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final circle = find.bySemanticsLabel('Round video, enlarged');
    expect(find.byKey(const ValueKey('round-stage-loading')), findsOneWidget);
    expect(
      find.descendant(of: circle, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(find.byType(VideoPlayer), findsNothing);

    video.value = const VideoPlayerValue.erroneous('decoder failed');
    await tester.pump();
    expect(find.byKey(const ValueKey('round-stage-error')), findsOneWidget);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);

    // Tapping a failed round shrinks back to the row (retry lives there).
    await tester.tap(circle);
    await tester.pumpAndSettle();
    expect(stage.isOpen, isFalse);
  });

  testWidgets('playing again during the shrink flight enlarges again', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/round.mp4'),
    );
    addTearDown(video.dispose);
    video.value = const VideoPlayerValue(
      duration: Duration(seconds: 10),
      size: Size(240, 240),
      isInitialized: true,
      isPlaying: true,
    );
    late BuildContext anchor;
    RoundStageActions actions() => RoundStageActions(
      toggle: () async {},
      seek: (_) async {},
      setSpeed: (_) async {},
      stop: () async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              anchor = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    stage.present(anchor, video: video, actions: actions());
    await tester.pumpAndSettle();
    stage.shrink();
    await tester.pump(const Duration(milliseconds: 60));
    stage.present(anchor, video: video, actions: actions());
    await tester.pumpAndSettle();
    expect(stage.isStaged(video), isTrue);
    expect(find.byType(RoundVideoStage), findsOneWidget);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(tester.takeException(), isNull);
    stage.release(video);
    await tester.pumpAndSettle();
  });

  testWidgets('a platform error while enlarged closes the stage and offers '
      'retry on the row', (tester) async {
    await tester.pumpWidget(
      host(
        event: _event,
        loader: _Loader(),
        coordinator: RoundPlaybackCoordinator(),
      ),
    );
    await tester.tap(find.byTooltip('Play round video'));
    await settle(tester);
    expect(find.byType(RoundVideoStage), findsOneWidget);
    platform.fail(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(RoundStageController.shared.isOpen, isFalse);
    expect(find.byTooltip('Retry playback'), findsOneWidget);
    expect(find.text('Playback was interrupted. Try again.'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a codec that never initializes ends in an error with retry', (
    tester,
  ) async {
    platform.hangInitialize = true;
    await tester.pumpWidget(
      host(
        event: _event,
        loader: _Loader(),
        coordinator: RoundPlaybackCoordinator(),
      ),
    );
    await tester.tap(find.byTooltip('Play round video'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byTooltip('Cancel download'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byTooltip('Cancel download'), findsNothing);
    expect(find.byTooltip('Retry playback'), findsOneWidget);
    expect(find.text('Playback failed. Try again.'), findsOneWidget);
    expect(RoundStageController.shared.isOpen, isFalse);
    await teardownTree(tester);
  });

  for (final playing in [true, false]) {
    testWidgets(
      'row unmounted and remounted while enlarged (playing: $playing)',
      (tester) async {
        final loader = _Loader();
        final coordinator = RoundPlaybackCoordinator();
        final event = _event();
        Widget build(bool show) => host(
          event: () => event,
          loader: loader,
          coordinator: coordinator,
          show: show,
        );
        await tester.pumpWidget(build(true));
        await tester.tap(find.byTooltip('Play round video'));
        await settle(tester);
        expect(find.byType(RoundVideoStage), findsOneWidget);
        if (!playing) {
          await tester.tap(find.byTooltip('Pause round video').last);
          await settle(tester);
        }
        await tester.pumpWidget(build(false));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // Playing hands the staged controller to the mini player; paused
        // playback ends with the row.
        expect(RoundStageController.shared.isOpen, playing);
        await tester.pumpWidget(build(true));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(4, 4));
        await settle(tester);
        expect(RoundStageController.shared.isOpen, isFalse);
        expect(tester.takeException(), isNull);
        await teardownTree(tester);
      },
    );
  }
}
