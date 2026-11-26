// SPDX-License-Identifier: AGPL-3.0-or-later
// A start that is abandoned after its controller initialized (another round
// took the audio while the codec was being set up) releases that controller
// and its lease at once. An initialized player that never draws keeps the
// platform video pipeline alive (on macOS a display link every vsync).
// Fictional offline fixtures; no platform player.
import 'dart:async';

import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

/// Controller that never reaches the platform.
class _Video extends VideoPlayerController {
  _Video({required bool mixes})
    : super.networkUrl(
        Uri.parse('https://example.invalid/round'),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: mixes),
      );
  Completer<void>? initializeGate, speedGate;
  bool initializing = false, settingSpeed = false, disposed = false;
  @override
  Future<void> initialize() async {
    initializing = true;
    await initializeGate?.future;
    value = const VideoPlayerValue(
      duration: Duration(seconds: 10),
      size: Size(100, 100),
      isInitialized: true,
    );
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);
  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    settingSpeed = true;
    await speedGate?.future;
  }

  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _Media extends RoundLoadedMedia {
  _Media() : super.web(Uri.parse('data:video/mp4;base64,AAAA'));
  bool closed = false;
  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

class _Loader extends RoundMediaLoader {
  final media = _Media();
  @override
  Future<RoundLoadedMedia> load(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) async => media;
}

Event _event() => Event(
  room: Room(
    id: '!abort:example.invalid',
    client: Client('abort fixture', database: _UnusedDatabase()),
  ),
  eventId: r'$abort-round',
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
  tearDown(() => RoundVideoMessage.debugCreatePlayer = null);

  // A plain audible start (superseded while its speed is set) and a muted
  // controller switched to an audible one (superseded while the audible
  // one initializes).
  for (final mixing in [false, true]) {
    testWidgets('${mixing ? 'a muted-to-audible switch' : 'an audible start'} '
        'superseded after initialize releases its controller', (tester) async {
      final created = <_Video>[];
      final gate = Completer<void>();
      RoundVideoMessage.debugCreatePlayer = (media, {required muted}) {
        final video = _Video(mixes: mixing && created.isEmpty);
        // The controller that will be abandoned waits at the gate.
        if (mixing ? created.length == 1 : created.isEmpty) {
          if (mixing) {
            video.initializeGate = gate;
          } else {
            video.speedGate = gate;
          }
        }
        created.add(video);
        return video;
      };
      final coordinator = RoundPlaybackCoordinator();
      final loader = _Loader();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoundVideoMessage(
              _event(),
              loader: loader,
              coordinator: coordinator,
              showThumbnail: false,
              enlargeOnPlay: false,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play round video'));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      final abandoned = created.last;
      expect(created, hasLength(mixing ? 2 : 1));
      expect(mixing ? abandoned.initializing : abandoned.settingSpeed, isTrue);

      // Another round takes the audio meanwhile.
      final other = coordinator.register(pause: () async {}, stop: () async {});
      addTearDown(other.dispose);
      expect(await other.acquireAudible(), isTrue);

      gate.complete();
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(abandoned.disposed, isTrue);
      expect(abandoned.value.isPlaying, isFalse);
      expect(loader.media.closed, isTrue);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(created.every((v) => v.disposed), isTrue);
    });
  }
}
