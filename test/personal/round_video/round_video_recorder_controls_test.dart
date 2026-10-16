// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluffychat/pages/chat/round_video_recorder.dart';
import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/round_video/round_capture_backend.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
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
  int revision = 1;
  double zoom = 1;
  bool torch = false;
  bool switched = false;
  String? captureId;
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

  Future<Object?> handle(MethodCall call) async {
    methods.add(call.method);
    final args = call.arguments as Map;
    if (call.method == 'initialize') {
      captureId = args['captureId'] as String;
      initialized.complete();
      return preview;
    }
    captureId ??= args['captureId'] as String;
    expect(args['captureId'], captureId);
    if (call.method == 'switchCamera' ||
        call.method == 'setZoom' ||
        call.method == 'setTorch') {
      expect(args['cameraRevision'], revision);
      revisions.add(revision);
    }
    switch (call.method) {
      case 'dispose':
        if (!disposed.isCompleted) disposed.complete();
        return null;
      case 'switchCamera':
        revision++;
        switched = true;
        zoom = 1;
        torch = false;
        return preview;
      case 'setZoom':
        zoom = (args['zoom'] as num).toDouble();
        return preview;
      case 'setTorch':
        torch = args['enabled'] == true;
        return preview;
      default:
        return null;
    }
  }
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
  Directory? directory;
  Finder button(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );

  Future<void> open(
    WidgetTester tester,
    RecorderFixture fixture, {
    double width = 390,
    double textScale = 1,
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
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: RoundVideoRecorder(
            mediaAccess: access!,
            profile: const RoundCaptureProfile(maxBytes: 25000000),
          ),
        ),
      ),
    );
    // File I/O uses real time; its continuations need fake-queue pumps too.
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (fixture.initialized.isCompleted &&
          find.text('Hold to record').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(fixture.initialized.isCompleted, isTrue);
    await tester.pump();
    expect(find.text('Hold to record'), findsOneWidget);
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
    final output = Platform.environment['ROUND_RECORDER_EVIDENCE_DIR'];
    if (output == null) return;
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
    'unsupported camera controls are visibly disabled and never invoke hardware',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: false);
      try {
        await open(tester, fixture);
        final switchButton = tester.widget<IconButton>(
          button('Only one camera available'),
        );
        final torchButton = tester.widget<IconButton>(
          button('Light unavailable on this camera'),
        );
        expect(switchButton.onPressed, isNull);
        expect(torchButton.onPressed, isNull);
        expect(find.byType(Slider), findsNothing);
        expect(find.text('Zoom unavailable on this camera'), findsOneWidget);
        expect(fixture.methods, ['initialize']);
      } finally {
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    'recording and paused controls use current native revision and camera availability',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      try {
        await open(tester, fixture);
        await evidence(tester, 'recorder-controls-390');
        final zoomSlider = tester.widget<Slider>(find.byType(Slider));
        expect(zoomSlider.min, 1);
        expect(zoomSlider.max, 4);
        expect(zoomSlider.semanticFormatterCallback!(2), '2.0 times zoom');
        zoomSlider.onChanged!(2);
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byTooltip('Turn light on'));
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('Turn light off'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.videocam));
        await tester.pump();
        await tester.pump();
        expect(find.text('Recording locked'), findsOneWidget);
        expect(
          tester.widget<IconButton>(button('Switch camera')).onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('Pause recording'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Recording paused'), findsOneWidget);
        await tester.tap(button('Switch camera'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Recording paused'), findsOneWidget);
        expect(find.byType(Slider), findsNothing);
        expect(
          tester
              .widget<IconButton>(button('Light unavailable on this camera'))
              .onPressed,
          isNull,
        );
        expect(fixture.methods, [
          'initialize',
          'setZoom',
          'setTorch',
          'start',
          'pause',
          'switchCamera',
        ]);
        expect(fixture.revisions, [1, 1, 1]);
      } finally {
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
        await evidence(tester, 'recorder-controls-320-text200-top');
        await tester.ensureVisible(find.byTooltip('Turn light on'));
        await tester.tap(find.byTooltip('Turn light on'));
        await tester.pump();
        await tester.pump();
        expect(fixture.methods, contains('setTorch'));
        await tester.ensureVisible(find.text('Cancel'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await evidence(tester, 'recorder-controls-320-text200-controls');
      } finally {
        await close(tester, fixture);
      }
    },
  );

  testWidgets(
    'a new disabled-avatar gesture cannot reuse the locked hold to cancel',
    (tester) async {
      final fixture = RecorderFixture(controlsAvailable: true);
      try {
        await open(tester, fixture);
        final avatar = find.byIcon(Icons.videocam);
        await tester.ensureVisible(avatar);
        final hold = await tester.startGesture(tester.getCenter(avatar));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await hold.moveBy(const Offset(0, -85));
        await tester.pump();
        await hold.up();
        await tester.pump();
        expect(find.text('Recording locked'), findsOneWidget);
        final stray = await tester.startGesture(tester.getCenter(avatar));
        await tester.pump(const Duration(milliseconds: 600));
        await stray.moveBy(const Offset(-110, 0));
        await tester.pump();
        await stray.up();
        await tester.pump();
        expect(find.text('Recording locked'), findsOneWidget);
        expect(fixture.methods.where((method) => method == 'start').length, 1);
        expect(fixture.methods, isNot(contains('cancel')));
        expect(fixture.methods, isNot(contains('finish')));
      } finally {
        await close(tester, fixture);
      }
    },
  );
}
