// SPDX-License-Identifier: AGPL-3.0-or-later
// A detached round that is paused and drawn nowhere never seeks natively
// (on macOS a native seek keeps a display link firing every vsync until a
// texture is composited): the bar shows the requested position at once and
// the seek lands on play or when a row takes the controller back.
// Fictional offline fixtures; no platform player.
import 'package:chatloom/pages/chat/events/round_mini_player.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

/// Controller that never reaches the platform and records native seeks.
class _Video extends VideoPlayerController {
  _Video() : super.networkUrl(Uri.parse('https://example.invalid/mini-seek')) {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 10),
      position: Duration(seconds: 1),
      size: Size(100, 100),
      isInitialized: true,
    );
  }

  final seeks = <Duration>[];

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    value = value.copyWith(position: position);
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);
  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> setPlaybackSpeed(double speed) async {}
}

Event _event() => Event(
  room: Room(
    id: '!mini-seek:example.invalid',
    client: Client('mini seek fixture', database: _UnusedDatabase()),
  ),
  eventId: r'$mini-seek',
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
  late RoundPlaybackCoordinator coordinator;
  late RoundMiniPlayerController control;
  late _Video video;
  late Event event;

  Future<RoundDetachedPlayback> adoptPaused(WidgetTester tester) async {
    event = _event();
    addTearDown(() => TelegramRoundService.closeFor(event.room.client));
    coordinator = RoundPlaybackCoordinator();
    control = RoundMiniPlayerController(coordinator: coordinator);
    addTearDown(control.dispose);
    video = _Video();
    final handle = coordinator.register(pause: () async {}, stop: () async {});
    final session = RoundDetachedPlayback(
      event: event,
      video: video,
      handle: handle,
      intent: RoundPlaybackIntent(),
    );
    control.adopt(session);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoundMiniPlayer(controller: control, onOpenSource: (_) {}),
        ),
      ),
    );
    return session;
  }

  String label(Duration position) =>
      '${RoundVideoView.formatTime(position)} / '
      '${RoundVideoView.formatTime(const Duration(seconds: 10))}';

  testWidgets('paused, unstaged seek shows at once and lands on play', (
    tester,
  ) async {
    final session = await adoptPaused(tester);
    expect(find.text(label(const Duration(seconds: 1))), findsOneWidget);

    await control.seek(const Duration(seconds: 4));
    await tester.pump();
    expect(video.seeks, isEmpty, reason: 'no native seek while undrawn');
    expect(session.position, const Duration(seconds: 4));
    expect(find.text(label(const Duration(seconds: 4))), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 4000);

    // Dragging keeps replacing the target, still without native work.
    await control.seek(const Duration(seconds: 6));
    expect(video.seeks, isEmpty);

    await control.toggle();
    await tester.pump();
    expect(video.seeks, [const Duration(seconds: 6)]);
    expect(video.value.isPlaying, isTrue);
    expect(session.pendingSeek, isNull);
    expect(session.position, const Duration(seconds: 6));

    // Playing: seeks go to the player directly.
    await control.seek(const Duration(seconds: 2));
    expect(video.seeks.last, const Duration(seconds: 2));
    expect(session.pendingSeek, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a paused seek past the end restarts from zero on play', (
    tester,
  ) async {
    final session = await adoptPaused(tester);
    await control.seek(const Duration(seconds: 30));
    expect(session.position, const Duration(seconds: 10));
    expect(video.seeks, isEmpty);
    await control.toggle();
    expect(video.seeks, [Duration.zero]);
    expect(video.value.isPlaying, isTrue);
  });

  testWidgets('a row taking the controller back applies the seek', (
    tester,
  ) async {
    final session = await adoptPaused(tester);
    await control.seek(const Duration(seconds: 3));
    expect(video.seeks, isEmpty);
    expect(control.takeFor(event), same(session));
    await tester.pump();
    expect(video.seeks, [const Duration(seconds: 3)]);
    expect(session.pendingSeek, isNull);
    expect(video.value.position, const Duration(seconds: 3));
    session.handle?.dispose();
  });
}
