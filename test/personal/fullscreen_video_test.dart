// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic decoder and message fixtures. No account, HTTP, files or codecs.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/pages/image_viewer/video_player.dart';
import 'package:chatloom/personal/media_transcript.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:video_player/video_player.dart';

import '../notion/conversation_test_support.dart';

class _Video extends VideoPlayerController {
  _Video() : super.networkUrl(Uri.parse('https://example.invalid/fixture'));

  @override
  Future<void> initialize() async {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 60),
      size: Size(1600, 900),
      isInitialized: true,
    );
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);
  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> seekTo(Duration position) async =>
      value = value.copyWith(position: position, isCompleted: false);
  @override
  Future<void> setPlaybackSpeed(double speed) async =>
      value = value.copyWith(playbackSpeed: speed);
  @override
  Future<void> setVolume(double volume) async =>
      value = value.copyWith(volume: volume);
}

class _VideoEvent extends Event {
  _VideoEvent(Room room, {Map<String, Object?> extra = const {}})
    : super(
        room: room,
        type: EventTypes.Message,
        eventId: r'$fullscreen-video',
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026, 11, 3, 12),
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'fixture.mp4',
          'url': 'mxc://example.invalid/fixture',
          'info': {
            'w': 400,
            'h': 300,
            'mimetype': 'video/mp4',
            'duration': 60000,
          },
          ...extra,
        },
      );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async => MatrixFile(bytes: Uint8List(0), name: 'fixture.mp4');
}

class _Transcripts extends PersonalClient {
  _Transcripts(super.client)
    : super.forTesting(openStore: () => throw StateError('No fixture store'));
  final jobs = <String, TranscriptionJob>{};
  @override
  Map<String, TranscriptionJob> get transcripts => jobs;
  @override
  String transcriptId(Event event) => event.eventId;
}

Future<void> _open(
  WidgetTester tester,
  Event event, {
  bool reduced = false,
}) async {
  RoundPlaybackCoordinator.shared.debugReset();
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(showImageViewer(context, event)),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 20 && find.text('Open').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  late _Video video;
  late Event event;
  late _Transcripts personal;
  setUp(() {
    RoundPlaybackCoordinator.shared.debugReset();
    MediaTranscriptPreference.visible.value = true;
    final client = ConversationClient();
    final room = ConversationRoom(client, '!video:example.invalid');
    event = _VideoEvent(room);
    personal = _Transcripts(client);
    PersonalClient.debugUse(client, personal);
    video = _Video();
    EventVideoPlayer.debugCreatePlayer = (_) => video;
  });
  tearDown(() {
    EventVideoPlayer.debugCreatePlayer = null;
    personal.dispose();
  });

  void transcript() {
    personal.jobs[event.eventId] = TranscriptionJob(
      id: event.eventId,
      source: SourceEventRef(
        conversation: ConversationRef(
          accountId: event.room.client.userID!,
          roomId: event.room.id,
        ),
        eventId: event.eventId,
      ),
      state: JobState.done,
      text: List.generate(
        20,
        (i) => 'Sentence ${i + 1} follows the video.',
      ).join(' '),
      durationSeconds: 60,
    );
  }

  testWidgets('video contains the live native size and rotation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, event);
    Size picture() => tester.getSize(find.byType(VideoPlayer));
    expect(picture().aspectRatio, closeTo(16 / 9, .001));
    expect(picture().width, lessThanOrEqualTo(390));
    video.value = video.value.copyWith(size: const Size(900, 1600));
    await tester.pump();
    expect(picture().aspectRatio, closeTo(9 / 16, .001));
    expect(picture().height, lessThan(844 - NotionSize.headerHeight));
    video.value = video.value.copyWith(rotationCorrection: 90);
    await tester.pump();
    expect(picture().aspectRatio, closeTo(16 / 9, .001));
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  for (final reduced in [false, true]) {
    testWidgets('transcript scroll keeps fullscreen, reduced motion $reduced', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      transcript();
      await _open(tester, event, reduced: reduced);
      final lyrics = find.byType(NotionSyncedTranscript);
      expect(lyrics, findsOneWidget);
      await tester.drag(lyrics, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsOneWidget);
      final controller = tester.state<ImageViewerController>(
        find.byType(ImageViewer),
      );
      expect(controller.dismiss.offset.value, 0);
      await tester.tap(find.byTooltip('Hide transcript'));
      await tester.pumpAndSettle();
      expect(lyrics, findsNothing);
      await tester.tap(find.byTooltip('Show transcript'));
      await tester.pumpAndSettle();
      expect(lyrics, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('landscape keeps video and transcript beside each other', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    transcript();
    await _open(tester, event);
    final picture = tester.getRect(find.byType(VideoPlayer));
    final lyrics = tester.getRect(find.byType(NotionSyncedTranscript));
    final controls = tester.getRect(
      find.byKey(const ValueKey('viewer-video-controls')),
    );
    expect(picture.right, lessThan(lyrics.left));
    expect(picture.bottom, lessThanOrEqualTo(controls.top));
    expect(lyrics.bottom, lessThanOrEqualTo(controls.top));
    expect(picture.width / picture.height, closeTo(16 / 9, .001));
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('a shared reel plays full screen under glass controls, '
      'without caption or transcript', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    event = _VideoEvent(
      event.room,
      extra: {
        'body': 'fixture.mp4',
        'filename': 'fixture.mp4',
        'external_url': 'https://www.instagram.com/reel/Cfixture/',
        'com.beeper.meta.full_post_title': 'fixture',
      },
    );
    // A transcript stored before 2026-11-18 is not shown either.
    transcript();
    await _open(tester, event);
    video.value = video.value.copyWith(size: const Size(900, 1600));
    await tester.pump();
    expect(find.byType(NotionSyncedTranscript), findsNothing);
    expect(find.byTooltip('Show transcript'), findsNothing);
    expect(find.textContaining('instagram.com'), findsNothing);
    // Edge to edge: the full width at 9:16.
    final picture = tester.getSize(find.byType(VideoPlayer));
    expect(picture.width, closeTo(390, .01));
    expect(picture.aspectRatio, closeTo(9 / 16, .001));
    final controls = find.byKey(const ValueKey('viewer-video-controls'));
    expect(controls, findsOneWidget);
    expect(tester.widget(controls), isA<NotionGlassPanel>());
    // Mute and unmute.
    await tester.tap(find.byKey(const ValueKey('viewer-reel-mute')));
    await tester.pump();
    expect(video.value.volume, 0);
    expect(find.byTooltip('Unmute'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-reel-mute')));
    await tester.pump();
    expect(video.value.volume, 1);
    // Playing, the controls fade out and a tap brings them back.
    if (!video.value.isPlaying) {
      await tester.tap(find.byKey(const ValueKey('viewer-reel-toggle')));
      await tester.pump();
    }
    expect(video.value.isPlaying, isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    AnimatedOpacity overlay() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('viewer-reel-controls')),
    );
    expect(overlay().opacity, 0);
    await tester.tap(find.byKey(const ValueKey('viewer-reel-picture')));
    await tester.pump();
    expect(overlay().opacity, 1);
    // The link lives in the overflow menu.
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Open in Instagram'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
