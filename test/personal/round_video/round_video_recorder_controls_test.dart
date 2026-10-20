// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/round_video_recorder.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_capture_backend.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/round_media_preparer.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Hardware and all labels here are fictional. These tests exercise the actual
/// recorder, not a recreation of its controls or a logged-in conversation.
class RecorderFixture {
  final bool controlsAvailable;
  final methods = <String>[];
  final revisions = <int>[];
  final zooms = <double>[];
  int revision = 1;
  double zoom = 1;
  bool torch = false;
  bool switched = false;
  String? captureId;
  String? outputPath;

  /// Holds the native switch reply (the new lens "opening") while set.
  Completer<void>? switchHold;
  final initialized = Completer<void>();
  final disposed = Completer<void>();
  RecorderFixture({required this.controlsAvailable});

  Map<String, Object?> get preview => {
    'captureId': captureId,
    'textureId': 1,
    'width': 384,
    'height': 384,
    'rotation': 0,
    'mirrored': false,
    'canSwitchCamera': controlsAvailable,
    'canSwitchDuringRecording': controlsAvailable,
    'cameraRevision': revision,
    'minZoom': 1.0,
    'maxZoom': controlsAvailable && !switched ? 4.0 : 1.0,
    'zoom': zoom,
    'torchAvailable': controlsAvailable && !switched,
    'torchEnabled': torch,
  };

  /// Calls with a foreign capture id or stale camera revision. Checked after
  /// each test: `expect` inside a channel handler can run during a pump.
  final mismatches = <String>[];

  Future<Object?> handle(MethodCall call) async {
    methods.add(call.method);
    final args = call.arguments as Map;
    if (call.method == 'initialize') {
      captureId = args['captureId'] as String;
      outputPath = args['outputPath'] as String;
      initialized.complete();
      return preview;
    }
    captureId ??= args['captureId'] as String;
    if (args['captureId'] != captureId) mismatches.add('${call.method} id');
    if (call.method == 'switchCamera' ||
        call.method == 'setZoom' ||
        call.method == 'setTorch') {
      if (args['cameraRevision'] != revision) {
        mismatches.add('${call.method} revision');
      }
      revisions.add(revision);
    }
    switch (call.method) {
      case 'dispose':
        if (!disposed.isCompleted) disposed.complete();
        return null;
      case 'switchCamera':
        await switchHold?.future;
        revision++;
        switched = true;
        zoom = 1;
        torch = false;
        return preview;
      case 'setZoom':
        zoom = (args['zoom'] as num).toDouble();
        zooms.add(zoom);
        return preview;
      case 'setTorch':
        torch = args['enabled'] == true;
        return preview;
      case 'finish':
        return {
          'captureId': captureId,
          'path': outputPath,
          'width': 384,
          'height': 384,
          'durationMs': 900,
          'sizeBytes': 1000,
          'videoCodec': 'h264',
          'audioCodec': 'aac',
          'cornersSanitized': true,
          'fastStart': true,
        };
      default:
        return null;
    }
  }
}

/// The recorder route's result. Awaiting it inside the fake-async test body
/// would deadlock, so tests pump until it is [done].
class Outcome {
  bool done = false;
  PreparedRoundMedia? media;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await fonts.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  const channel = MethodChannel(AndroidRoundCaptureBackend.channelName);
  final boundaryKey = GlobalKey();
  final hostKey = GlobalKey();
  Directory? directory;
  Finder button(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );

  /// Real time for File I/O and the recorder's stopwatch; fake-queue pumps
  /// let the continuations run.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 200 && !done(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> record(WidgetTester tester, Duration duration) async {
    await tester.runAsync(() => Future<void>.delayed(duration));
    await tester.pump();
  }

  Future<MediaAccess> mount(
    WidgetTester tester,
    RecorderFixture fixture, {
    double width = 390,
    double textScale = 1,
    Widget Function(MediaAccess access)? recorder,
    NotionGlassMode glass = NotionGlassMode.auto,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fixture.handle);
    final access = await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('round-recorder-ui-');
      return MediaAccess.open(directory: directory!);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: NotionGlassScope(
            mode: glass,
            child: RepaintBoundary(key: boundaryKey, child: child),
          ),
        ),
        home: Scaffold(
          key: hostKey,
          body: recorder == null
              ? const Center(child: Text('Conversation'))
              : recorder(access!),
        ),
      ),
    );
    return access!;
  }

  /// The recorder without a composer gesture: it waits for a tap on the
  /// record circle (re-recording and the attach-menu path).
  Future<void> open(
    WidgetTester tester,
    RecorderFixture fixture, {
    double width = 390,
    double textScale = 1,
  }) async {
    await mount(
      tester,
      fixture,
      width: width,
      textScale: textScale,
      recorder: (access) => RoundVideoRecorder(
        mediaAccess: access,
        profile: const RoundCaptureProfile(maxBytes: 25000000),
      ),
    );
    await settle(
      tester,
      () =>
          fixture.initialized.isCompleted &&
          find.text('Tap the camera button to record').evaluate().isNotEmpty,
    );
    expect(fixture.initialized.isCompleted, isTrue);
    await tester.pump();
    expect(find.text('Tap the camera button to record'), findsOneWidget);
  }

  /// Opens the recorder route the way the composer does, with a held gesture.
  Future<Outcome> openHeld(
    WidgetTester tester,
    RecorderFixture fixture,
    RoundCaptureGestureController gesture, {
    NotionGlassMode glass = NotionGlassMode.auto,
  }) async {
    final access = await mount(tester, fixture, glass: glass);
    final outcome = Outcome();
    unawaited(
      showRoundVideoRecorder(
        hostKey.currentContext!,
        mediaAccess: access,
        profile: const RoundCaptureProfile(maxBytes: 25000000),
        targetLabel: 'Telegram · Fixture chat',
        gesture: gesture,
      ).then((media) {
        outcome.media = media;
        outcome.done = true;
      }),
    );
    await settle(tester, () => fixture.methods.contains('start'));
    expect(fixture.methods, ['initialize', 'start']);
    await tester.pump();
    return outcome;
  }

  Future<void> close(WidgetTester tester, RecorderFixture fixture) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var empty = false;
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      empty = await tester.runAsync(() => directory!.list().isEmpty) ?? false;
      if (fixture.disposed.isCompleted && empty) break;
    }
    expect(fixture.disposed.isCompleted, isTrue);
    expect(empty, isTrue);
    expect(fixture.mismatches, isEmpty);
    await tester.runAsync(() async {
      await directory?.delete(recursive: true);
    });
    directory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  Future<void> evidence(WidgetTester tester, String name) async {
    final root =
        Platform.environment['ROUND_RECORDER_EVIDENCE_DIR'] ??
        Platform.environment['NOTION_CAPTURE_DIR'];
    if (root == null) return;
    final output = '$root/round-recorder';
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final rendered = await boundary
          .toImage(pixelRatio: 1)
          .timeout(const Duration(seconds: 3));
      try {
        final bytes = await rendered
            .toByteData(format: ui.ImageByteFormat.png)
            .timeout(const Duration(seconds: 3));
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        rendered.dispose();
      }
    });
  }

  testWidgets(
    'unsupported camera controls are disabled; the front camera offers a screen flash',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: false);
      try {
        await open(tester, fixture);
        final switchButton = tester.widget<IconButton>(
          button('Only one camera available'),
        );
        expect(switchButton.onPressed, isNull);
        // Telegram: no zoom slider, pinch only.
        expect(find.byType(Slider), findsNothing);
        await tester.tap(button('Turn screen flash on'));
        await tester.pump();
        expect(button('Turn screen flash off'), findsOneWidget);
        // The screen flash is local: it never reaches the camera.
        expect(fixture.methods, ['initialize']);
        // The camera circle follows Telegram: min side − 28 dp on a phone.
        expect(
          tester.getSize(find.byKey(const Key('round_camera_circle'))),
          const Size.square(390 - 28),
        );
      } finally {
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    'locked recording: pinch zoom springs back, pause, resume and flip use the native revision',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      try {
        await open(tester, fixture);
        await evidence(tester, 'recorder-ready-390');
        await tester.tap(find.byTooltip('Turn light on'));
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('Turn light off'), findsOneWidget);
        await tester.tap(find.byKey(const Key('round_record_start')));
        await tester.pump();
        await tester.pump();
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.byTooltip('Send round video'), findsOneWidget);
        expect(
          tester.widget<IconButton>(button('Switch camera')).onPressed,
          isNotNull,
        );
        // Two fingers inside the circle.
        final circle = tester.getCenter(
          find.byKey(const Key('round_camera_circle')),
        );
        final a = await tester.startGesture(circle - const Offset(30, 0));
        final b = await tester.startGesture(
          circle + const Offset(30, 0),
          pointer: 7,
        );
        await tester.pump();
        await a.moveBy(const Offset(-40, 0));
        await b.moveBy(const Offset(40, 0));
        await tester.pump();
        await tester.pump();
        expect(fixture.zooms, isNotEmpty);
        expect(fixture.zooms.last, greaterThan(1.5));
        await a.up();
        await b.up();
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(fixture.zoom, 1);
        await evidence(tester, 'recorder-locked-390');
        // Under the 800 ms minimum Telegram discards on pause, so record
        // long enough first.
        await record(tester, const Duration(milliseconds: 850));
        await tester.tap(find.byTooltip('Pause recording'));
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('Resume recording'), findsOneWidget);
        expect(find.text('Preview'), findsOneWidget);
        await evidence(tester, 'recorder-paused-390');
        await tester.tap(button('Switch camera'));
        await tester.pump();
        // The native lens switch starts with the turn, not half-way through.
        expect(fixture.methods, contains('switchCamera'));
        expect(
          RoundRecorderLayout.flip,
          lessThan(const Duration(milliseconds: 580)),
        );
        await tester.pump(RoundRecorderLayout.flip);
        await tester.pump();
        await tester.pump(RoundRecorderLayout.flip);
        expect(
          tester
              .widget<IconButton>(button('Light unavailable on this camera'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byTooltip('Resume recording'));
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('Pause recording'), findsOneWidget);
        final methods = fixture.methods.where((m) => m != 'setZoom').toList();
        expect(methods, [
          'initialize',
          'setTorch',
          'start',
          'pause',
          'switchCamera',
          'resume',
        ]);
        expect(fixture.revisions.toSet(), {1});
      } finally {
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    'flip: the lens switch overlaps the turn; a slow lens shows the waiting scrim until it is live',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      double waitingOpacity() => tester
          .widget<AnimatedOpacity>(find.byKey(const Key('round_flip_waiting')))
          .opacity;
      try {
        await open(tester, fixture);
        await tester.tap(find.byKey(const Key('round_record_start')));
        await tester.pump();
        await tester.pump();
        fixture.switchHold = Completer<void>();
        await tester.tap(button('Switch camera'));
        await tester.pump();
        expect(fixture.methods.where((m) => m == 'switchCamera'), hasLength(1));
        // Mid-turn: no waiting scrim yet, and a second tap is ignored.
        await tester.pump(RoundRecorderLayout.flip ~/ 2);
        expect(waitingOpacity(), 0);
        await tester.tap(button('Switch camera'), warnIfMissed: false);
        await tester.pump();
        expect(fixture.methods.where((m) => m == 'switchCamera'), hasLength(1));
        // The turn ended before the lens: last frame under the scrim.
        await tester.pump(RoundRecorderLayout.flip);
        await tester.pump();
        expect(waitingOpacity(), 1);
        fixture.switchHold!.complete();
        fixture.switchHold = null;
        await settle(tester, () => waitingOpacity() == 0);
        expect(waitingOpacity(), 0);
        expect(fixture.mismatches, isEmpty);
      } finally {
        fixture.switchHold?.complete();
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    'the conversation behind the recorder is dimmed: the backdrop fades in with the route and out on cancel',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      final gesture = RoundCaptureGestureController(held: true);
      double backdropOpacity() => tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.byType(RoundRecorderBackdrop),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;
      final glass = find.byKey(const Key('round_recorder_glass'));
      final dim = find.byKey(const Key('round_recorder_dim'));
      try {
        final result = await openHeld(
          tester,
          fixture,
          gesture,
          glass: NotionGlassMode.on,
        );
        expect(find.byType(RoundRecorderBackdrop), findsOneWidget);
        // Exactly one backdrop layer, and it never takes the pointer.
        expect(
          find.descendant(
            of: find.byType(RoundRecorderBackdrop),
            matching: find.byType(IgnorePointer),
          ),
          findsWidgets,
        );
        // Fades in with the opening route as a flat dim: glass never sits
        // inside the route's fade (DESIGN.md), it appears once settled.
        expect(backdropOpacity(), lessThan(1));
        expect(dim, findsOneWidget);
        expect(glass, findsNothing);
        await tester.pump(const Duration(milliseconds: 250));
        expect(backdropOpacity(), 1);
        expect(glass, findsOneWidget);
        expect(dim, findsNothing);
        gesture.move(dx: -140, dy: 0);
        await settle(tester, () => result.done);
        // Fading out with the closing route as the flat dim, then gone.
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(RoundRecorderBackdrop), findsOneWidget);
        expect(backdropOpacity(), inExclusiveRange(0.0, 1.0));
        expect(glass, findsNothing);
        expect(dim, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(RoundRecorderBackdrop), findsNothing);
      } finally {
        gesture.dispose();
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    '320px and 200 percent text keep controls reachable without overflow',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      try {
        await open(tester, fixture, width: 320, textScale: 2);
        expect(tester.takeException(), isNull);
        await evidence(tester, 'recorder-320-text200-ready');
        await tester.tap(find.byTooltip('Turn light on'));
        await tester.pump();
        await tester.pump();
        expect(fixture.methods, contains('setTorch'));
        await tester.tap(find.byKey(const Key('round_record_start')));
        await tester.pump();
        await tester.pump();
        expect(find.text('Cancel'), findsOneWidget);
        expect(
          tester.getSize(find.byTooltip('Pause recording')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
        await evidence(tester, 'recorder-320-text200-locked');
      } finally {
        await close(tester, fixture);
      }
    },
  );

  group('held from the composer', () {
    testWidgets('release before 800 ms discards silently', (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      final gesture = RoundCaptureGestureController(
        held: true,
        anchor: const Rect.fromLTWH(330, 770, 56, 56),
      );
      try {
        final result = await openHeld(tester, fixture, gesture);
        expect(find.text('Slide to cancel'), findsOneWidget);
        expect(find.byKey(const Key('round_lock_pill')), findsOneWidget);
        expect(find.text('Telegram · Fixture chat'), findsOneWidget);
        // Let the open animation (scale 0.1 → 1 from below) finish.
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester.getSize(find.byKey(const Key('round_camera_circle'))),
          const Size.square(390 - 28),
        );
        gesture.move(dx: -50, dy: -20);
        await tester.pump();
        await evidence(tester, 'recorder-held-390');
        gesture.release();
        await settle(tester, () => result.done);
        await tester.pump(const Duration(milliseconds: 300));
        expect(result.done, isTrue);
        expect(result.media, isNull);
        expect(fixture.methods, contains('cancel'));
        expect(fixture.methods, isNot(contains('finish')));
      } finally {
        gesture.dispose();
        await close(tester, fixture);
      }
    });

    testWidgets('release after 800 ms sends at once without review', (
      tester,
    ) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      final gesture = RoundCaptureGestureController(held: true);
      PreparedRoundMedia? media;
      try {
        final result = await openHeld(tester, fixture, gesture);
        await record(tester, const Duration(milliseconds: 850));
        gesture.release();
        await settle(tester, () => result.done);
        await tester.pump(const Duration(milliseconds: 300));
        media = result.media;
        expect(media, isNotNull);
        expect(media!.durationMs, 900);
        expect(fixture.methods, isNot(contains('cancel')));
        expect(find.text('Review before sending'), findsNothing);
      } finally {
        await tester.runAsync(() async => media?.close());
        gesture.dispose();
        await close(tester, fixture);
      }
    });

    testWidgets('slide to cancel follows the finger and cancels at the end', (
      tester,
    ) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      final gesture = RoundCaptureGestureController(held: true);
      try {
        final result = await openHeld(tester, fixture, gesture);
        gesture.move(dx: -70, dy: 0);
        await tester.pump();
        final hint = tester.widget<Opacity>(
          find
              .ancestor(
                of: find.text('Slide to cancel'),
                matching: find.byType(Opacity),
              )
              .first,
        );
        expect(hint.opacity, closeTo(0.5, 0.01));
        gesture.move(dx: -140, dy: 0);
        await settle(tester, () => result.done);
        await tester.pump(const Duration(milliseconds: 300));
        expect(result.done, isTrue);
        expect(result.media, isNull);
        expect(fixture.methods, contains('cancel'));
        expect(fixture.methods, isNot(contains('finish')));
      } finally {
        gesture.dispose();
        await close(tester, fixture);
      }
    });

    testWidgets('swipe up locks; the send arrow finishes and returns media', (
      tester,
    ) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      final gesture = RoundCaptureGestureController(held: true);
      PreparedRoundMedia? media;
      try {
        final result = await openHeld(tester, fixture, gesture);
        gesture.move(dx: 0, dy: -60);
        await tester.pump();
        expect(gesture.phase, RoundCaptureGesturePhase.locked);
        gesture.release();
        await tester.pump();
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Slide to cancel'), findsNothing);
        expect(fixture.methods, isNot(contains('finish')));
        await record(tester, const Duration(milliseconds: 850));
        await tester.tap(find.byTooltip('Send round video'));
        await settle(tester, () => result.done);
        await tester.pump(const Duration(milliseconds: 300));
        media = result.media;
        expect(media, isNotNull);
      } finally {
        await tester.runAsync(() async => media?.close());
        gesture.dispose();
        await close(tester, fixture);
      }
    });
  });
}
