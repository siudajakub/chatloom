import 'dart:async';

import 'package:chatloom/pages/chat/events/round_video_stage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

/// No initialize() or native texture: ownership and routing only.
VideoPlayerController _video({bool playing = true}) {
  final video = VideoPlayerController.networkUrl(
    Uri.parse('https://example.invalid/round.mp4'),
  );
  video.value = VideoPlayerValue(
    duration: const Duration(seconds: 10),
    position: const Duration(seconds: 2),
    size: const Size(240, 240),
    isInitialized: true,
    isPlaying: playing,
  );
  return video;
}

class _Calls {
  int toggles = 0, stops = 0, saves = 0;
  final seeks = <Duration>[];
  final speeds = <double>[];
  Rect? source;

  RoundStageActions actions({bool save = true}) => RoundStageActions(
    toggle: () async => toggles++,
    seek: (position) async => seeks.add(position),
    setSpeed: (speed) async => speeds.add(speed),
    stop: () async => stops++,
    save: save ? () async => saves++ : null,
    sourceRect: () => source,
  );
}

Widget _app(
  RoundStageController stage,
  VideoPlayerController video,
  _Calls calls, {
  bool reduced = false,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => stage.present(
                context,
                video: video,
                actions: calls.actions(),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  ),
);

bool _notDisposed(ChangeNotifier notifier) {
  try {
    return ChangeNotifier.debugAssertNotDisposed(notifier);
  } catch (_) {
    return false;
  }
}

void main() {
  testWidgets('shrinking keeps the same controller playing', (tester) async {
    final stage = RoundStageController();
    final video = _video();
    final calls = _Calls()..source = const Rect.fromLTWH(20, 500, 120, 120);
    addTearDown(video.dispose);
    await tester.pumpWidget(_app(stage, video, calls));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(stage.isStaged(video), isTrue);
    expect(find.bySemanticsLabel('Round video, enlarged'), findsOneWidget);
    final player = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
    expect(player.controller, same(video));
    expect(find.text('0:02 / 0:10'), findsOneWidget);

    // Backdrop tap shrinks: no pause/stop, controller untouched.
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(stage.isStaged(video), isTrue, reason: 'flight back still runs');
    await tester.pumpAndSettle();
    expect(stage.isStaged(video), isFalse);
    expect(find.byType(RoundVideoStage), findsNothing);
    expect(calls.toggles, 0);
    expect(calls.stops, 0);
    expect(_notDisposed(video), isTrue);
    expect(video.value.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stage controls drive the current owner callbacks', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = _video();
    final first = _Calls();
    final second = _Calls();
    addTearDown(video.dispose);
    await tester.pumpWidget(_app(stage, video, first));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause round video'));
    expect(first.toggles, 1);
    await tester.tap(find.byTooltip('Save round video'));
    expect(first.saves, 1);
    // Row recycled → mini player owns the same controller.
    stage.rebind(video, second.actions(save: false));
    await tester.pump();
    expect(find.byTooltip('Save round video'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Round video, enlarged'));
    expect(second.toggles, 1);
    expect(first.toggles, 1);
    await tester.tap(find.byTooltip('Stop playback'));
    expect(second.stops, 1);
    stage.release(video);
    await tester.pumpAndSettle();
    expect(find.byType(RoundVideoStage), findsNothing);
  });

  testWidgets('release before dispose removes the stage without errors', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = _video();
    await tester.pumpWidget(_app(stage, video, _Calls()));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    stage.release(video);
    await video.dispose();
    await tester.pump();
    expect(stage.isOpen, isFalse);
    expect(find.byType(RoundVideoStage), findsNothing);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner disposed mid-frame releases after the frame', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = _video();
    final calls = _Calls();
    var showOwner = true;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Scaffold(
              body: Column(
                children: [
                  if (showOwner) _Owner(stage: stage, video: video),
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => stage.present(
                        context,
                        video: video,
                        actions: calls.actions(),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(stage.isStaged(video), isTrue);
    // State.dispose runs while the tree is locked; release must defer the
    // navigator change instead of throwing.
    setOuter(() => showOwner = false);
    await tester.pump();
    await tester.pump();
    expect(stage.isOpen, isFalse);
    expect(find.byType(RoundVideoStage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion opens and shrinks without animation', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = _video();
    final calls = _Calls()..source = const Rect.fromLTWH(10, 10, 100, 100);
    addTearDown(video.dispose);
    await tester.pumpWidget(_app(stage, video, calls, reduced: true));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<RoundVideoStage>(find.byType(RoundVideoStage))
          .animation
          .value,
      1,
      reason: 'zero-duration transition',
    );
    final circle = tester.getRect(
      find.bySemanticsLabel('Round video, enlarged'),
    );
    expect(circle.width, greaterThan(100), reason: 'already at target');
    stage.shrink();
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoundVideoStage), findsNothing);
    expect(stage.isOpen, isFalse);
    expect(_notDisposed(video), isTrue);
  });

  testWidgets('presenting another controller releases the first', (
    tester,
  ) async {
    final stage = RoundStageController();
    final first = _video();
    final second = _video();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_app(stage, first, _Calls()));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('Open'));
    stage.present(context, video: second, actions: _Calls().actions());
    await tester.pumpAndSettle();
    expect(stage.isStaged(first), isFalse);
    expect(stage.isStaged(second), isTrue);
    expect(find.byType(RoundVideoStage), findsOneWidget);
    expect(
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller,
      same(second),
    );
    stage.release(second);
    await tester.pumpAndSettle();
  });

  testWidgets('completion shrinks the stage', (tester) async {
    final stage = RoundStageController();
    final video = _video();
    addTearDown(video.dispose);
    await tester.pumpWidget(_app(stage, video, _Calls()));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    video.value = video.value.copyWith(
      isPlaying: false,
      position: const Duration(seconds: 10),
      isCompleted: true,
    );
    await tester.pumpAndSettle();
    expect(stage.isOpen, isFalse);
    expect(_notDisposed(video), isTrue);
  });
}

/// Mimics a timeline row: releases, then disposes, inside State.dispose.
class _Owner extends StatefulWidget {
  final RoundStageController stage;
  final VideoPlayerController video;
  const _Owner({required this.stage, required this.video});
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  void dispose() {
    widget.stage.release(widget.video);
    unawaited(widget.video.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}
