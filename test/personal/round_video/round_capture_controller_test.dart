// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/round_video/round_capture_backend.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/round_media_preparer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCapture implements RoundCaptureBackend {
  final eventController = StreamController<RoundCaptureNativeEvent>.broadcast();
  Completer<RoundCapturePreview>? pendingInitialize;
  Completer<void>? pendingStart;
  Completer<PreparedRoundMedia>? pendingFinish;
  Completer<void>? pendingPause;
  Completer<RoundCapturePreview>? pendingSwitch;
  Completer<RoundCapturePreview>? pendingZoom;
  Completer<RoundCapturePreview>? pendingTorch;
  final operations = <String>[];
  final zoomRequests = <double>[];
  final cameraRevisions = <int>[];
  RoundCapturePreview previewValue = capturePreview();
  PreparedRoundMedia? media;
  int finishCalls = 0;
  int cancelCalls = 0;
  bool kept = false;
  bool trimFails = false;
  bool resumeError = false;
  @override
  Stream<RoundCaptureNativeEvent> get events => eventController.stream;
  @override
  Future<RoundCapturePreview> initialize(RoundCaptureProfile profile) async =>
      pendingInitialize?.future ?? previewValue;
  @override
  Future<void> start() async {
    operations.add('start');
    await pendingStart?.future;
  }

  @override
  Future<void> pause() async {
    operations.add('pause');
    await pendingPause?.future;
  }

  @override
  Future<void> resume() async {
    operations.add('resume');
    if (resumeError) throw const RoundCaptureException('interrupted');
  }

  @override
  Future<PreparedRoundMedia> finish() async {
    finishCalls++;
    operations.add('finish');
    return pendingFinish?.future ?? media!;
  }

  @override
  Future<PreparedRoundMedia> trim(int startMs, int endMs) async {
    if (trimFails) throw const RoundCaptureException('trim_failed');
    return media!;
  }

  @override
  Future<RoundCapturePreview> switchCamera({
    required int cameraRevision,
  }) async {
    operations.add('switch');
    cameraRevisions.add(cameraRevision);
    return pendingSwitch?.future ?? previewValue;
  }

  @override
  Future<RoundCapturePreview> setZoom(
    double zoom, {
    required int cameraRevision,
  }) async {
    operations.add('zoom');
    cameraRevisions.add(cameraRevision);
    zoomRequests.add(zoom);
    return pendingZoom?.future ?? capturePreview(available: true, zoom: zoom);
  }

  @override
  Future<RoundCapturePreview> setTorch(
    bool enabled, {
    required int cameraRevision,
  }) async {
    operations.add('torch');
    cameraRevisions.add(cameraRevision);
    return pendingTorch?.future ??
        capturePreview(available: true, torchEnabled: enabled);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose({bool keepPrepared = false}) async {
    kept = keepPrepared;
    await eventController.close();
  }
}

RoundCapturePreview capturePreview({
  bool available = false,
  int revision = 1,
  double zoom = 1,
  bool torchEnabled = false,
}) => RoundCapturePreview(
  textureId: 1,
  width: 640,
  height: 480,
  rotation: 90,
  mirrored: true,
  canSwitchDuringRecording: available,
  canSwitchCamera: available,
  minZoom: 1,
  maxZoom: available ? 4 : 1,
  zoom: zoom,
  torchAvailable: available,
  torchEnabled: torchEnabled,
  cameraRevision: revision,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const profile = RoundCaptureProfile(maxBytes: 25000000);
  testWidgets('paused capture has no periodic UI wakeups and resume restarts it', (
    tester,
  ) async {
    final backend = FakeCapture();
    final controller = RoundCaptureController(backend: backend, profile: profile);
    addTearDown(controller.dispose);
    var changes = 0;
    controller.addListener(() => changes++);
    await controller.initialize();
    await controller.start();
    await tester.pump(const Duration(milliseconds: 200));
    await controller.pause();
    final pausedChanges = changes;
    await tester.pump(const Duration(seconds: 5));
    expect(changes, pausedChanges);
    await controller.resume();
    final resumedChanges = changes;
    await tester.pump(const Duration(milliseconds: 200));
    expect(changes, greaterThan(resumedChanges));
    await controller.cancel();
  });
  test(
    'Dart and native share the narrow-range zoom availability threshold',
    () {
      const narrow = RoundCapturePreview(
        textureId: 1,
        width: 384,
        height: 384,
        rotation: 0,
        mirrored: false,
        canSwitchDuringRecording: false,
        minZoom: 1,
        maxZoom: 1.00001,
      );
      expect(narrow.canZoom, isFalse);
      expect(capturePreview(available: true).canZoom, isTrue);
    },
  );
  test(
    'recoverable transition interruption waits for native export before any event',
    () async {
      for (final phase in ['start', 'pause', 'resume']) {
        final backend = FakeCapture()
          ..pendingStart = phase == 'start' ? Completer() : null
          ..pendingPause = phase == 'pause' ? Completer() : null;
        final controller = RoundCaptureController(
          backend: backend,
          profile: profile,
        );
        await controller.initialize();
        Future<void> transition;
        if (phase == 'start') {
          transition = controller.start();
          backend.pendingStart!.completeError(
            const RoundCaptureException('interrupted'),
          );
        } else {
          await controller.start();
          if (phase == 'pause') {
            transition = controller.pause();
            backend.pendingPause!.completeError(
              const RoundCaptureException('interrupted'),
            );
          } else {
            await controller.pause();
            backend.resumeError = true;
            transition = controller.resume();
          }
        }
        await transition;
        expect(controller.state, RoundCaptureState.preparing, reason: phase);
        expect(controller.wasInterrupted, isTrue, reason: phase);
        expect(controller.locked, isTrue, reason: phase);
        expect(controller.errorCode, isNull, reason: phase);
        expect(controller.isFinalizing, isTrue, reason: phase);
        await controller.interrupt();
        expect(
          backend.cancelCalls,
          0,
          reason: 'A lock must preserve native export bytes during $phase',
        );
        await controller.cancel();
        controller.dispose();
      }
    },
  );
  test(
    'ready lens switch blocks start until new capabilities are applied',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true)
        ..pendingSwitch = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      final switching = controller.switchCamera();
      await controller.start();
      expect(controller.state, RoundCaptureState.ready);
      expect(backend.operations, ['switch']);
      backend.pendingSwitch!.complete(
        capturePreview(available: true, revision: 2),
      );
      await switching;
      await controller.start();
      expect(controller.state, RoundCaptureState.recording);
      expect(controller.preview!.cameraRevision, 2);
      await controller.cancel();
      controller.dispose();
    },
  );
  test(
    'stale controls events never replace newer camera availability',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true, revision: 2);
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      backend.eventController.add(
        const RoundCaptureNativeEvent('controls', {
          'textureId': 1,
          'width': 640,
          'height': 480,
          'rotation': 0,
          'cameraRevision': 1,
          'canSwitchCamera': false,
          'minZoom': 1,
          'maxZoom': 1,
          'zoom': 1,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.preview!.cameraRevision, 2);
      expect(controller.canZoom, isTrue);
      await controller.cancel();
      controller.dispose();
    },
  );
  test('native preparing invalidates a late start result', () async {
    final backend = FakeCapture()..pendingStart = Completer();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    await controller.initialize();
    final start = controller.start();
    backend.eventController.add(const RoundCaptureNativeEvent('preparing', {}));
    await Future<void>.delayed(Duration.zero);
    backend.pendingStart!.complete();
    await start;
    expect(controller.state, RoundCaptureState.preparing);
    expect(controller.active, isFalse);
    await controller.cancel();
    controller.dispose();
  });
  test(
    'backend rejects finish response after cancel before parsing its closed lease',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round-finish-lease-race-',
      );
      const channel = MethodChannel('round-finish-lease-race-test');
      final pending = Completer<Map<Object?, Object?>>();
      final args = <String, Map<Object?, Object?>>{};
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            args[call.method] = Map<Object?, Object?>.from(
              call.arguments as Map,
            );
            if (call.method == 'initialize') {
              return {
                'captureId': args[call.method]!['captureId'],
                'textureId': 1,
                'width': 640,
                'height': 480,
                'rotation': 0,
                'cameraRevision': 1,
                'minZoom': 1,
                'maxZoom': 1,
                'zoom': 1,
              };
            }
            if (call.method == 'finish') return pending.future;
            return null;
          });
      try {
        final access = await MediaAccess.open(directory: directory);
        final backend = AndroidRoundCaptureBackend(access, channel: channel);
        await backend.initialize(profile);
        final finish = backend.finish();
        final assertion = expectLater(
          finish,
          throwsA(
            isA<RoundCaptureException>().having(
              (e) => e.code,
              'code',
              'canceled',
            ),
          ),
        );
        await backend.cancel();
        pending.complete({'captureId': args['initialize']!['captureId']});
        await assertion;
        await backend.dispose();
        expect(
          args.values.map((value) => value['captureId']).toSet().length,
          1,
        );
        expect(await directory.list().length, 0);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'backend session token filters a prior recorder event at the shared channel',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round-event-epoch-',
      );
      const channel = MethodChannel('round-event-epoch-test');
      final ids = <String>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'initialize') {
          ids.add(args['captureId'] as String);
          return {
            'captureId': ids.last,
            'textureId': 1,
            'width': 640,
            'height': 480,
            'rotation': 0,
          };
        }
        return null;
      });
      Future<void> emit(String id) async {
        final completion = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('event', {'captureId': id, 'type': 'controls'}),
          ),
          (_) => completion.complete(),
        );
        await completion.future;
      }

      try {
        final access = await MediaAccess.open(directory: directory);
        final old = AndroidRoundCaptureBackend(access, channel: channel);
        await old.initialize(profile);
        await old.dispose();
        final current = AndroidRoundCaptureBackend(access, channel: channel);
        await current.initialize(profile);
        final events = <RoundCaptureNativeEvent>[];
        final subscription = current.events.listen(events.add);
        await emit(ids.first);
        await emit(ids.last);
        await Future<void>.delayed(Duration.zero);
        expect(ids[0], isNot(ids[1]));
        expect(events.length, 1);
        expect(events.single.data['captureId'], ids.last);
        await subscription.cancel();
        await current.dispose();
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
  test('unavailable camera controls never reach native hardware', () async {
    final backend = FakeCapture();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    await controller.initialize();
    expect(controller.canSwitchCamera, isFalse);
    expect(controller.canZoom, isFalse);
    expect(controller.canSetTorch, isFalse);
    await controller.switchCamera();
    await controller.setZoom(2);
    await controller.setTorch(true);
    expect(backend.operations, isEmpty);
    await controller.cancel();
    controller.dispose();
  });
  test(
    'switch during recording and pause revalidates per-camera controls',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true);
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start(lock: true);
      await controller.switchCamera();
      expect(controller.state, RoundCaptureState.recording);
      await controller.pause();
      final duration = controller.duration;
      backend.previewValue = capturePreview(revision: 2);
      await controller.switchCamera();
      expect(controller.state, RoundCaptureState.paused);
      expect(controller.duration, duration);
      expect(controller.locked, isTrue);
      expect(controller.canZoom, isFalse);
      expect(controller.canSetTorch, isFalse);
      await controller.setTorch(true);
      expect(backend.cameraRevisions, [1, 1]);
      expect(backend.operations, ['start', 'switch', 'pause', 'switch']);
      await controller.cancel();
      controller.dispose();
    },
  );
  test(
    'duplicate switch and pause serialize; cancel wins the late camera',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true)
        ..pendingSwitch = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start();
      final switching = controller.switchCamera();
      await controller.switchCamera();
      final pausing = controller.pause();
      await controller.pause();
      expect(backend.operations, ['start', 'switch']);
      await controller.cancel();
      backend.pendingSwitch!.complete(
        capturePreview(available: true, revision: 2),
      );
      await switching;
      await pausing;
      expect(controller.state, RoundCaptureState.canceled);
      expect(controller.preview, isNull);
      expect(backend.operations, ['start', 'switch']);
      controller.dispose();
    },
  );
  test('failed switch preserves active draft and permits retry', () async {
    final backend = FakeCapture()
      ..previewValue = capturePreview(available: true)
      ..pendingSwitch = Completer();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    await controller.initialize();
    await controller.start();
    final switching = controller.switchCamera();
    backend.pendingSwitch!.completeError(
      const RoundCaptureException('camera_switch_failed'),
    );
    await switching;
    expect(controller.state, RoundCaptureState.recording);
    expect(controller.errorCode, isNull);
    expect(controller.controlErrorCode, 'camera_switch_failed');
    expect(controller.canSwitchCamera, isTrue);
    await controller.cancel();
    controller.dispose();
  });
  test(
    'rapid zoom coalesces targets, clamps range and rejects non-finite input',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true)
        ..pendingZoom = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      final first = controller.setZoom(2);
      final middle = controller.setZoom(3);
      final latest = controller.setZoom(9);
      await controller.setZoom(double.nan);
      expect(identical(first, middle), isTrue);
      expect(identical(first, latest), isTrue);
      expect(backend.zoomRequests, [2]);
      final pending = backend.pendingZoom!;
      backend.pendingZoom = null;
      pending.complete(capturePreview(available: true, zoom: 2));
      await latest;
      expect(backend.zoomRequests, [2, 4]);
      expect(controller.preview!.zoom, 4);
      expect(controller.controlsBusy, isFalse);
      await controller.cancel();
      controller.dispose();
    },
  );
  test('finish preempts camera control and ignores its late preview', () async {
    final backend = FakeCapture()
      ..previewValue = capturePreview(available: true)
      ..pendingTorch = Completer()
      ..pendingFinish = Completer();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    await controller.initialize();
    await controller.start();
    final torch = controller.setTorch(true);
    final finish = controller.finish();
    expect(controller.state, RoundCaptureState.preparing);
    expect(backend.finishCalls, 1);
    backend.pendingTorch!.complete(
      capturePreview(available: true, torchEnabled: true),
    );
    await torch;
    await Future<void>.delayed(Duration.zero);
    expect(backend.operations, ['start', 'torch', 'finish']);
    expect(controller.preview!.torchEnabled, isFalse);
    await controller.cancel();
    backend.pendingFinish!.completeError(
      const RoundCaptureException('canceled'),
    );
    await finish;
    controller.dispose();
  });
  test(
    'interruption with pending switch freezes hold send and preempts finish',
    () async {
      final backend = FakeCapture()
        ..previewValue = capturePreview(available: true)
        ..pendingSwitch = Completer()
        ..pendingFinish = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start();
      final switching = controller.switchCamera();
      final interruption = controller.interrupt();
      expect(controller.wasInterrupted, isTrue);
      expect(controller.locked, isTrue);
      expect(backend.finishCalls, 1);
      backend.pendingSwitch!.complete(
        capturePreview(available: true, revision: 2),
      );
      await switching;
      await Future<void>.delayed(Duration.zero);
      expect(backend.finishCalls, 1);
      expect(controller.preview!.cameraRevision, 1);
      await controller.cancel();
      backend.pendingFinish!.completeError(
        const RoundCaptureException('canceled'),
      );
      await interruption;
      controller.dispose();
    },
  );
  test(
    'concurrent and later backend disposal share one native cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round-dispose-race-',
      );
      const channel = MethodChannel('round-capture-disposal-test');
      final nativeDispose = Completer<void>();
      var disposals = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'dispose');
            disposals++;
            await nativeDispose.future;
            return null;
          });
      try {
        final access = await MediaAccess.open(directory: directory);
        final backend = AndroidRoundCaptureBackend(access, channel: channel);
        final first = backend.dispose(keepPrepared: true);
        final second = backend.dispose();
        expect(identical(first, second), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(disposals, 1);
        nativeDispose.complete();
        await first;
        await second;
        await backend.dispose();
        expect(disposals, 1);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'Android capture accepts the 800ms profile boundary and rejects 799ms',
    () {
      expect(
        const RoundCaptureProfile(
          maxBytes: 25000000,
          maxDurationMs: 799,
        ).isValid,
        isFalse,
      );
      expect(
        const RoundCaptureProfile(
          maxBytes: 25000000,
          maxDurationMs: 800,
        ).isValid,
        isTrue,
      );
      expect(RoundCaptureController.minimumDurationMs, 800);
    },
  );
  test(
    'backend cancel during writer allocation never requests camera permission later',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round-writer-race-',
      );
      const channel = MethodChannel('round-capture-allocation-test');
      final methods = <String>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            return null;
          });
      try {
        final access = await MediaAccess.open(directory: directory);
        final backend = AndroidRoundCaptureBackend(access, channel: channel);
        final initialize = backend.initialize(profile);
        final cancel = backend.cancel();
        await expectLater(initialize, throwsA(isA<RoundCaptureException>()));
        await cancel;
        expect(methods, isNot(contains('initialize')));
        expect(await directory.list().length, 0);
        await backend.dispose();
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'original hold release and cancel cannot resurrect after permission setup',
    () {
      final release = RoundCaptureGestureController(held: true)..release();
      release.begin();
      expect(release.phase, RoundCaptureGesturePhase.released);
      final cancel = RoundCaptureGestureController(held: true)
        ..move(dx: -81, dy: 0)
        ..release();
      expect(cancel.phase, RoundCaptureGesturePhase.canceled);
      release.dispose();
      cancel.dispose();
    },
  );
  test(
    'gesture lock survives original release and thresholds are deliberate',
    () {
      final gesture = RoundCaptureGestureController(held: true)
        ..move(dx: -80, dy: -80);
      expect(gesture.phase, RoundCaptureGesturePhase.holding);
      gesture.move(dx: 0, dy: -81);
      gesture.release();
      expect(gesture.phase, RoundCaptureGesturePhase.locked);
      gesture.cancel();
      expect(gesture.phase, RoundCaptureGesturePhase.canceled);
      gesture.dispose();
    },
  );
  test(
    'recording lock is idempotent and cannot recurse through listeners',
    () async {
      final backend = FakeCapture();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start();
      var changes = 0;
      controller.addListener(() {
        changes++;
        controller.lock();
      });
      controller.lock();
      expect(changes, 1);
      await controller.cancel();
      controller.dispose();
    },
  );
  test(
    'duration limit always disables held-release send and enters review preparation',
    () async {
      final backend = FakeCapture()..pendingFinish = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: const RoundCaptureProfile(
          maxBytes: 25000000,
          maxDurationMs: 10,
        ),
      );
      await controller.initialize();
      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(controller.wasInterrupted, isTrue);
      expect(controller.locked, isTrue);
      expect(controller.state, RoundCaptureState.preparing);
      expect(backend.finishCalls, 1);
      await controller.cancel();
      backend.pendingFinish!.completeError(
        const RoundCaptureException('canceled'),
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
    },
  );
  test('cancellation during permission setup rejects late ready', () async {
    final backend = FakeCapture()..pendingInitialize = Completer();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    final init = controller.initialize();
    await controller.cancel();
    backend.pendingInitialize!.complete(
      const RoundCapturePreview(
        textureId: 1,
        width: 640,
        height: 480,
        rotation: 0,
        mirrored: false,
        canSwitchDuringRecording: false,
      ),
    );
    await init;
    expect(controller.state, RoundCaptureState.canceled);
    expect(controller.preview, isNull);
    controller.dispose();
  });
  test('late capture start cannot undo cancellation', () async {
    final backend = FakeCapture()..pendingStart = Completer();
    final controller = RoundCaptureController(
      backend: backend,
      profile: profile,
    );
    await controller.initialize();
    final start = controller.start();
    await controller.cancel();
    backend.pendingStart!.complete();
    await start;
    expect(controller.state, RoundCaptureState.canceled);
    expect(controller.active, isFalse);
    controller.dispose();
  });
  test(
    'pause duration, lock and app interruption do not auto resume',
    () async {
      final backend = FakeCapture()..pendingFinish = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start();
      await controller.pause();
      final duration = controller.duration;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.duration, duration);
      expect(controller.locked, isTrue);
      final interruption = RoundCaptureController.interruptActive();
      expect(controller.wasInterrupted, isTrue);
      expect(controller.state, RoundCaptureState.preparing);
      await controller.cancel();
      backend.pendingFinish!.completeError(
        const RoundCaptureException('canceled'),
      );
      await interruption;
      expect(controller.state, RoundCaptureState.canceled);
      controller.dispose();
    },
  );
  test(
    'concurrent finishes share one operation and cancellation wins late output',
    () async {
      final backend = FakeCapture()..pendingFinish = Completer();
      final controller = RoundCaptureController(
        backend: backend,
        profile: profile,
      );
      await controller.initialize();
      await controller.start(lock: true);
      final first = controller.finish();
      final second = controller.finish();
      expect(identical(first, second), isTrue);
      expect(backend.finishCalls, 1);
      await controller.cancel();
      backend.pendingFinish!.completeError(
        const RoundCaptureException('canceled'),
      );
      await first;
      expect(controller.state, RoundCaptureState.canceled);
      controller.dispose();
    },
  );
  test(
    'prepared codec metadata and paths fail closed; lease transfers once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round-dart-fixture-',
      );
      try {
        final access = await MediaAccess.open(directory: directory);
        final lease = await access.createWriter(extension: '.mp4');
        final valid = <Object?, Object?>{
          'path': lease.file.path,
          'thumbnailPath': '${lease.writableDirectory}/thumb.jpg',
          'width': 384,
          'height': 384,
          'durationMs': 1200,
          'sizeBytes': 10000,
          'videoCodec': 'h264',
          'audioCodec': 'aac',
          'cornersSanitized': true,
          'fastStart': true,
        };
        PreparedRoundMedia parse(Map<Object?, Object?> map) =>
            PreparedRoundMedia.fromNative(
              map,
              lease,
              maxBytes: 25000000,
              maxDurationMs: 60000,
              maxSide: 640,
            );
        for (final change in <Map<Object?, Object?>>[
          {'cornersSanitized': false},
          {'fastStart': false},
          {'videoCodec': 'hevc'},
          {'audioCodec': 'opus'},
          {'durationMs': 60001},
          {'durationMs': 799},
          {'width': 641},
          {'height': 383},
          {'sizeBytes': 25000001},
          {'path': '/arbitrary.mp4'},
          {'thumbnailPath': '/arbitrary.jpg'},
        ]) {
          expect(
            () => parse({...valid, ...change}),
            throwsA(isA<RoundCaptureException>()),
          );
        }
        expect(parse({...valid, 'durationMs': 800}).durationMs, 800);
        final backend = FakeCapture()..media = parse(valid);
        final controller = RoundCaptureController(
          backend: backend,
          profile: profile,
        );
        await controller.initialize();
        await controller.start();
        await controller.finish();
        backend.trimFails = true;
        await controller.trim(0, 1000);
        expect(controller.state, RoundCaptureState.review);
        expect(controller.controlErrorCode, 'trim_failed');
        expect(controller.prepared, same(backend.media));
        backend.eventController.add(
          const RoundCaptureNativeEvent('error', {
            'code': 'camera_unavailable',
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.state, RoundCaptureState.review);
        expect(controller.prepared, same(backend.media));
        final media = controller.takePrepared();
        expect(
          () => controller.takePrepared(),
          throwsA(isA<RoundCaptureException>()),
        );
        controller.dispose();
        expect(backend.kept, isTrue);
        await media.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
