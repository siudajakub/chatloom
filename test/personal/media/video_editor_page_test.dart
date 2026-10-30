// SPDX-License-Identifier: AGPL-3.0-or-later
// The send-time video editor against fake platforms: a video_player that
// behaves like video_player_android (initialize, loop, volume, dispose) and
// a pro_video_editor that records what Done asks it to render. The native
// render itself (Media3/AVFoundation) needs a phone.
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/video_editor_page.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _duration = Duration(milliseconds: 12700);

class _Player extends VideoPlayerPlatform {
  _Player(this.log);

  final List<String> log;
  final players = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  var _next = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    log.add('player create');
    positions[id] = Duration.zero;
    players[id] = StreamController<VideoEvent>.broadcast(
      onListen: () => scheduleMicrotask(
        () => players[id]?.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: _duration,
            size: const Size(1080, 1920),
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
    log.add('player dispose');
    unawaited(players.remove(playerId)?.close());
  }

  /// Like video_player_android: a disposed player has no view.
  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    if (!players.containsKey(options.playerId)) {
      throw StateError('No active player with ID ${options.playerId}.');
    }
    return const SizedBox.expand(key: ValueKey('texture'));
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      log.add('looping $looping');
  @override
  Future<void> play(int playerId) async => log.add('play');
  @override
  Future<void> pause(int playerId) async => log.add('pause');
  @override
  Future<void> setVolume(int playerId, double volume) async =>
      log.add('volume $volume');

  /// Holds seeks until completed, like a slow decoder.
  Completer<void>? seekGate;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    await seekGate?.future;
    // Like video_player_android: a released player is unknown.
    if (!players.containsKey(playerId)) {
      throw PlatformException(
        code: 'VideoError',
        message: 'No active player for /data/user/0/app/cache/clip.mp4',
      );
    }
    positions[playerId] = position;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

class _Editor extends ProVideoEditor {
  _Editor(this.log);

  final List<String> log;
  Size resolution = const Size(1080, 1920);
  final renders = <VideoRenderData>[];
  final outputs = <String>[];
  final cancelled = <String>[];

  /// What a render does; completes normally by default.
  Future<void> Function(VideoRenderData data)? onRender;

  @override
  void initializeStream() {}

  @override
  Future<VideoMetadata> getMetadata(
    EditorVideo value, {
    bool checkStreamingOptimization = false,
    NativeLogLevel? nativeLogLevel,
  }) async => VideoMetadata(
    duration: _duration,
    extension: 'mp4',
    fileSize: 24 * 1000 * 1000,
    resolution: resolution,
    rotation: 90,
    bitrate: 17 * 1000 * 1000,
  );

  @override
  Future<List<Uint8List>> getKeyFrames(
    KeyFramesConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async => const [];

  @override
  Future<String> renderVideoToFile(
    String filePath,
    VideoRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    log.add('render');
    renders.add(value);
    outputs.add(filePath);
    await onRender?.call(value);
    return filePath;
  }

  @override
  Future<void> cancel(String taskId) async {
    log.add('cancel');
    cancelled.add(taskId);
  }
}

Finder _named(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

Finder _handle({required bool left}) => find.byWidgetPredicate(
  (widget) =>
      widget.runtimeType.toString() == 'VideoEditorTrimHandle' &&
      (widget as dynamic).isLeft == left,
);

void main() {
  late List<String> log;
  late _Player player;
  late _Editor editor;
  late VideoPlayerPlatform originalPlayer;
  late ProVideoEditor originalEditor;
  late Directory temporary;
  late MediaAccess access;
  final leases = <ManagedMediaFile>[];

  setUp(() async {
    log = [];
    originalPlayer = VideoPlayerPlatform.instance;
    originalEditor = ProVideoEditor.instance;
    editor = _Editor(log);
    VideoPlayerPlatform.instance = player = _Player(log);
    ProVideoEditor.instance = editor;
    temporary = await Directory.systemTemp.createTemp('video-editor-test');
    access = await MediaAccess.open(
      directory: Directory('${temporary.path}/edits'),
    );
  });

  tearDown(() async {
    VideoEditorPage.debugCreateLease = null;
    VideoPlayerPlatform.instance = originalPlayer;
    ProVideoEditor.instance = originalEditor;
    for (final lease in leases) {
      // A close the editor began on the fake clock may never finish here.
      await lease.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    leases.clear();
    await temporary.delete(recursive: true);
  });

  /// Lets real file IO (the lease) and fake time (frames, timers) run.
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens the editor on a phone-sized screen; returns its pending result.
  Future<Future<EditedVideo?>> open(
    WidgetTester tester, {
    bool keepQuality = false,
    int rounds = 20,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final host = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(body: SizedBox.expand(key: host)),
      ),
    );
    // The lease's file IO is real: made here, outside the fake clock.
    final lease = (await tester.runAsync(
      () => access.createWriter(extension: '.mp4'),
    ))!;
    leases.add(lease);
    VideoEditorPage.debugCreateLease = () async => lease;
    final result = showVideoEditor(
      host.currentContext!,
      path: '/fixture/clip.mp4',
      heroTag: 'send-preview-fixture',
      keepQuality: keepQuality,
    );
    await settle(tester, rounds: rounds);
    return result;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 3);
  }

  Future<void> trimEnd(WidgetTester tester) async {
    await tester.drag(_handle(left: false), const Offset(-90, 0));
    await settle(tester, rounds: 4);
  }

  testWidgets('the stage shows the playing video above a usable trim bar', (
    tester,
  ) async {
    await open(tester);
    expect(tester.takeException(), isNull);

    final stage = tester.getRect(find.byKey(const ValueKey('texture')));
    expect(stage.height, greaterThan(300), reason: 'stage $stage');
    expect(stage.width, greaterThan(150), reason: 'stage $stage');
    // Portrait, as the rotation-corrected metadata says.
    expect(stage.height / stage.width, closeTo(1920 / 1080, 0.02));
    expect(log, containsAllInOrder(['looping true', 'volume 1.0', 'play']));

    final bar = tester.getRect(_named('VideoEditorTrimBar'));
    final dock = tester.getRect(find.text('Crop'));
    expect(bar.top, greaterThan(stage.top), reason: 'bar $bar');
    expect(bar.bottom, lessThanOrEqualTo(dock.top), reason: 'bar $bar');
    expect(tester.getRect(_handle(left: false)).bottom, lessThan(dock.top));
    // The bar answers a drag (it would not inside a 0 px tall body).
    await trimEnd(tester);
    expect(tester.getCenter(_handle(left: false)).dx, lessThan(bar.right - 60));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Done without an edit renders nothing and returns null', (
    tester,
  ) async {
    final result = await open(tester);
    // The trim bar reported the whole clip in whole seconds (12 s of 12.7 s)
    // when it set itself up; that is not a trim.
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(editor.renders, isEmpty);
    expect(await result, isNull);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('an end trim and mute render the exact span as a copy, with '
      'the preview decoder freed first', (tester) async {
    final result = await open(tester);

    await trimEnd(tester);
    await tester.tap(find.text('Sound'));
    await settle(tester, rounds: 2);
    expect(log, contains('volume 0.0'));

    await tester.tap(find.text('Done'));
    await settle(tester);

    expect(editor.renders, hasLength(1));
    final data = editor.renders.single;
    expect(data.startTime, isNull);
    final end = data.endTime!;
    expect(end, lessThan(_duration - const Duration(seconds: 1)));
    expect(end, greaterThan(const Duration(seconds: 2)));
    // The drag's exact end, not the bar's whole-second readout.
    expect(end.inMicroseconds % Duration.microsecondsPerSecond, isNot(0));
    expect(data.enableAudio, isFalse);
    // Nothing to re-encode: no scale, bitrate or frame cap, so the samples
    // can be copied.
    expect(data.transform, isNull);
    expect(data.bitrate, isNull);
    expect(data.maxFrameRate, isNull);
    // The paused preview no longer holds a decoder when the render starts.
    expect(log.lastIndexOf('player dispose'), lessThan(log.indexOf('render')));

    final edited = await result;
    expect(edited, isNotNull);
    expect(edited!.path, editor.outputs.single);
    expect(leases.single.file.path, edited.path);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a later start re-encodes at the HD ceiling', (tester) async {
    editor.resolution = const Size(2160, 3840);
    final result = await open(tester);

    await tester.drag(_handle(left: true), const Offset(60, 0));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('Done'));
    await settle(tester);

    final data = editor.renders.single;
    expect(data.startTime, greaterThan(Duration.zero));
    expect(data.endTime, isNull);
    expect(data.transform?.scaleX, closeTo(0.5, 1e-9));
    expect(data.transform?.scaleY, closeTo(0.5, 1e-9));
    expect(data.bitrate, editedVideoBitrate);
    expect(data.maxFrameRate, editedVideoMaxFps);
    expect((await result)?.size, const Size(1080, 1920));
    await close(tester);
  });

  testWidgets('a failed render keeps the editor, brings the preview back '
      'and says why', (tester) async {
    final result = await open(tester);
    var completed = false;
    unawaited(result.then((_) => completed = true));
    editor.onRender = (_) async => throw PlatformException(
      code: 'RENDER_ERROR',
      message: 'Failed to open /data/user/0/app/cache/lease_1_x/media.mp4',
      details: {
        'domain': 'androidx.media3.transformer.ExportException',
        'code': 3001,
        'codeName': 'ERROR_CODE_DECODER_INIT_FAILED',
      },
    );

    await trimEnd(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);

    expect(editor.renders, hasLength(1));
    // On the editor's scaffold (and the covered one below it).
    expect(
      find.text(
        'This video couldn\'t be edited. Try again, or send it as it is.',
      ),
      findsWidgets,
    );
    expect(completed, isFalse);
    expect(find.text('Edit video'), findsOneWidget);
    // A new player is on the stage; the render's lease is gone.
    expect(log.where((entry) => entry == 'player create'), hasLength(2));
    expect(find.byKey(const ValueKey('texture')), findsOneWidget);
    expect(File(editor.outputs.single).existsSync(), isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Cancel stops the render and keeps editing', (tester) async {
    final result = await open(tester);
    var completed = false;
    unawaited(result.then((_) => completed = true));
    final rendering = Completer<void>();
    editor.onRender = (_) => rendering.future;

    await trimEnd(tester);
    await tester.tap(find.text('Done'));
    await settle(tester, rounds: 8);
    expect(find.text('Preparing video…'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    expect(editor.cancelled.single, startsWith('edit-'));
    rendering.completeError(const RenderCanceledException());
    await settle(tester);

    expect(completed, isFalse);
    expect(find.text('Preparing video…'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const ValueKey('texture')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a busy encoder is retried once', (tester) async {
    final result = await open(tester);
    var calls = 0;
    editor.onRender = (_) async {
      if (calls++ == 0) {
        throw const RenderEncoderException.transient('codec reclaimed');
      }
    };

    await trimEnd(tester);
    await tester.tap(find.text('Done'));
    await settle(tester, rounds: 16);

    expect(editor.renders, hasLength(2));
    expect(editor.renders.first.id, isNot(editor.renders.last.id));
    expect(await result, isNotNull);
    await close(tester);
  });

  testWidgets('closing after a trim asks before the trim is lost', (
    tester,
  ) async {
    final result = await open(tester);
    var completed = false;
    unawaited(result.then((_) => completed = true));

    await trimEnd(tester);
    await tester.tap(find.byTooltip('Cancel'));
    await settle(tester, rounds: 4);
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await settle(tester, rounds: 4);
    expect(completed, isFalse);
    expect(find.text('Edit video'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel'));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('Discard'));
    await settle(tester, rounds: 4);
    expect(await result, isNull);
    expect(editor.renders, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Back in Crop returns to the editor', (tester) async {
    final result = await open(tester);
    var completed = false;
    unawaited(result.then((_) => completed = true));

    await tester.tap(find.text('Crop'));
    await settle(tester, rounds: 20);
    expect(tester.takeException(), isNull);
    // The pills drop their labels on a narrow phone.
    final rotate = find.text('Rotate').evaluate().isEmpty
        ? find.byTooltip('Rotate')
        : find.text('Rotate');
    expect(rotate, findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await settle(tester, rounds: 10);
    expect(find.text('Rotate'), findsNothing);
    expect(find.byTooltip('Rotate'), findsNothing);
    expect(find.text('Edit video'), findsOneWidget);
    expect(completed, isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a full-quality render the encoder refuses is retried at '
      'the HD ceiling', (tester) async {
    editor.resolution = const Size(2160, 3840);
    final result = await open(tester, keepQuality: true);
    var calls = 0;
    editor.onRender = (_) async {
      if (calls++ == 0) {
        throw const RenderEncoderException('profile not supported');
      }
    };

    await tester.drag(_handle(left: true), const Offset(60, 0));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('Done'));
    await settle(tester, rounds: 16);

    expect(editor.renders, hasLength(2));
    // Sent as a file: full size, but 30 fps above 1080p.
    expect(editor.renders.first.transform, isNull);
    expect(editor.renders.first.maxFrameRate, editedVideoMaxFps);
    expect(editor.renders.first.bitrate, 17 * 1000 * 1000);
    expect(editor.renders.last.transform?.scaleX, closeTo(0.5, 1e-9));
    expect(editor.renders.last.bitrate, editedVideoBitrate);
    expect((await result)?.size, const Size(1080, 1920));
    await close(tester);
  });

  testWidgets('a loop seek still in flight when Done frees the player is '
      'caught, not reported', (tester) async {
    final result = await open(tester);
    player.seekGate = Completer<void>();

    // The drag's end seeks to the kept start; the seek hangs.
    await trimEnd(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(log.indexOf('render'), greaterThan(log.indexOf('player dispose')));

    player.seekGate!.complete();
    await settle(tester, rounds: 3);
    expect(await result, isNotNull);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a finger down while the trim bar sets itself up is not a '
      'drag', (tester) async {
    final result = await open(tester, rounds: 0);
    // Down on the stage as soon as the editor is there, before its trim
    // bar reports the whole clip.
    for (var i = 0; i < 20 && find.text('Edit video').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_named('VideoEditorTrimBar'), findsNothing);
    final finger = await tester.startGesture(
      tester.getCenter(find.text('Edit video')) + const Offset(0, 200),
    );
    await settle(tester, rounds: 20);
    expect(_named('VideoEditorTrimBar'), findsOneWidget);
    // Playing, not paused by a "drag".
    expect(log.sublist(log.lastIndexOf('play')), isNot(contains('pause')));
    await finger.up();
    await settle(tester, rounds: 2);

    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(editor.renders, isEmpty);
    expect(await result, isNull);
    await close(tester);
  });

  testWidgets('a handle stopped a frame short of the end is no trim', (
    tester,
  ) async {
    final result = await open(tester);

    await tester.drag(_handle(left: false), const Offset(-90, 0));
    await settle(tester, rounds: 4);
    await tester.drag(_handle(left: false), const Offset(89.6, 0));
    await settle(tester, rounds: 4);
    // No "Discard changes?" for what Done would not render.
    await tester.tap(find.byTooltip('Cancel'));
    await settle(tester, rounds: 4);
    expect(find.text('Discard changes?'), findsNothing);
    expect(await result, isNull);
    expect(editor.renders, isEmpty);
    await close(tester);
  });

  test('a failure is logged with its codes and without paths', () {
    final text = describeVideoEditFailure(
      PlatformException(
        code: 'RENDER_ERROR',
        message: 'open failed: /storage/emulated/0/DCIM/Anna birthday.mp4',
        details: {
          'domain': 'androidx.media3.transformer.ExportException',
          'code': 3001,
          'codeName': 'ERROR_CODE_DECODER_INIT_FAILED',
          'cause': 'java.io.FileNotFoundException: /data/user/0/a/b.mp4',
          'sources': [
            {'mime': 'video/hevc', 'bitDepth': 10, 'transfer': 'HLG'},
          ],
        },
      ),
    );
    expect(text, contains('RENDER_ERROR'));
    expect(text, contains('ERROR_CODE_DECODER_INIT_FAILED'));
    expect(text, contains('video/hevc 10-bit HLG'));
    expect(text, isNot(contains('/storage')));
    expect(text, isNot(contains('/data')));
    expect(text, isNot(contains('Anna')));
    expect(text, isNot(contains('birthday')));
  });
}
