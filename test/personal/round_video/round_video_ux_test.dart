// SPDX-License-Identifier: AGPL-3.0-or-later
// UX contracts from the 17 Oct review: glyphs, speed cycle, seek-once,
// record button tooltip.
import 'package:chatloom/pages/chat/events/round_video_stage.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/personal/round_video/round_record_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

VideoPlayerController _video() {
  final video = VideoPlayerController.networkUrl(
    Uri.parse('https://example.invalid/round.mp4'),
  );
  video.value = VideoPlayerValue(
    duration: const Duration(seconds: 10),
    position: const Duration(seconds: 2),
    size: const Size(240, 240),
    isInitialized: true,
  );
  return video;
}

void main() {
  test('speed cycle matches voice messages and labels trim zeros', () {
    expect(RoundVideoView.speedCycle, [1.0, 1.25, 1.5, 2.0, 0.5]);
    var speed = 1.0;
    final seen = <double>[];
    for (var i = 0; i < 5; i++) {
      speed = RoundVideoView.nextSpeed(speed);
      seen.add(speed);
    }
    expect(seen, [1.25, 1.5, 2.0, 0.5, 1.0]);
    // A slider value off the cycle restarts it.
    expect(RoundVideoView.nextSpeed(1.7), 1.0);
    expect(RoundVideoView.speedLabel(1), '1×');
    expect(RoundVideoView.speedLabel(1.25), '1.25×');
    expect(RoundVideoView.speedLabel(1.5), '1.5×');
    expect(RoundVideoView.speedLabel(.5), '0.5×');
  });

  testWidgets('glyphs are circular and the placeholder has no camera icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.light),
        home: Scaffold(
          body: RoundVideoView(
            duration: const Duration(seconds: 3),
            mediaUnread: true,
            onToggle: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.style!.shape!.resolve({}), isA<CircleBorder>());
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('round-unread-dot')),
    );
    final context = tester.element(find.byType(RoundVideoView));
    expect(
      (dot.decoration! as BoxDecoration).color,
      context.notion.colors.info,
    );
  });

  testWidgets('indeterminate download draws a ring around the cancel glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RoundVideoView(loading: true, onCancel: () {})),
      ),
    );
    final spinner = find.byKey(const ValueKey('round-download-spinner'));
    expect(spinner, findsOneWidget);
    expect(tester.getSize(spinner), const Size.square(44));
    expect(
      tester.getCenter(spinner),
      tester.getCenter(find.byTooltip('Cancel download')),
    );
  });

  testWidgets('stage speed pill cycles and the slider seeks once per drag', (
    tester,
  ) async {
    final stage = RoundStageController();
    final video = _video();
    addTearDown(video.dispose);
    final seeks = <Duration>[];
    final speeds = <double>[];
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
                  seek: (position) async => seeks.add(position),
                  setSpeed: (speed) async => speeds.add(speed),
                  stop: () async {},
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

    await tester.tap(find.text('1×'));
    expect(speeds, [1.25]);

    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    expect(seeks, isEmpty, reason: 'dragging only previews');
    expect(find.text('0:02 / 0:10'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(const Duration(seconds: 5)));

    stage.release(video);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stage barrier uses the media scrim token', (tester) async {
    final stage = RoundStageController();
    final video = _video();
    addTearDown(video.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => stage.present(
              context,
              video: video,
              actions: RoundStageActions(
                toggle: () async {},
                seek: (_) async {},
                setSpeed: (_) async {},
                stop: () async {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final route =
        ModalRoute.of(tester.element(find.byType(RoundVideoStage)))!
            as RoundStageRoute;
    expect(route.barrierColor, NotionMediaColors.stageScrim);
    stage.release(video);
    await tester.pumpAndSettle();
  });

  testWidgets('record button tooltip never pops on long press', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: RoundRecordButton(onRecord: (_) async {})),
        ),
      ),
    );
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.triggerMode, TooltipTriggerMode.manual);
    expect(tooltip.message, 'Record a round video');
    expect(
      find.bySemanticsLabel(RegExp('^Record a round video')),
      findsOneWidget,
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.videocam_outlined));
    final context = tester.element(find.byType(RoundRecordButton));
    expect(icon.color, Theme.of(context).colorScheme.onSurface);
  });
}
