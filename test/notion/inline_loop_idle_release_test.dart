// SPDX-License-Identifier: AGPL-3.0-or-later
// Perf wave (2026-11-26, lane mac): a muted loop that stays paused (covered,
// inactive, a hidden window) releases its native player after a grace. On
// macOS a paused player whose texture was never drawn keeps the plugin's
// display link firing every vsync; every paused player holds a decoder.
// Synthetic events only; nothing is downloaded, decrypted or sent.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/inline_loop_slots.dart';
import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
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
  _Client() : super('inline loop idle fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

/// Players that initialise at once and record play/pause/dispose.
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
  final room = Room(id: '!loop:example.invalid', client: client);
  late _FakePlatform platform;
  late VideoPlayerPlatform original;

  Event gif(String id) => Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: DateTime.utc(2026, 1, 1, 12),
    content: {
      'msgtype': MessageTypes.Video,
      'body': 'loop.mp4',
      'url': 'mxc://example.invalid/loop',
      'info': {'mimetype': 'video/mp4', 'fi.mau.gif': true},
    },
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _FakePlatform();
    VideoPlayerPlatform.instance = platform;
    InlineLoopSlots.debugReset();
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

  Widget app(Widget child) => MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('a paused loop frees its player after the grace and starts '
      'again when it may play', (tester) async {
    final loop = InlineLoopVideo(gif(r'$idle'), width: 320, height: 180);
    await tester.pumpWidget(app(TickerMode(enabled: true, child: loop)));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(platform.created, 1);
    expect(platform.playing, isNotEmpty);

    // Covered route, inactive app or a hidden Mac window.
    await tester.pumpWidget(app(TickerMode(enabled: false, child: loop)));
    await tester.pump();
    expect(platform.playing, isEmpty);
    expect(platform.players, hasLength(1), reason: 'paused, frame kept');

    await tester.pump(InlineLoopSlots.idleRelease);
    await tester.pump();
    // VideoPlayerController.dispose cancels its event subscription before
    // the platform call; that completes on the real event loop only.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    expect(platform.players, isEmpty, reason: 'native player released');
    expect(InlineLoopVideo.debugLivePlayers, 0);
    expect(find.byKey(const ValueKey('fake-texture')), findsNothing);

    await tester.pumpWidget(app(TickerMode(enabled: true, child: loop)));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(platform.created, 2);
    expect(platform.playing, isNotEmpty);

    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();
    expect(InlineLoopVideo.debugLivePlayers, 0);
  });

  testWidgets('playing again within the grace keeps the same player', (
    tester,
  ) async {
    final loop = InlineLoopVideo(gif(r'$brief'), width: 320, height: 180);
    await tester.pumpWidget(app(TickerMode(enabled: true, child: loop)));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await tester.pumpWidget(app(TickerMode(enabled: false, child: loop)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(app(TickerMode(enabled: true, child: loop)));
    await tester.pump();
    await tester.pump(InlineLoopSlots.idleRelease * 2);
    expect(platform.created, 1);
    expect(platform.players, hasLength(1));
    expect(platform.playing, isNotEmpty);

    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();
  });
}
