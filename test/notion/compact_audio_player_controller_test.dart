// Offline SDK adapter checks: no account, files, codec, HTTP or microphone.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/audio_player.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/personal/voice_playback.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Client extends Client {
  _Client() : super('offline audio fixture', database: _NoDatabase());
  @override
  String get userID => '@fixture:example.invalid';
}

class _NoFiles extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('Fixture denies file access');
}

class _Player implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final speeds = StreamController<double>.broadcast(sync: true);
  final processing = StreamController<ProcessingState>.broadcast(sync: true);
  // Live subscriptions across every stream, to catch leaked ones.
  int listeners = 0;
  int progressStreams = 0;
  Stream<T> _counted<T>(Stream<T> source) => Stream<T>.multi((controller) {
    listeners++;
    final subscription = source.listen(
      controller.addSync,
      onError: controller.addErrorSync,
      onDone: controller.closeSync,
    );
    controller.onCancel = () {
      listeners--;
      return subscription.cancel();
    };
  }, isBroadcast: true);
  final seeks = <Duration>[];
  int stops = 0;
  Completer<void>? pauseGate;
  int pauses = 0;
  @override
  Duration? duration = const Duration(seconds: 66);
  @override
  Duration position = const Duration(seconds: 18);
  @override
  bool playing = false;
  @override
  double speed = 1;
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  Stream<Duration> get positionStream => _counted(positions.stream);
  @override
  Stream<PlayerState> get playerStateStream => _counted(states.stream);
  @override
  Stream<Duration?> get durationStream => _counted(durations.stream);
  @override
  Stream<double> get speedStream => _counted(speeds.stream);
  @override
  Stream<ProcessingState> get processingStateStream => processing.stream;
  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    progressStreams++;
    expect(minPeriod, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
    return _counted(positions.stream);
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async {
    position = value ?? Duration.zero;
    seeks.add(position);
    positions.add(position);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    speeds.add(value);
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (pauseGate != null) await pauseGate!.future;
    playing = false;
    states.add(PlayerState(playing, processingState));
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Future<void> dispose() async {
    await processing.close();
    await positions.close();
    await states.close();
    await durations.close();
    await speeds.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected audio platform access');
}

class _Matrix extends MatrixState {
  final Client source;
  final SharedPreferences preferences;
  late BuildContext viewContext;
  int resumes = 0;
  _Matrix(this.source, this.preferences);
  @override
  bool get mounted => true;
  @override
  Client get client => source;
  @override
  Matrix get widget => Matrix(clients: [source], store: preferences);
  @override
  BuildContext get context => viewContext;
  @override
  Future<void> playAudio() async {
    resumes++;
    final player = audioPlayer as _Player;
    player.playing = true;
    player.states.add(PlayerState(true, player.processingState));
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  late PathProviderPlatform originalPaths;
  setUp(() {
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoFiles();
  });
  tearDown(() => PathProviderPlatform.instance = originalPaths);

  // Drive the row like the timeline does: rebuilds and recycling.
  late ValueNotifier<int> rebuild;
  late ValueNotifier<bool> shown;
  late Event voice;
  Future<(_Player, _Matrix)> mount(
    WidgetTester tester, {
    bool playing = false,
  }) async {
    rebuild = ValueNotifier(0);
    shown = ValueNotifier(true);
    // Synthetic identity; path access fails before any store or key is opened.
    final client = _Client();
    final room = Room(id: '!voice:example.invalid', client: client);
    final event = voice = Event(
      room: room,
      eventId: r'$voice-fixture',
      type: EventTypes.Message,
      senderId: '@speaker:example.invalid',
      originServerTs: DateTime.utc(2026),
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'Voice message',
        'info': {'duration': 66000},
        'org.matrix.msc1767.audio': {
          'waveform': [100, 500, 1024],
        },
      },
    );
    final player = _Player()..playing = playing;
    final matrix = _Matrix(client, await SharedPreferences.getInstance())
      ..audioPlayer = player
      ..voiceMessageEventId.value = event.eventId;
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                matrix.viewContext = context;
                return ListenableBuilder(
                  listenable: Listenable.merge([rebuild, shown]),
                  builder: (context, _) => SizedBox(
                    width: 300,
                    child: shown.value
                        ? AudioPlayerWidget(
                            event,
                            color: Colors.black,
                            linkColor: Colors.black,
                            fontSize: 15,
                          )
                        : const SizedBox.shrink(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      matrix.voiceMessageEventId.value = null;
      await tester.pumpWidget(const SizedBox());
      await matrix.closeAudioPlayer();
      PersonalClient.of(client).dispose();
    });
    return (player, matrix);
  }

  testWidgets(
    'real adapter clamps jumps, seeks paused audio and cycles speed',
    (tester) async {
      final (player, matrix) = await mount(tester);
      expect(find.text('0:18 / 1:06'), findsOneWidget);
      await tester.tap(find.byTooltip('Rewind 10 seconds'));
      await tester.pump();
      expect(player.position, const Duration(seconds: 8));
      await tester.tap(find.byTooltip('Rewind 10 seconds'));
      await tester.pump();
      expect(player.position, Duration.zero);
      player.position = const Duration(seconds: 64);
      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();
      expect(player.position, const Duration(seconds: 66));
      final block = tester.widget<NotionAudioFileBlock>(
        find.byType(NotionAudioFileBlock),
      );
      block.onSeek!(.5);
      await tester.pump();
      expect(player.position, const Duration(seconds: 33));
      expect(player.playing, isFalse);
      expect(matrix.resumes, 0);
      for (final speed in [1.25, 1.5, 2.0, .5, 1.0]) {
        await tester.tap(find.byTooltip('Playback speed'));
        await tester.pump();
        expect(player.speed, speed);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('duration and speed streams refresh the compact controls', (
    tester,
  ) async {
    final (player, _) = await mount(tester);
    player.duration = const Duration(seconds: 90);
    player.durations.add(player.duration);
    player.speed = 1.5;
    player.speeds.add(player.speed);
    await tester.pump();
    expect(find.text('0:18 / 1:30'), findsOneWidget);
    expect(find.text('1.5×'), findsOneWidget);
    player.duration = null;
    player.durations.add(null);
    await tester.pump();
    final block = tester.widget<NotionAudioFileBlock>(
      find.byType(NotionAudioFileBlock),
    );
    expect(block.onSeek, isNull);
    expect(block.onSeekBack, isNull);
    expect(find.text('0:18 / 1:06'), findsOneWidget);
  });

  testWidgets('stale source callbacks cannot seek or change another player', (
    tester,
  ) async {
    final (player, matrix) = await mount(tester);
    final block = tester.widget<NotionAudioFileBlock>(
      find.byType(NotionAudioFileBlock),
    );
    matrix.voiceMessageEventId.value = r'$another-voice';
    block.onSeek!(.9);
    block.onSeekBack!();
    block.onSeekForward!();
    block.onSpeed!();
    await tester.pump();
    expect(player.seeks, isEmpty);
    expect(player.speed, 1);
  });

  testWidgets('rapid repeated play taps perform one pending transport action', (
    tester,
  ) async {
    final (player, matrix) = await mount(tester, playing: true);
    player.pauseGate = Completer<void>();
    final block = tester.widget<NotionAudioFileBlock>(
      find.byType(NotionAudioFileBlock),
    );
    block.onPlay!();
    block.onPlay!();
    expect(player.pauses, 1);
    player.pauseGate!.complete();
    await tester.pump();
    expect(player.playing, isFalse);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(matrix.resumes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'position ticks rebuild only the transport; subscriptions do not grow',
    (tester) async {
      final (player, _) = await mount(tester, playing: true);
      // Progress, state, duration and speed: one subscription each.
      expect(player.listeners, 4);
      expect(player.progressStreams, 1);
      final transcript = tester.widget(find.byType(TranscriptPanel));
      for (var second = 19; second <= 23; second++) {
        player.position = Duration(seconds: second);
        player.positions.add(player.position);
        await tester.pump();
      }
      expect(find.text('0:23 / 1:06'), findsOneWidget);
      // The transcript (and caption) were not rebuilt by the ticks.
      expect(tester.widget(find.byType(TranscriptPanel)), same(transcript));
      for (var i = 0; i < 6; i++) {
        rebuild.value++;
        await tester.pump();
      }
      expect(player.listeners, 4);
      expect(player.progressStreams, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only the active note shows skips, speed and save', (
    tester,
  ) async {
    final (_, matrix) = await mount(tester);
    expect(find.byTooltip('Rewind 10 seconds'), findsOneWidget);
    expect(find.byTooltip('Playback speed'), findsOneWidget);
    expect(find.byTooltip('Download audio'), findsOneWidget);
    matrix.voiceMessageEventId.value = r'$another-voice';
    await tester.pump();
    await tester.pump(NotionMotion.long);
    expect(find.byTooltip('Rewind 10 seconds'), findsNothing);
    expect(find.byTooltip('Playback speed'), findsNothing);
    expect(find.byTooltip('Download audio'), findsNothing);
    expect(find.byTooltip('Play audio'), findsOneWidget);
    matrix.voiceMessageEventId.value = voice.eventId;
    await tester.pump();
    await tester.pump(NotionMotion.long);
    expect(find.byTooltip('Playback speed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a paused note keeps its player and position when recycled', (
    tester,
  ) async {
    final (player, matrix) = await mount(tester);
    shown.value = false;
    await tester.pump();
    await tester.pump();
    expect(matrix.audioPlayer, same(player));
    expect(matrix.voiceMessageEventId.value, voice.eventId);
    expect(player.stops, 0);
    shown.value = true;
    await tester.pump();
    expect(find.text('0:18 / 1:06'), findsOneWidget);
    expect(player.listeners, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an ended note is released after the frame, not while unmounting',
    (tester) async {
      final (player, matrix) = await mount(tester);
      player.position = player.duration!;
      final phases = <SchedulerPhase>[];
      void record() => phases.add(SchedulerBinding.instance.schedulerPhase);
      matrix.voiceMessageEventId.addListener(record);
      addTearDown(() => matrix.voiceMessageEventId.removeListener(record));
      shown.value = false;
      await tester.pump();
      expect(matrix.audioPlayer, isNull);
      expect(player.stops, 1);
      expect(phases, [SchedulerPhase.postFrameCallbacks]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the chosen speed is remembered for the next notes', (
    tester,
  ) async {
    addTearDown(() => AppSettings.personalVoicePlaybackSpeed.setItem(1));
    final (player, matrix) = await mount(tester);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    expect(player.speed, 1.5);
    expect(AppSettings.personalVoicePlaybackSpeed.value, 1.5);
    expect(matrix.voiceSpeed, 1.5);
    // Another account state or a later note reads the same stored speed.
    final later = _Matrix(_Client(), await SharedPreferences.getInstance());
    expect(later.voiceSpeed, 1.5);
  });

  testWidgets('a finished voice note continues with the next one', (
    tester,
  ) async {
    RoundPlaybackCoordinator.shared.debugReset();
    addTearDown(RoundPlaybackCoordinator.shared.debugReset);
    final (player, matrix) = await mount(tester, playing: true);
    final next = Event(
      room: voice.room,
      eventId: r'$voice-next',
      type: EventTypes.Message,
      senderId: '@speaker:example.invalid',
      originServerTs: DateTime.utc(2026, 1, 2),
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'Voice message',
        'org.matrix.msc3245.voice': <String, Object?>{},
      },
    );
    final row = _Row();
    VoicePlayback.targets.register(next, row);
    addTearDown(() => VoicePlayback.targets.unregister(next, row));
    expect(await matrix.reserveAudio().acquireAudible(), isTrue);
    matrix.watchAudio(player, continuation: () => [next]);
    player.processing.add(ProcessingState.completed);
    await tester.pump();
    await tester.pump();
    expect(row.calls, hasLength(1));
    expect(row.tokenWasActive, isTrue);
    expect(matrix.audioPlayer, isNull);
    expect(player.stops, 1);
    expect(RoundPlaybackCoordinator.shared.continuing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the notification shade keeps a voice note; background pauses it and '
    'keeps it; a lock closes it',
    (tester) async {
      RoundPlaybackCoordinator.shared.debugReset();
      addTearDown(() {
        RoundPlaybackCoordinator.shared.debugReset();
        PersonalPrivacy.surfaceUnlocked = true;
        PersonalPrivacy.surfaceForeground = true;
      });
      final matrix = _Matrix(_Client(), await SharedPreferences.getInstance());
      final player = _Player()..playing = true;
      matrix
        ..audioPlayer = player
        ..voiceMessageEventId.value = r'$voice-fixture';
      expect(await matrix.reserveAudio().acquireAudible(), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const AppLockWidget(
            pincode: null,
            useBiometrics: false,
            isLoggedIn: true,
            child: SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.pauses, 0);
      expect(player.stops, 0);
      expect(player.playing, isTrue);
      expect(RoundPlaybackCoordinator.shared.suspended, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(player.pauses, greaterThanOrEqualTo(1));
      expect(player.playing, isFalse);
      expect(player.stops, 0);
      expect(matrix.audioPlayer, same(player));
      expect(player.position, const Duration(seconds: 18));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(RoundPlaybackCoordinator.shared.suspended, isFalse);
      // Nothing resumes by itself; a lock releases the note.
      expect(player.playing, isFalse);
      tester.state<AppLock>(find.byType(AppLockWidget)).showLockScreen();
      await tester.pump();
      expect(matrix.audioPlayer, isNull);
      expect(player.stops, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Row implements RoundContinuationTarget {
  final calls = <List<Event>>[];
  bool tokenWasActive = false;
  @override
  Future<RoundStartResult> startContinuation(
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
  }) async {
    calls.add(rest);
    tokenWasActive = token.active;
    return RoundStartResult.started;
  }
}
