// SPDX-License-Identifier: AGPL-3.0-or-later
// Switching a mixing (muted preview) controller to an audible one never lets
// a frame or a stop reach the controller being disposed, and an unavailable
// source releases the lease. Fictional offline fixtures; no platform player.
import 'dart:async';

import 'package:fluffychat/pages/chat/events/round_video_message.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
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
  Completer<void>? disposeGate;
  bool disposing = false, disposed = false;
  @override
  Future<void> initialize() async {
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
  Future<void> setPlaybackSpeed(double speed) async {}
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> dispose() async {
    disposing = true;
    await disposeGate?.future;
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
    id: '!audible:example.invalid',
    client: Client('audible fixture', database: _UnusedDatabase()),
  ),
  eventId: r'$audible-round',
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
  late List<_Video> created;
  setUp(() {
    created = [];
    RoundVideoMessage.debugCreatePlayer = (media, {required muted}) {
      // The first controller mixes with others like a muted preview.
      final video = _Video(mixes: created.isEmpty);
      if (created.isEmpty) video.disposeGate = Completer<void>();
      created.add(video);
      return video;
    };
  });
  tearDown(() => RoundVideoMessage.debugCreatePlayer = null);

  Iterable<VideoPlayerController> mounted(WidgetTester tester) => tester
      .widgetList<VideoPlayer>(find.byType(VideoPlayer))
      .map((v) => v.controller);

  for (final staysAvailable in [true, false]) {
    testWidgets(
      'muted to audible switch ${staysAvailable ? 'hands the lease to the audible controller' : 'releases the lease when the source goes away'}',
      (tester) async {
        var available = true;
        final loader = _Loader();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RoundVideoMessage(
                _event(),
                loader: loader,
                coordinator: RoundPlaybackCoordinator(),
                showThumbnail: false,
                enlargeOnPlay: false,
                sourceAvailable: () => available,
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Play round video'));
        await tester.pump();
        await tester.pump();
        expect(created, hasLength(1));
        final muted = created.single;
        expect(muted.disposing, isTrue);
        // A frame while dispose is pending never mounts the old controller.
        await tester.pump();
        expect(mounted(tester), isNot(contains(muted)));
        expect(tester.takeException(), isNull);

        if (!staysAvailable) available = false;
        muted.disposeGate!.complete();
        await tester.pump();
        await tester.pump();
        expect(muted.disposed, isTrue);
        if (staysAvailable) {
          expect(created, hasLength(2));
          expect(mounted(tester), [created.last]);
          expect(created.last.value.isPlaying, isTrue);
          expect(loader.media.closed, isFalse);
        } else {
          expect(created, hasLength(1));
          expect(mounted(tester), isEmpty);
          expect(loader.media.closed, isTrue);
        }
        expect(tester.takeException(), isNull);

        // Unavailable on unmount: no hand-off to the mini player.
        available = false;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(loader.media.closed, isTrue);
        expect(created.every((v) => v.disposed), isTrue);
      },
    );
  }
}
