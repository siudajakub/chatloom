// Offline SDK adapter checks: no account, files, codec, HTTP or microphone.
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/events/audio_player.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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
  final seeks = <Duration>[];
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
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<double> get speedStream => speeds.stream;
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
  Future<void> stop() async => playing = false;
  @override
  Future<void> dispose() async {
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

  Future<(_Player, _Matrix)> mount(
    WidgetTester tester, {
    bool playing = false,
  }) async {
    // Synthetic identity; path access fails before any store or key is opened.
    final client = _Client();
    final room = Room(id: '!voice:example.invalid', client: client);
    final event = Event(
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
                return SizedBox(
                  width: 300,
                  child: AudioPlayerWidget(
                    event,
                    color: Colors.black,
                    linkColor: Colors.black,
                    fontSize: 15,
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
}
