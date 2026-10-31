// Offline platform fixtures: no microphone, native encoder, files or account.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/recording_input_row.dart';
import 'package:chatloom/pages/chat/recording_view_model.dart';
import 'package:chatloom/pages/chat/recording_waveform.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/voice_format.dart';
import 'package:chatloom/personal/media/voice_remux.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart'
    show wakelockPlusPlatformInstance;
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'outgoing_media_support.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No account access');
}

class _Client extends Client {
  _Client() : super('offline recorder fixture', database: _NoDatabase());
  @override
  String get userID => '@owner:example.invalid';
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig();
}

class _Paths extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => '/offline-recorder-fixture';
}

class _Wake extends WakelockPlusPlatformInterface {
  final values = <bool>[];
  @override
  Future<void> toggle({required bool enable}) async => values.add(enable);
}

class _Record extends RecordPlatform {
  int creates = 0,
      disposals = 0,
      starts = 0,
      stops = 0,
      samples = 0,
      pauses = 0;
  bool permission = true;
  bool nativePaused = false;
  RecordConfig? lastConfig;
  Object? startFailure;

  /// The macOS encoder cannot be set up for Opus (start throws).
  bool rejectOpus = false;
  String? outputPath;
  String stopOutput = '/offline-recorder-fixture/voice.ogg';
  final operations = <String>[];
  Completer<bool>? permissionGate;
  Completer<void>? startGate;
  Completer<Amplitude>? amplitudeGate;
  final states = StreamController<RecordState>.broadcast();
  final disposed = Completer<void>();

  @override
  Future<void> create(String recorderId) async => creates++;
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      permissionGate?.future ?? permission;
  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;
  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    starts++;
    operations.add('start');
    outputPath = path;
    lastConfig = config;
    await startGate?.future;
    if (startFailure != null) throw startFailure!;
    if (rejectOpus && config.encoder == AudioEncoder.opus) {
      throw StateError('Format conversion is not possible');
    }
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => states.stream;
  @override
  Future<Amplitude> getAmplitude(String recorderId) async {
    samples++;
    return amplitudeGate?.future ?? Amplitude(current: -20, max: 0);
  }

  @override
  Future<void> pause(String recorderId) async {
    pauses++;
    nativePaused = true;
  }

  @override
  Future<void> resume(String recorderId) async => nativePaused = false;
  @override
  Future<bool> isPaused(String recorderId) async => nativePaused;
  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    operations.add('stop');
    return stopOutput;
  }

  @override
  Future<void> cancel(String recorderId) async {
    operations.add('cancel');
  }

  @override
  Future<void> dispose(String recorderId) async {
    disposals++;
    operations.add('dispose');
    if (!disposed.isCompleted) disposed.complete();
  }

  void completePending() {
    final permission = permissionGate;
    if (permission != null && !permission.isCompleted) {
      permission.complete(false);
    }
    final starting = startGate;
    if (starting != null && !starting.isCompleted) starting.complete();
    final amplitude = amplitudeGate;
    if (amplitude != null && !amplitude.isCompleted) {
      amplitude.complete(Amplitude(current: -20, max: 0));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected recorder call');
}

class _VoiceRoom extends Room {
  int sends = 0;
  bool simulateFirstAckLoss = false, nullFirstAck = false;
  final transactions = <String?>[];
  final fileNames = <String>[];
  final committed = <String, String>{};
  Event? sentReply;
  String? sentThread, sentLastThread;
  Completer<String?>? sendGate;
  _VoiceRoom(Client client, String id) : super(id: id, client: client);
  @override
  bool get canSendDefaultMessages => true;
  @override
  Future<Event?> getEventById(String eventID) async => null;
  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    sends++;
    transactions.add(txid);
    fileNames.add(file.name);
    sentReply = inReplyTo;
    sentThread = threadRootEventId;
    sentLastThread = threadLastEventId;
    if (simulateFirstAckLoss) {
      // Model Matrix's idempotent room + transaction endpoint: acceptance can
      // precede a lost/null response, but a retry with the same txid is one event.
      final key = txid ?? 'implicit-$sends';
      final eventId = committed.putIfAbsent(
        key,
        () => '\$committed-${committed.length}',
      );
      if (sends == 1) {
        if (nullFirstAck) return null;
        throw TimeoutException('Synthetic lost acknowledgement');
      }
      return eventId;
    }
    return sendGate?.future ?? r'$accepted-voice';
  }
}

class _VoiceController extends ChatController {
  _VoiceRoom target;
  late BuildContext viewContext;
  bool alive = true;
  _VoiceController(this.target) {
    sendingClient = target.client;
  }
  @override
  Room get room => target;
  @override
  bool get mounted => alive;
  @override
  BuildContext get context => viewContext;
  @override
  String? get threadLastEventId => r'$last-thread-event';
  @override
  void setState(VoidCallback fn) => fn();
}

class _VoiceMatrix extends MatrixState {
  final Client initial;
  Client active;
  final SharedPreferences preferences;
  _VoiceMatrix(this.initial, this.preferences) : active = initial;
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [initial], store: preferences);
}

void testWithDeadline(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      timeout: const Timeout(Duration(seconds: 30)),
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  late _Record platform;
  late _Wake wake;
  late RecordPlatform originalRecord;
  late PathProviderPlatform originalPaths;
  late WakelockPlusPlatformInterface originalWake;
  late WakelockPlusPlatformInterface originalWakeFacade;
  final cleanedOutputs = <({String? nativePath, String? blobUrl})>[];
  setUp(() {
    cleanedOutputs.clear();
    originalRecord = RecordPlatform.instance;
    originalPaths = PathProviderPlatform.instance;
    originalWake = WakelockPlusPlatformInterface.instance;
    originalWakeFacade = wakelockPlusPlatformInstance;
    RecordPlatform.instance = platform = _Record();
    PathProviderPlatform.instance = _Paths();
    WakelockPlusPlatformInterface.instance = wake = _Wake();
    // The package caches its own facade separately from the platform singleton.
    wakelockPlusPlatformInstance = wake;
  });
  tearDown(() async {
    PersonalPrivacy.surfaceUnlocked = true;
    await platform.states.close();
    VoiceRecordingPlan.appleOpusFailed = false;
    RecordPlatform.instance = originalRecord;
    PathProviderPlatform.instance = originalPaths;
    WakelockPlusPlatformInterface.instance = originalWake;
    wakelockPlusPlatformInstance = originalWakeFacade;
  });

  Future<void> drainNativeLifecycle(
    WidgetTester tester,
    bool Function() completed,
  ) async {
    // Completed SDK/plugin futures can originate from the root zone, whereas
    // their continuations and semaphore waiters belong to FakeAsync. Drive both
    // event queues until the explicit native barrier completes. This advances
    // no recording time and does not rely on a wall-clock settling duration.
    for (var turn = 0; turn < 32 && !completed(); turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(Duration.zero);
    }
    expect(
      completed(),
      isTrue,
      reason:
          'Native lifecycle did not settle: starts=${platform.starts}, '
          'stops=${platform.stops}, disposals=${platform.disposals}',
    );
  }

  Future<(RecordingViewModelState, Room)> mount(
    WidgetTester tester, {
    void Function()? onBuild,
    VoiceRemux? remux,
  }) async {
    final key = GlobalKey<RecordingViewModelState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: RecordingViewModel(
            key: key,
            remuxOutput: remux,
            cleanupOutput: ({ownedNativePath, stoppedBlobUrl}) async {
              cleanedOutputs.add((
                nativePath: ownedNativePath,
                blobUrl: stoppedBlobUrl,
              ));
            },
            builder: (_, _) {
              onBuild?.call();
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    addTearDown(() {
      // Flutter's binding owns widget teardown. Pumping here occurs after the
      // fake test body ended and can leave a guarded pump waiting forever.
      if (state.mounted) state.cancel();
      platform.completePending();
    });
    return (state, Room(id: '!fixture:example.invalid', client: _Client()));
  }

  Future<void> start(RecordingViewModelState state, Room room) async {
    await state.startRecording(room);
    expect(platform.starts, 1);
    expect(state.isRecording, isTrue);
    expect(state.controlsBusy, isFalse);
    expect(wake.values, [true]);
  }

  late FakeEchoes echoes;
  Future<(_VoiceController, _VoiceMatrix)> mountSend(
    WidgetTester tester,
  ) async {
    echoes = OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final client = _Client();
    final target = _VoiceRoom(client, '!voice:example.invalid');
    final control = _VoiceController(target);
    final matrix = _VoiceMatrix(client, await SharedPreferences.getInstance());
    control.activeThreadId = r'$thread';
    control.replyEvent = Event(
      room: target,
      eventId: r'$reply',
      type: EventTypes.Message,
      senderId: '@fixture:example.invalid',
      originServerTs: DateTime.utc(2026),
      content: const {'msgtype': MessageTypes.Text, 'body': 'Synthetic reply'},
    );
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: const [Locale('en')],
          home: Scaffold(
            body: Builder(
              builder: (context) {
                control.viewContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(control.sendController.dispose);
    addTearDown(control.scrollController.dispose);
    return (control, matrix);
  }

  for (final nullAck in [false, true]) {
    testWithDeadline(
      'voice ${nullAck ? 'null' : 'lost'} ACK stays in its bubble; Retry commits one event with the original SDK transaction',
      (tester) async {
        final (control, _) = await mountSend(tester);
        final target = control.target
          ..simulateFirstAckLoss = true
          ..nullFirstAck = nullAck;
        Future<bool> send() => control.onVoiceMessageSend(
          '/stopped-voice',
          1000,
          const [1024],
          'voice.ogg',
          confirmTrust: (_) async => true,
          readRecording: (_) async => Uint8List.fromList([0]),
        );
        // The bubble is in the chat: the recorder is free at once.
        expect(await send(), isTrue);
        await tester.pump();
        expect(target.committed.length, 1);
        final txid = target.transactions.single!;
        expect(echoes.statusOf(txid), EventStatus.error.intValue);
        // Retry from the bubble: same transaction, still one event.
        final failed = Event.fromMatrixEvent(echoes.events[txid]!, target);
        final again = await OutgoingMedia.retry(failed);
        await tester.pump();
        expect(await again.accepted, startsWith(r'$committed'));
        expect(target.sends, 2);
        expect(target.transactions[1], txid);
        expect(target.fileNames[1], target.fileNames.first);
        expect(target.committed.length, 1);
        // A duplicate completion callback after the composer cleared is a
        // tombstone hit, never a second message.
        expect(await send(), isTrue);
        expect(target.sends, 2);
      },
    );
  }

  testWithDeadline(
    'a voice draft whose bubble could not be stored retries with the same transaction',
    (tester) async {
      final (control, _) = await mountSend(tester);
      final target = control.target;
      echoes.failWriteNumber = 1;
      Future<bool> send() => control.onVoiceMessageSend(
        '/stopped-voice',
        1000,
        const [1024],
        'voice.ogg',
        confirmTrust: (_) async => true,
        readRecording: (_) async => Uint8List.fromList([0]),
      );
      expect(await send(), isFalse, reason: 'the draft stays in the recorder');
      expect(target.sends, 0);
      expect(await send(), isTrue);
      await tester.pump();
      expect(target.sends, 1);
      expect(echoes.events.keys.single, target.transactions.single);
    },
  );

  for (final change in ['room', 'reply', 'thread', 'account', 'bytes']) {
    testWithDeadline(
      'an unstored voice draft cannot be sent after changing $change',
      (tester) async {
        final (control, matrix) = await mountSend(tester);
        final target = control.target;
        echoes.failWriteNumber = 1;
        var bytes = Uint8List.fromList([0]);
        Future<bool> send() => control.onVoiceMessageSend(
          '/stopped-voice',
          1000,
          const [1024],
          'voice.ogg',
          confirmTrust: (_) async => true,
          readRecording: (_) async => bytes,
        );
        expect(await send(), isFalse);
        switch (change) {
          case 'room':
            control.target = _VoiceRoom(
              target.client,
              '!another:example.invalid',
            );
          case 'reply':
            control.replyEvent = null;
          case 'thread':
            control.activeThreadId = r'$another-thread';
          case 'account':
            matrix.active = _Client();
          case 'bytes':
            bytes = Uint8List.fromList([1]);
        }
        expect(await send(), isFalse);
        await tester.pump();
        expect(target.sends, 0);
        expect(echoes.events, isEmpty);
        if (!identical(control.target, target)) {
          expect(control.target.sends, 0);
        }
      },
    );
  }

  testWithDeadline(
    'voice controller returns false when trust is canceled without reading or sending',
    (tester) async {
      final (control, _) = await mountSend(tester);
      var reads = 0;
      final sent = await control.onVoiceMessageSend(
        '/unused',
        1000,
        const [1024],
        'voice.ogg',
        confirmTrust: (_) async => false,
        readRecording: (_) async {
          reads++;
          return Uint8List.fromList([0]);
        },
      );
      expect(sent, isFalse);
      expect(reads, 0);
      expect(control.target.sends, 0);
      expect(control.replyEvent, isNotNull);
    },
  );

  for (final change in [
    'reply',
    'thread',
    'account',
    'room',
    'privacy',
    'disposed',
  ]) {
    testWithDeadline(
      'voice controller rejects $change changes during trust confirmation',
      (tester) async {
        final (control, matrix) = await mountSend(tester);
        final original = control.target;
        final gate = Completer<bool>();
        var reads = 0;
        final sent = control.onVoiceMessageSend(
          '/unused',
          1000,
          const [1024],
          'voice.ogg',
          confirmTrust: (_) => gate.future,
          readRecording: (_) async {
            reads++;
            return Uint8List.fromList([0]);
          },
        );
        switch (change) {
          case 'reply':
            control.replyEvent = null;
          case 'thread':
            control.activeThreadId = r'$another-thread';
          case 'account':
            matrix.active = _Client();
          case 'room':
            control.target = _VoiceRoom(
              original.client,
              '!another:example.invalid',
            );
          case 'privacy':
            PersonalPrivacy.surfaceUnlocked = false;
          case 'disposed':
            control.alive = false;
        }
        gate.complete(true);
        expect(await sent, isFalse);
        expect(reads, 0);
        expect(original.sends, 0);
      },
    );
  }

  testWithDeadline('voice controller revalidates source after file loading', (
    tester,
  ) async {
    final (control, matrix) = await mountSend(tester);
    final bytes = Completer<Uint8List?>();
    final sent = control.onVoiceMessageSend(
      '/unused',
      1000,
      const [1024],
      'voice.ogg',
      confirmTrust: (_) async => true,
      readRecording: (_) => bytes.future,
    );
    await tester.pump();
    matrix.active = _Client();
    bytes.complete(Uint8List.fromList([0]));
    expect(await sent, isFalse);
    expect(control.target.sends, 0);
  });

  testWithDeadline(
    'voice is handed to the chat before its upload ends, with its frozen reply/thread',
    (tester) async {
      final (control, _) = await mountSend(tester);
      final target = control.target;
      final reply = control.replyEvent;
      target.sendGate = Completer<String?>();
      final sent = control.onVoiceMessageSend(
        '/unused',
        1000,
        const [1024],
        'voice.ogg',
        confirmTrust: (_) async => true,
        readRecording: (_) async => Uint8List.fromList([0]),
      );
      // Returns while the upload is still held: the recorder is free.
      expect(await sent, isTrue);
      await tester.pump();
      expect(target.sends, 1);
      expect(target.sentReply, same(reply));
      expect(target.sentThread, r'$thread');
      expect(target.sentLastThread, r'$last-thread-event');
      final txid = target.transactions.single!;
      expect(echoes.events[txid]?.content['m.relates_to'], isNotNull);
      // The reply moved into the bubble.
      expect(control.replyEvent, isNull);
      target.sendGate!.complete(r'$accepted');
      await tester.pump();
    },
  );

  testWithDeadline('a reply chosen while the voice bubble is stored is kept', (
    tester,
  ) async {
    final (control, _) = await mountSend(tester);
    final target = control.target;
    final reply = control.replyEvent;
    echoes.writeGate = Completer<void>();
    final sent = control.onVoiceMessageSend(
      '/unused',
      1000,
      const [1024],
      'voice.ogg',
      confirmTrust: (_) async => true,
      readRecording: (_) async => Uint8List.fromList([0]),
    );
    await tester.pump();
    control.activeThreadId = r'$new-thread';
    echoes.writeGate!.complete();
    expect(await sent, isTrue);
    await tester.pump();
    expect(target.sentThread, r'$thread');
    expect(control.replyEvent, same(reply));
  });

  testWithDeadline(
    'pending permission is single flight and cancellation disposes its only recorder',
    (tester) async {
      final (state, room) = await mount(tester);
      platform.permissionGate = Completer<bool>();
      final first = state.startRecording(room);
      final repeated = state.startRecording(room);
      await tester.pump();
      expect(platform.creates, 1);
      state.cancel();
      platform.permissionGate!.complete(true);
      await first;
      await repeated;
      await tester.pump();
      expect(platform.starts, 0);
      expect(platform.disposals, 1);
      expect(state.isRecording, isFalse);
      expect(wake.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWithDeadline(
    'denied permission releases native recorder without a wake lock',
    (tester) async {
      final (state, room) = await mount(tester);
      platform.permission = false;
      await state.startRecording(room);
      expect(platform.creates, 1);
      expect(platform.disposals, 1);
      expect(state.isRecording, isFalse);
      expect(wake.values, isEmpty);
      expect(cleanedOutputs, isEmpty);
    },
  );

  testWithDeadline(
    'active cancel removes only its assigned UUID output after SDK cancel',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      final assigned = platform.outputPath!;
      expect(
        assigned,
        matches(
          RegExp(
            // Named after the recording process (stale_recordings.dart).
            r'/voice_\d+_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:ogg|m4a)$',
          ),
        ),
      );
      expect(assigned, isNot(platform.stopOutput));
      state.cancel();
      await drainNativeLifecycle(tester, () => cleanedOutputs.length == 1);
      expect(platform.operations, ['start', 'cancel', 'stop', 'dispose']);
      expect(cleanedOutputs.single.nativePath, assigned);
      expect(cleanedOutputs.single.blobUrl, isNull);
    },
  );

  testWithDeadline(
    'failed and accepted sends retain then remove their own stopped output',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      final assigned = platform.outputPath!;
      await state.stopAndSend((_, _, _, _) async => false);
      expect(cleanedOutputs, isEmpty);
      expect(platform.operations, ['start', 'stop']);
      await state.stopAndSend((_, _, _, _) async => true);
      await drainNativeLifecycle(tester, () => cleanedOutputs.length == 1);
      expect(platform.operations, ['start', 'stop', 'cancel', 'dispose']);
      expect(cleanedOutputs.single.nativePath, assigned);
      expect(cleanedOutputs.single.nativePath, isNot(platform.stopOutput));
    },
  );

  testWithDeadline('cancel after a failed send releases an earlier Blob URL', (
    tester,
  ) async {
    final (state, room) = await mount(tester);
    platform.stopOutput = 'blob:https://example.invalid/recording-fixture';
    await start(state, room);
    await state.stopAndSend((_, _, _, _) async => false);
    expect(cleanedOutputs, isEmpty);
    state.cancel();
    await drainNativeLifecycle(tester, () => cleanedOutputs.length == 1);
    expect(cleanedOutputs.single.blobUrl, platform.stopOutput);
    expect(platform.stops, 1);
    expect(platform.disposals, 1);
  });

  testWithDeadline(
    'native start failure removes only its assigned partial output',
    (tester) async {
      final (state, room) = await mount(tester);
      platform.startFailure = StateError('Synthetic start failure');
      var finished = false;
      final starting = state
          .startRecording(room)
          .whenComplete(() => finished = true);
      await drainNativeLifecycle(
        tester,
        () => finished && cleanedOutputs.length == 1,
      );
      await starting;
      expect(cleanedOutputs.single.nativePath, platform.outputPath);
      expect(platform.operations, ['start', 'cancel', 'dispose']);
      expect(state.isRecording, isFalse);
      expect(wake.values, [true, false]);
    },
  );

  testWithDeadline(
    'amplitude reads never overlap and late completion cannot update a canceled row',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      platform.amplitudeGate = Completer<Amplitude>();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      expect(platform.samples, 1);
      state.cancel();
      platform.amplitudeGate!.complete(Amplitude(current: -20, max: 0));
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
      expect(state.amplitudeTimeline, isEmpty);
      expect(platform.disposals, 1);
      expect(wake.values.last, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWithDeadline(
    'paused voice releases wake lock and stops sampling until resume',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      await tester.pump(const Duration(milliseconds: 100));
      await state.pause();
      final samples = platform.samples;
      await tester.pump(const Duration(seconds: 3));
      expect(platform.samples, samples);
      expect(wake.values.last, isFalse);
      await state.resume();
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.samples, greaterThan(samples));
      expect(wake.values.last, isTrue);
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
  );

  testWithDeadline(
    'unmount during native start still stops, disposes and releases wake lock',
    (tester) async {
      final (state, room) = await mount(tester);
      platform.startGate = Completer<void>();
      var startCompleted = false;
      final starting = state
          .startRecording(room)
          .whenComplete(() => startCompleted = true);
      try {
        await tester.pump();
        expect(platform.starts, 1);
        await tester.pumpWidget(const SizedBox());
      } finally {
        // Always release this native callback, including on assertion failure.
        platform.completePending();
      }
      await drainNativeLifecycle(
        tester,
        () => startCompleted && platform.disposed.isCompleted,
      );
      await starting;
      expect(platform.stops, 1);
      expect(platform.disposals, 1);
      expect(wake.values, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWithDeadline(
    'send is single flight and failure retains the stopped recording for retry',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      final sent = Completer<bool>();
      var sends = 0;
      Future<bool> onSend(
        String path,
        int duration,
        List<int> waveform,
        String name,
      ) {
        sends++;
        return sent.future;
      }

      final sending = state.stopAndSend(onSend);
      await state.stopAndSend(onSend);
      await tester.pump();
      expect(sends, 1);
      expect(state.isSending, isTrue);
      sent.completeError(StateError('Synthetic send failure'));
      await sending;
      expect(state.isRecording, isTrue);
      expect(state.canResume, isFalse);
      expect(wake.values.last, isFalse);
      await state.stopAndSend((_, _, _, _) async {
        sends++;
        return true;
      });
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
      expect(sends, 2);
      expect(platform.stops, 1);
      expect(platform.disposals, 1);
      expect(state.isRecording, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWithDeadline(
    'declined trust/send keeps the stopped draft for explicit retry',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      final name = state.fileName;
      await state.stopAndSend((_, _, _, _) async => false);
      expect(state.isRecording, isTrue);
      expect(state.fileName, name);
      expect(state.isPaused, isTrue);
      expect(state.isSending, isFalse);
      expect(state.canResume, isFalse);
      expect(platform.disposals, 0);
      expect(wake.values.last, isFalse);
      await state.stopAndSend((_, _, _, _) async => true);
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
      expect(state.isRecording, isFalse);
      expect(platform.stops, 1);
      expect(platform.disposals, 1);
    },
  );

  testWithDeadline(
    'visible amplitude history stays bounded for long recordings',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      for (var sample = 0; sample < 150; sample++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        state.amplitudeTimeline.length,
        RecordingViewModelState.maxVisibleAmplitudes,
      );
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
  );

  testWithDeadline(
    'amplitude samples tick the sample listenable, not the composer',
    (tester) async {
      var builds = 0;
      final (state, room) = await mount(tester, onBuild: () => builds++);
      await start(state, room);
      var ticks = 0;
      state.samples.addListener(() => ticks++);
      await tester.pump(const Duration(milliseconds: 100));
      final before = builds;
      for (var sample = 0; sample < 10; sample++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ticks, greaterThanOrEqualTo(10));
      expect(state.amplitudeTimeline.length, greaterThanOrEqualTo(10));
      expect(state.duration, greaterThan(Duration.zero));
      expect(builds, before, reason: 'the composer builder is not per sample');
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
  );

  group('voice capture config', () {
    test('defaults to Telegram: plain mic, mono Opus 48 kHz, no effects', () {
      final config = buildVoiceRecordConfig(
        AudioEncoder.opus,
        const VoiceCaptureOptions(),
      );
      expect(config.encoder, AudioEncoder.opus);
      expect(config.sampleRate, 48000);
      // 64 kbit/s Opus: headroom for a bridge's re-encode (Signal → AAC).
      expect(config.bitRate, 64000);
      expect(config.numChannels, 1);
      expect(config.noiseSuppress, isFalse);
      expect(config.autoGain, isFalse);
      expect(config.echoCancel, isFalse);
      expect(config.audioInterruption, AudioInterruptionMode.pause);
      // record_android maps defaultSource to MediaRecorder.AudioSource.DEFAULT,
      // the source of Telegram's voice notes and rounds.
      expect(
        config.androidConfig.audioSource,
        AndroidAudioSource.defaultSource,
      );
      expect(config.androidConfig.useLegacy, isFalse);
      // No Bluetooth SCO (8–16 kHz call audio) unless the user opts in.
      expect(config.androidConfig.manageBluetooth, isFalse);
    });

    test('high quality raises Opus to 96 kbps and AAC to 128 kbps', () {
      const hq = VoiceCaptureOptions(highQuality: true);
      expect(buildVoiceRecordConfig(AudioEncoder.opus, hq).bitRate, 96000);
      final aac = buildVoiceRecordConfig(AudioEncoder.aacLc, hq);
      expect(aac.bitRate, 128000);
      expect(aac.sampleRate, 44100);
      final aacDefault = buildVoiceRecordConfig(
        AudioEncoder.aacLc,
        const VoiceCaptureOptions(),
      );
      expect(aacDefault.bitRate, 64000);
      expect(aacDefault.sampleRate, 44100);
      expect(aacDefault.numChannels, 1);
      expect(
        aacDefault.androidConfig.audioSource,
        AndroidAudioSource.defaultSource,
      );
      expect(aacDefault.autoGain, isFalse);
      expect(aacDefault.noiseSuppress, isFalse);
    });

    test('voice isolation forces the communication path with AEC, NS, AGC', () {
      final config = buildVoiceRecordConfig(
        AudioEncoder.opus,
        const VoiceCaptureOptions(
          noiseSuppress: false,
          echoCancel: false,
          autoGain: false,
          isolation: true,
        ),
      );
      expect(
        config.androidConfig.audioSource,
        AndroidAudioSource.voiceCommunication,
      );
      expect(config.echoCancel, isTrue);
      expect(config.noiseSuppress, isTrue);
      // The plugin disables an effect it is told is off, which can switch
      // off the call path's own gain control.
      expect(config.autoGain, isTrue);
      expect(config.bitRate, 64000);
    });

    test('individual effect toggles map through unchanged', () {
      final config = buildVoiceRecordConfig(
        AudioEncoder.opus,
        const VoiceCaptureOptions(
          noiseSuppress: true,
          autoGain: true,
          echoCancel: true,
        ),
      );
      expect(config.noiseSuppress, isTrue);
      expect(config.autoGain, isTrue);
      expect(config.echoCancel, isTrue);
      expect(
        config.androidConfig.audioSource,
        AndroidAudioSource.defaultSource,
      );
      final ns = buildVoiceRecordConfig(
        AudioEncoder.opus,
        const VoiceCaptureOptions(noiseSuppress: true),
      );
      expect(ns.noiseSuppress, isTrue);
      expect(ns.autoGain, isFalse);
      expect(ns.echoCancel, isFalse);
    });

    test('the Bluetooth headset microphone is opt-in for either codec', () {
      for (final encoder in [AudioEncoder.opus, AudioEncoder.aacLc]) {
        expect(
          buildVoiceRecordConfig(
            encoder,
            const VoiceCaptureOptions(),
          ).androidConfig.manageBluetooth,
          isFalse,
        );
        final bluetooth = buildVoiceRecordConfig(
          encoder,
          const VoiceCaptureOptions(bluetoothMic: true),
        );
        expect(bluetooth.androidConfig.manageBluetooth, isTrue);
        // The source stays the plain microphone; Android routes it to the
        // headset once SCO is up.
        expect(
          bluetooth.androidConfig.audioSource,
          AndroidAudioSource.defaultSource,
        );
      }
      expect(
        buildVoiceRecordConfig(
          AudioEncoder.opus,
          const VoiceCaptureOptions(bluetoothMic: true, isolation: true),
        ).androidConfig.manageBluetooth,
        isTrue,
      );
    });

    test(
      'untouched settings read the new defaults; explicit ones are kept',
      () async {
        final keys = [
          AppSettings.audioRecordingNoiseSuppress,
          AppSettings.audioRecordingAutoGain,
          AppSettings.audioRecordingEchoCancel,
          AppSettings.personalVoiceBluetoothMic,
        ];
        for (final setting in keys) {
          await AppSettings.store.remove(setting.key);
        }
        addTearDown(() async {
          for (final setting in keys) {
            await AppSettings.store.remove(setting.key);
          }
        });
        var options = VoiceCaptureOptions.fromSettings();
        expect(options.noiseSuppress, isFalse);
        expect(options.autoGain, isFalse);
        expect(options.echoCancel, isFalse);
        expect(options.bluetoothMic, isFalse);
        // A value the user chose (even the old default) is stored and wins.
        await AppSettings.audioRecordingNoiseSuppress.setItem(true);
        await AppSettings.audioRecordingAutoGain.setItem(true);
        await AppSettings.personalVoiceBluetoothMic.setItem(true);
        options = VoiceCaptureOptions.fromSettings();
        expect(options.noiseSuppress, isTrue);
        expect(options.autoGain, isTrue);
        expect(options.bluetoothMic, isTrue);
        final config = buildVoiceRecordConfig(AudioEncoder.opus, options);
        expect(config.noiseSuppress, isTrue);
        expect(config.autoGain, isTrue);
        expect(config.androidConfig.manageBluetooth, isTrue);
      },
    );
  });

  testWithDeadline('recorder starts with the configured voice settings', (
    tester,
  ) async {
    await AppSettings.personalVoiceHighQuality.setItem(true);
    await AppSettings.personalVoiceIsolation.setItem(true);
    addTearDown(() async {
      await AppSettings.personalVoiceHighQuality.setItem(false);
      await AppSettings.personalVoiceIsolation.setItem(false);
    });
    final (state, room) = await mount(tester);
    await start(state, room);
    final config = platform.lastConfig!;
    final apple = PlatformInfos.isCupertinoStyle;
    expect(config.encoder, apple ? AudioEncoder.aacLc : AudioEncoder.opus);
    expect(config.sampleRate, apple ? 44100 : 48000);
    expect(config.bitRate, apple ? 128000 : 96000);
    expect(platform.outputPath, endsWith(apple ? '.m4a' : '.ogg'));
    expect(config.numChannels, 1);
    expect(
      config.androidConfig.audioSource,
      AndroidAudioSource.voiceCommunication,
    );
    state.cancel();
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
  });

  testWithDeadline('recorder starts with Telegram defaults when untouched', (
    tester,
  ) async {
    final (state, room) = await mount(tester);
    await start(state, room);
    final config = platform.lastConfig!;
    final apple = PlatformInfos.isCupertinoStyle;
    expect(config.encoder, apple ? AudioEncoder.aacLc : AudioEncoder.opus);
    expect(config.bitRate, 64000);
    expect(config.autoGain, isFalse);
    expect(config.noiseSuppress, isFalse);
    expect(config.echoCancel, isFalse);
    expect(config.androidConfig.audioSource, AndroidAudioSource.defaultSource);
    expect(config.androidConfig.manageBluetooth, isFalse);
    state.cancel();
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
  });

  group('voice recording plan per platform and network', () {
    BridgeRoomCapabilities caps(Map<String, int>? mimes) =>
        BridgeRoomCapabilities.fromState(
          mimes == null
              ? null
              : {
                  'file': {
                    'org.matrix.msc3245.voice': {'mime_types': mimes},
                  },
                },
        );
    Future<VoiceRecordingPlan> plan(
      TargetPlatform platform,
      BridgeRoomCapabilities capabilities, {
      bool supported = true,
    }) => VoiceRecordingPlan.choose(
      platform: platform,
      web: false,
      preferOpus: preferOpusVoice(capabilities),
      opusSupported: () async => supported,
    );
    // The bridges' voice declarations (docs/voice-recording.md).
    final networks = <String, (Map<String, int>?, bool)>{
      'Telegram': ({'audio/ogg': 2, 'audio/mpeg': 2, 'audio/mp4': 2}, true),
      'WhatsApp': ({opusVoiceMime: 2, 'audio/ogg': 0}, true),
      'Slack': ({'audio/ogg': 1, webmOpusVoiceMime: 2, 'audio/mp4': 2}, true),
      'Signal': ({'audio/aac': 2, 'audio/ogg': 1}, true),
      'an undeclared room': (null, true),
      'Messenger/Instagram': ({'audio/mp4': 2, 'audio/ogg': 1}, false),
      'Slack without ffmpeg': (
        {'audio/ogg': -2, webmOpusVoiceMime: 2, 'audio/mp4': 2},
        false,
      ),
    };
    for (final MapEntry(key: network, value: (mimes, opus))
        in networks.entries) {
      test('$network: macOS records like Android', () async {
        final mac = await plan(TargetPlatform.macOS, caps(mimes));
        final android = await plan(TargetPlatform.android, caps(mimes));
        expect(mac.encoder, android.encoder);
        expect(mac.sentExtension, android.sentExtension);
        if (opus) {
          expect(android, VoiceRecordingPlan.opusOgg);
          // Apple's recorder writes Opus in CAF; it is remuxed to Ogg.
          expect(mac, VoiceRecordingPlan.opusCaf);
          expect(mac.remuxToOgg, isTrue);
          expect(mac.sentExtension, 'ogg');
        } else {
          expect(mac, VoiceRecordingPlan.aacM4a);
          expect(android, VoiceRecordingPlan.aacM4a);
        }
      });
    }
    test('AAC when Opus is unavailable or failed earlier on a Mac', () async {
      expect(
        await plan(TargetPlatform.macOS, caps(null), supported: false),
        VoiceRecordingPlan.aacM4a,
      );
      VoiceRecordingPlan.appleOpusFailed = true;
      expect(
        await plan(TargetPlatform.macOS, caps(null)),
        VoiceRecordingPlan.aacM4a,
      );
      expect(
        await plan(TargetPlatform.android, caps(null)),
        VoiceRecordingPlan.opusOgg,
        reason: 'Android never remuxes',
      );
    });
    test('macOS config: Opus 48 kHz mono 64 kbit/s, 96 high quality', () {
      final config = buildVoiceRecordConfig(
        VoiceRecordingPlan.opusCaf.encoder,
        const VoiceCaptureOptions(),
      );
      expect(config.encoder, AudioEncoder.opus);
      expect(config.sampleRate, 48000);
      expect(config.numChannels, 1);
      expect(config.bitRate, 64000);
      expect(
        buildVoiceRecordConfig(
          AudioEncoder.opus,
          const VoiceCaptureOptions(highQuality: true),
        ).bitRate,
        96000,
      );
    });
  });

  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  const deadline = Timeout(Duration(seconds: 30));

  testWidgets(
    'macOS records Opus in CAF and sends the remuxed Ogg/Opus file',
    (tester) async {
      final remuxed = <(String, String)>[];
      final (state, room) = await mount(
        tester,
        remux: (caf, ogg) async {
          remuxed.add((caf, ogg));
          return RemuxedVoice(ogg, const Duration(milliseconds: 4321));
        },
      );
      await start(state, room);
      final config = platform.lastConfig!;
      expect(config.encoder, AudioEncoder.opus);
      expect(config.sampleRate, 48000);
      expect(config.bitRate, 64000);
      expect(config.numChannels, 1);
      final caf = platform.outputPath!;
      expect(caf, endsWith('.caf'));
      platform.stopOutput = caf;
      final sent = <(String, int, String)>[];
      Future<bool> send(String path, int ms, List<int> _, String name) async {
        sent.add((path, ms, name));
        return sent.length > 1;
      }

      // A failed send keeps the draft; the retry sends the same Ogg file.
      await state.stopAndSend(send);
      expect(state.isRecording, isTrue);
      await state.stopAndSend(send);
      final ogg = caf.replaceFirst(RegExp(r'\.caf$'), '.ogg');
      expect(remuxed, [(caf, ogg)], reason: 'remuxed once per recording');
      expect(sent.map((s) => s.$1), [ogg, ogg]);
      expect(sent.map((s) => s.$2), [4321, 4321]);
      expect(sent.first.$3, endsWith('.ogg'));
      expect(state.isRecording, isFalse);
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
      await drainNativeLifecycle(tester, () => cleanedOutputs.length == 2);
      expect(
        cleanedOutputs.map((o) => o.nativePath),
        unorderedEquals([caf, ogg]),
      );
      expect(VoiceRecordingPlan.appleOpusFailed, isFalse);
    },
    variant: macOS,
    timeout: deadline,
  );

  testWidgets(
    'a failed remux on macOS keeps the draft; the next note records AAC',
    (tester) async {
      var attempts = 0;
      final (state, room) = await mount(
        tester,
        remux: (caf, ogg) async {
          attempts++;
          throw const FormatException('Unexpected CAF');
        },
      );
      await start(state, room);
      platform.stopOutput = platform.outputPath!;
      var sends = 0;
      await state.stopAndSend((_, _, _, _) async {
        sends++;
        return true;
      });
      await tester.pump();
      expect(attempts, 1);
      expect(sends, 0, reason: 'never sends CAF under an Ogg label');
      expect(state.isRecording, isTrue, reason: 'the draft stays');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(VoiceRecordingPlan.appleOpusFailed, isTrue);
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);

      // Later recordings use AAC in M4A, as before Opus on macOS.
      await state.startRecording(room);
      expect(platform.lastConfig!.encoder, AudioEncoder.aacLc);
      expect(platform.lastConfig!.sampleRate, 44100);
      expect(platform.outputPath, endsWith('.m4a'));
      expect(state.fileName, endsWith('.m4a'));
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposals == 2);
    },
    variant: macOS,
    timeout: deadline,
  );

  testWidgets(
    'macOS falls back to AAC when the Opus encoder cannot start',
    (tester) async {
      platform.rejectOpus = true;
      final (state, room) = await mount(tester);
      await state.startRecording(room);
      expect(platform.starts, 2);
      expect(platform.lastConfig!.encoder, AudioEncoder.aacLc);
      expect(platform.outputPath, endsWith('.m4a'));
      expect(state.isRecording, isTrue);
      expect(state.controlsBusy, isFalse);
      expect(cleanedOutputs.single.nativePath, endsWith('.caf'));
      expect(VoiceRecordingPlan.appleOpusFailed, isTrue);
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
    variant: macOS,
    timeout: deadline,
  );

  testWithDeadline(
    'system interruption pause stops the clock, sampling and wake lock',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      // Let the plugin attach its native state subscription.
      for (var turn = 0; turn < 4; turn++) {
        await tester.runAsync(() => Future<void>(() {}));
        await tester.pump(Duration.zero);
      }
      await tester.pump(const Duration(milliseconds: 100));
      platform.nativePaused = true;
      platform.states.add(RecordState.pause);
      await drainNativeLifecycle(tester, () => state.isPaused);
      expect(state.canResume, isTrue);
      final samples = platform.samples;
      await tester.pump(const Duration(seconds: 2));
      expect(platform.samples, samples);
      await drainNativeLifecycle(tester, () => wake.values.last == false);

      // A system-driven resume restarts the clock and sampling.
      platform.nativePaused = false;
      platform.states.add(RecordState.record);
      await drainNativeLifecycle(tester, () => !state.isPaused);
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.samples, greaterThan(samples));
      await drainNativeLifecycle(tester, () => wake.values.last == true);
      state.cancel();
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
  );

  testWithDeadline('stale pause event does not override a running recorder', (
    tester,
  ) async {
    final (state, room) = await mount(tester);
    await start(state, room);
    for (var turn = 0; turn < 4; turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(Duration.zero);
    }
    platform.nativePaused = false;
    platform.states.add(RecordState.pause);
    for (var turn = 0; turn < 8; turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(Duration.zero);
    }
    expect(state.isPaused, isFalse);
    state.cancel();
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
  });

  testWithDeadline('own pause is not undone by its late native event', (
    tester,
  ) async {
    final (state, room) = await mount(tester);
    await start(state, room);
    for (var turn = 0; turn < 4; turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(Duration.zero);
    }
    await state.pause();
    platform.states.add(RecordState.pause);
    platform.states.add(RecordState.record);
    for (var turn = 0; turn < 8; turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(Duration.zero);
    }
    expect(state.isPaused, isTrue);
    state.cancel();
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
  });

  testWithDeadline('short recording is discarded without confirmation', (
    tester,
  ) async {
    final (state, room) = await mount(tester);
    await start(state, room);
    expect(await state.requestDiscard(), isTrue);
    expect(state.isRecording, isFalse);
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    expect(find.byType(Dialog), findsNothing);
  });

  testWithDeadline('recording row exposes labelled 48 dp controls', (
    tester,
  ) async {
    final key = GlobalKey<RecordingViewModelState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: RecordingViewModel(
            key: key,
            cleanupOutput: ({ownedNativePath, stoppedBlobUrl}) async {},
            builder: (_, state) => state.isRecording
                ? RecordingInputRow(
                    state: state,
                    onSend: (_, _, _, _) async => true,
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    await start(state, Room(id: '!row:example.invalid', client: _Client()));
    await tester.pump(const Duration(milliseconds: 100));
    for (final id in [
      'voice_delete_button',
      'voice_pause_button',
      'voice_send_button',
    ]) {
      final size = tester.getSize(find.byKey(Key(id)));
      expect(size.width, greaterThanOrEqualTo(48), reason: id);
      expect(size.height, greaterThanOrEqualTo(48), reason: id);
    }
    expect(find.byKey(const Key('voice_recording_dot')), findsOneWidget);
    expect(find.byTooltip('Delete recording'), findsOneWidget);
    expect(find.byTooltip('Send voice message'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Recording, 0:0')), findsOneWidget);
    await state.pause();
    // The paused row fades through to the recorded waveform.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('Resume recording'), findsOneWidget);
    // Paused: the recorded waveform with play replaces the live bars.
    expect(find.byTooltip('Listen to recording'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Recording paused, ')),
      findsOneWidget,
    );
    state.cancel();
    await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    await tester.pump();
  });

  testWithDeadline(
    'listening to a paused recording finishes it once; send reuses the file',
    (tester) async {
      final (state, room) = await mount(tester);
      await start(state, room);
      expect(await state.finishForReview(), isNull, reason: 'not paused');
      await state.pause();
      expect(state.canResume, isTrue);
      expect(state.isReviewing, isFalse);
      final path = await state.finishForReview();
      expect(path, platform.stopOutput);
      expect(state.isReviewing, isTrue);
      expect(state.canResume, isFalse, reason: 'a stopped file cannot grow');
      expect(await state.finishForReview(), path);
      expect(platform.stops, 1);
      final sent = <String>[];
      await state.stopAndSend((path, _, _, _) async {
        sent.add(path);
        return true;
      });
      expect(sent, [path]);
      expect(platform.stops, 1, reason: 'the reviewed file is the one sent');
      expect(state.isRecording, isFalse);
      expect(state.isReviewing, isFalse);
      await drainNativeLifecycle(tester, () => platform.disposed.isCompleted);
    },
  );

  test('waveform keeps early and late peaks with bounded memory', () {
    final waveform = RecordingWaveform();
    waveform.add(100);
    for (var sample = 0; sample < 100000; sample++) {
      waveform.add(0);
      expect(
        waveform.retainedPeaks,
        lessThanOrEqualTo(RecordingWaveform.maxPeaks),
      );
    }
    waveform.add(50);
    final samples = waveform.samples(count: 40);
    expect(samples.length, 40);
    expect(samples.first, 1024);
    expect(samples.last, 512);
    waveform.clear();
    expect(waveform.samples(count: 40), isEmpty);
    waveform.add(double.nan);
    waveform.add(double.infinity);
    expect(waveform.samples(count: 40), [0, 0]);
  });
}
