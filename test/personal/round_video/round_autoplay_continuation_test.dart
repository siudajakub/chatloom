// SPDX-License-Identifier: AGPL-3.0-or-later
// Autoplay continuation (round → next round/voice) against a fake platform
// that behaves like video_player_android 2.12: a buffering event arrives
// before `initialized`, calls on a disposed player throw, and building a
// VideoPlayer for a disposed player throws (a grey ErrorWidget in release).
// The mini player is hosted like lib/widgets/matrix.dart: above the
// Navigator, outside every Overlay. Fictional offline fixtures only.
import 'dart:async';

import 'package:chatloom/pages/chat/events/round_mini_player.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/chat/events/round_video_stage.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _NativePlayer {
  // A zone-local cancel future: the SDK's default root-zone future never
  // completes under fake async.
  final events = StreamController<VideoEvent>(onCancel: () async {});
  Duration position = Duration.zero;
}

/// video_player_android 2.12 semantics, see the file comment.
class _AndroidLikePlatform extends VideoPlayerPlatform {
  final players = <int, _NativePlayer>{};
  final created = <int>[];
  final played = <int>[];
  var maxLive = 0;
  var _next = 0;

  @override
  Future<void> init() async {}

  _NativePlayer _with(int id) =>
      players[id] ?? (throw StateError('No active player with ID $id.'));

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    final player = players[id] = _NativePlayer();
    created.add(id);
    if (players.length > maxLive) maxLive = players.length;
    // ExoPlayer reports BUFFERING before READY/initialized.
    player.events
      ..add(VideoEvent(eventType: VideoEventType.bufferingStart))
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 10),
          size: const Size(240, 240),
        ),
      )
      ..add(VideoEvent(eventType: VideoEventType.bufferingEnd));
    return id;
  }

  /// STATE_ENDED: `completed`, then `isPlaying` false.
  void finish(int id, {bool twice = false}) {
    final player = _with(id)..position = const Duration(seconds: 10);
    player.events.add(VideoEvent(eventType: VideoEventType.completed));
    if (twice) {
      player.events.add(VideoEvent(eventType: VideoEventType.completed));
    }
    player.events.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: false,
      ),
    );
  }

  void fail(int id) => _with(id).events.addError(
    PlatformException(code: 'VideoError', message: 'decoder failed'),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _with(playerId).events.stream;

  @override
  Future<void> dispose(int playerId) async {
    final player = players.remove(playerId);
    unawaited(player?.events.close());
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    _with(options.playerId);
    return SizedBox.expand(key: ValueKey('texture-${options.playerId}'));
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async => _with(playerId);
  @override
  Future<void> play(int playerId) async {
    _with(playerId);
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async => _with(playerId);
  @override
  Future<void> setVolume(int playerId, double volume) async => _with(playerId);
  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      _with(playerId).position = position;
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async =>
      _with(playerId);
  @override
  Future<Duration> getPosition(int playerId) async => _with(playerId).position;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async => _with(playerId);
}

class _Media extends RoundLoadedMedia {
  _Media() : super.web(Uri.parse('data:video/mp4;base64,AAAA'));
  bool closed = false;
  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

/// Re-validates the source after the (gated) download like the real loader.
class _Loader extends RoundMediaLoader {
  final gates = <String, Completer<void>>{};
  final failing = <String>{};
  final loads = <String>[];
  final media = <_Media>[];

  Future<RoundLoadedMedia> _fetch(
    Event event,
    RoundMediaCancellation? cancellation,
  ) async {
    loads.add(event.eventId);
    await gates[event.eventId]?.future;
    if (cancellation?.valid == false) {
      throw const RoundMediaUnavailable('cancelled');
    }
    if (failing.contains(event.eventId)) {
      throw const RoundMediaUnavailable('decryptionFailed');
    }
    final loaded = _Media();
    media.add(loaded);
    return loaded;
  }

  @override
  Future<RoundLoadedMedia> load(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) => _fetch(event, cancellation);

  @override
  Future<RoundLoadedMedia> loadVoice(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) => _fetch(event, cancellation);
}

/// The few just_audio members the detached voice path uses.
class _FakeAudio implements AudioPlayer {
  static final instances = <_FakeAudio>[];
  _FakeAudio() {
    instances.add(this);
  }
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  Duration _position = Duration.zero;
  bool _playing = false, disposed = false;
  ProcessingState _processing = ProcessingState.idle;

  void _emit() {
    if (disposed) return;
    _states.add(PlayerState(_playing, _processing));
    _positions.add(_position);
  }

  void finish() {
    _position = const Duration(seconds: 5);
    _playing = false;
    _processing = ProcessingState.completed;
    _emit();
  }

  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  ProcessingState get processingState => _processing;
  @override
  Duration get position => _position;
  @override
  Duration? get duration => const Duration(seconds: 5);
  @override
  bool get playing => _playing;
  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async => _ready();
  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => _ready();
  Duration? _ready() {
    _processing = ProcessingState.ready;
    return duration;
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> play() async {
    _playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _position = position ?? Duration.zero;
    _emit();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(_positions.close());
    unawaited(_states.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('fake audio: ${invocation.memberName}');
}

/// A row that cannot take the continuation, like a row still busy after the
/// bounded wait: before the fix this stopped the whole queue.
class _BusyTarget implements RoundContinuationTarget {
  var calls = 0;
  @override
  Future<RoundStartResult> startContinuation(
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
  }) async {
    calls++;
    return RoundStartResult.aborted;
  }
}

final _client = Client('autoplay fixture', database: _UnusedDatabase());
final _room = Room(id: '!autoplay:example.invalid', client: _client);

Event _message(int i, {bool voice = false}) => Event(
  room: _room,
  eventId: '\$message$i',
  senderId: '@fixture:example.invalid',
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026, 1, 1, 0, i),
  status: EventStatus.synced,
  content: voice
      ? {
          'msgtype': 'm.audio',
          'body': 'voice.ogg',
          'url': 'mxc://example.invalid/voice$i',
          'info': {'duration': 5000, 'mimetype': 'audio/ogg'},
        }
      : {
          'msgtype': 'm.video',
          'body': 'fixture.mp4',
          'url': 'mxc://example.invalid/round$i',
          'info': {'fi.mau.telegram.round_message': true, 'duration': 10000},
        },
);

void main() {
  late _AndroidLikePlatform platform;
  late VideoPlayerPlatform original;
  late _Loader loader;

  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _AndroidLikePlatform();
    VideoPlayerPlatform.instance = platform;
    loader = _Loader();
    _FakeAudio.instances.clear();
    RoundMiniPlayerController.debugMediaState = (_) async => null;
    RoundMiniPlayerController.debugLoader = loader;
    RoundMiniPlayerController.debugCreateAudio = _FakeAudio.new;
    RoundVideoMessage.debugCreatePlayer = null;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = original;
    RoundMiniPlayerController.debugMediaState = null;
    RoundMiniPlayerController.debugLoader = null;
    RoundMiniPlayerController.debugCreateAudio = null;
  });

  /// Every scenario shares [RoundPlaybackCoordinator.shared] with the mini
  /// player, so it starts from a chain created in its own fake-async zone.
  void scenario(String description, WidgetTesterCallback body) =>
      testWidgets(description, (tester) async {
        RoundPlaybackCoordinator.shared.debugReset();
        await body(tester);
      });

  Future<void> settle(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Production shape: MaterialApp.router's builder puts Matrix (and the
  /// mini player) above the Navigator, so the bar has no Overlay ancestor.
  Widget app({
    required List<Event> rows,
    List<Event>? timeline,
    Set<String> unreadRows = const {},
    bool? Function(Event)? unreadOf,
  }) {
    final all = timeline ?? rows;
    return MaterialApp(
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child!,
          Positioned(
            left: 16,
            right: 16,
            bottom: 80,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: RoundMiniPlayer(onOpenSource: (_) {}),
              ),
            ),
          ),
        ],
      ),
      home: Scaffold(
        body: ListView(
          children: [
            for (final event in rows)
              Padding(
                key: ValueKey(event.eventId),
                padding: const EdgeInsets.only(bottom: 8),
                child: RoundVideoMessage(
                  event,
                  loader: loader,
                  coordinator: RoundPlaybackCoordinator.shared,
                  showThumbnail: false,
                  mediaUnread: unreadRows.contains(event.eventId),
                  continuationUnread: unreadOf,
                  continuationQueue: () => all.sublist(all.indexOf(event) + 1),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Finder playButtons() => find.byTooltip('Play round video');

  /// Number of rows rendering a live texture inline or on the stage.
  int textures() => find
      .byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('texture-'),
      )
      .evaluate()
      .length;

  Future<void> cleanup(WidgetTester tester) async {
    unawaited(RoundMiniPlayerController.shared.stop());
    await settle(tester, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(RoundMiniPlayerController.shared.stop());
    await settle(tester, 4);
    expect(RoundStageController.shared.isOpen, isFalse);
    expect(platform.players, isEmpty, reason: 'every decoder released');
    expect(
      loader.media.every((m) => m.closed),
      isTrue,
      reason: 'every plaintext lease closed',
    );
    RoundPlaybackCoordinator.shared.resume();
  }

  scenario('a buffering event before initialization is not a completion', (
    tester,
  ) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(loader.loads, [r'$message0'], reason: 'the tapped round plays');
    expect(platform.played, [0]);
    expect(RoundMiniPlayerController.shared.current, isNull);
    expect(RoundStageController.shared.isOpen, isTrue);
    await cleanup(tester);
  });

  scenario('autoplay moves into the next mounted row, one decoder at a '
      'time, through the last round', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      final id = platform.players.keys.single;
      platform.finish(id);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'after round $i');
      expect(platform.maxLive, 1, reason: 'never two decoders at once');
      if (i < 2) {
        expect(loader.loads.last, '\$message${i + 1}');
        expect(platform.played.last, platform.players.keys.single);
        // The next round plays in its own row and is enlarged again.
        expect(RoundMiniPlayerController.shared.current, isNull);
        expect(RoundStageController.shared.isOpen, isTrue);
        expect(find.byType(RoundVideoStage), findsOneWidget);
        expect(textures(), 1);
      }
    }
    // Last in list: nothing else starts, nothing is left enlarged. The
    // finished row may keep its paused controller for an instant replay; it
    // is the only one and is released as soon as anything else opens.
    expect(loader.loads, [r'$message0', r'$message1', r'$message2']);
    expect(RoundStageController.shared.isOpen, isFalse);
    expect(platform.players.length, lessThanOrEqualTo(1));
    expect(platform.played, hasLength(3));
    expect(find.byType(ErrorWidget), findsNothing);
    await cleanup(tester);
  });

  scenario('a next round that is not mounted continues in the mini player '
      'without breaking the app', (tester) async {
    final timeline = [for (var i = 0; i < 2; i++) _message(i)];
    await tester.pumpWidget(app(rows: [timeline.first], timeline: timeline));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(platform.maxLive, 1);
    final session = RoundMiniPlayerController.shared.current;
    expect(session?.event.eventId, r'$message1');
    expect(session?.playing, isTrue);
    expect(find.text('Round video'), findsOneWidget);
    // The bar stays usable: pause, change speed, stop.
    await tester.tap(find.byTooltip('Pause'));
    await settle(tester, 2);
    await tester.tap(find.byTooltip('Playback speed'));
    await settle(tester, 2);
    expect(RoundMiniPlayerController.shared.current?.speed, 1.25);
    await tester.tap(find.byTooltip('Stop playback'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(RoundMiniPlayerController.shared.current, isNull);
    await cleanup(tester);
  });

  scenario('a next round that cannot be decrypted is skipped with an '
      'inline error', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    loader.failing.add(r'$message1');
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(loader.loads, [r'$message0', r'$message1', r'$message2']);
    expect(find.text('Playback failed. Try again.'), findsOneWidget);
    expect(platform.players, hasLength(1));
    expect(platform.played.last, platform.players.keys.single);
    expect(RoundStageController.shared.isOpen, isTrue);
    await cleanup(tester);
  });

  scenario('a next round still downloading shows its own progress, then '
      'plays', (tester) async {
    final rows = [for (var i = 0; i < 2; i++) _message(i)];
    final gate = loader.gates[r'$message1'] = Completer<void>();
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(find.byTooltip('Cancel download'), findsOneWidget);
    expect(platform.players, isEmpty, reason: 'previous decoder released');
    gate.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(platform.played, hasLength(2));
    expect(RoundStageController.shared.isOpen, isTrue);
    await cleanup(tester);
  });

  scenario('duplicate completion events advance exactly once', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single, twice: true);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(loader.loads, [r'$message0', r'$message1']);
    expect(platform.created, hasLength(2));
    expect(platform.maxLive, 1);
    await cleanup(tester);
  });

  scenario('an explicit play while the next round loads wins', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    final gate = loader.gates[r'$message1'] = Completer<void>();
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    // The third row: the second shows its download ring instead.
    await tester.tap(playButtons().last);
    await settle(tester);
    gate.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(platform.players, hasLength(1));
    expect(loader.loads.last, r'$message2');
    expect(find.text('Playback failed. Try again.'), findsNothing);
    await cleanup(tester);
  });

  scenario('pausing the app mid-continuation stops it for good', (
    tester,
  ) async {
    final rows = [for (var i = 0; i < 2; i++) _message(i)];
    final gate = loader.gates[r'$message1'] = Completer<void>();
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    // AppLockWidget/Matrix stop the coordinator when the app backgrounds.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    unawaited(RoundPlaybackCoordinator.shared.stopAll());
    await settle(tester, 2);
    gate.complete();
    await settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    RoundPlaybackCoordinator.shared.resume();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(platform.players, isEmpty, reason: 'nothing resumes by itself');
    expect(RoundMiniPlayerController.shared.current, isNull);
    await cleanup(tester);
  });

  scenario('leaving the chat while the next round loads keeps the '
      'continuation in the mini player', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    final gate = loader.gates[r'$message1'] = Completer<void>();
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    // The chat closes: every row is disposed while round 1 downloads.
    await tester.pumpWidget(app(rows: const [], timeline: rows));
    await settle(tester, 2);
    gate.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(platform.maxLive, 1);
    expect(
      RoundMiniPlayerController.shared.current?.event.eventId,
      r'$message1',
    );
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(
      RoundMiniPlayerController.shared.current?.event.eventId,
      r'$message2',
    );
    expect(platform.maxLive, 1);
    await cleanup(tester);
  });

  scenario('scrolling a playing round away hands it to the mini player, '
      'which continues the queue', (tester) async {
    final rows = [for (var i = 0; i < 2; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    // Shrink back into the row, then recycle the row while it plays.
    RoundStageController.shared.shrink();
    await settle(tester);
    await tester.pumpWidget(app(rows: const [], timeline: rows));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(
      RoundMiniPlayerController.shared.current?.event.eventId,
      r'$message0',
    );
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(
      RoundMiniPlayerController.shared.current?.event.eventId,
      r'$message1',
    );
    expect(platform.maxLive, 1);
    await cleanup(tester);
  });

  scenario('voice and round items continue in order', (tester) async {
    final timeline = [_message(0), _message(1, voice: true), _message(2)];
    await tester.pumpWidget(
      app(rows: [timeline[0], timeline[2]], timeline: timeline),
    );
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(platform.players, isEmpty, reason: 'video decoder released');
    final voice = RoundMiniPlayerController.shared.current;
    expect(voice?.event.eventId, r'$message1');
    expect(_FakeAudio.instances.single.playing, isTrue);
    expect(find.text('Voice message'), findsOneWidget);
    _FakeAudio.instances.single.finish();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(_FakeAudio.instances.single.disposed, isTrue);
    expect(RoundMiniPlayerController.shared.current, isNull);
    expect(loader.loads.last, r'$message2');
    expect(platform.players, hasLength(1));
    expect(RoundStageController.shared.isOpen, isTrue);
    await cleanup(tester);
  });

  scenario('from an unread round, autoplay skips messages known to be '
      'played', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    await tester.pumpWidget(
      app(
        rows: rows,
        unreadRows: {r'$message0', r'$message2'},
        unreadOf: (e) => switch (e.eventId) {
          r'$message1' => false,
          r'$message2' => true,
          _ => null,
        },
      ),
    );
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(loader.loads, [r'$message0', r'$message2']);
    await cleanup(tester);
  });

  scenario('a next round that cannot start in its row is skipped and the '
      'continuation is always released', (tester) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    final busy = _BusyTarget();
    RoundContinuationTargets.shared.register(rows[1], busy);
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.finish(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(busy.calls, 1);
    expect(loader.loads, [r'$message0', r'$message2']);
    expect(platform.played, hasLength(2));
    expect(RoundPlaybackCoordinator.shared.continuing, isFalse);
    RoundContinuationTargets.shared.unregister(rows[1], busy);
    await cleanup(tester);
  });

  scenario('a row busy with another start is waited for, bounded', (
    tester,
  ) async {
    final rows = [for (var i = 0; i < 3; i++) _message(i)];
    final first = loader.gates[r'$message1'] = Completer<void>();
    final never = loader.gates[r'$message2'] = Completer<void>();
    await tester.pumpWidget(app(rows: rows));
    // Row 1 is busy loading when the continuation reaches it.
    await tester.tap(playButtons().at(1));
    await tester.pump();
    var token = RoundPlaybackCoordinator.shared.beginContinuation();
    final target = RoundContinuationTargets.shared.targetFor(rows[1])!;
    RoundStartResult? result;
    unawaited(
      target
          .startContinuation(const [], token: token, speed: 1, enlarge: false)
          .then((value) => result = value),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(result, isNull, reason: 'waits instead of giving up');
    first.complete();
    await settle(tester);
    expect(result, RoundStartResult.started);
    expect(platform.created, hasLength(1), reason: 'reuses the decoder');
    expect(tester.takeException(), isNull);
    // Still busy after the bounded wait: reported as failed (skipped).
    RoundStageController.shared.shrink();
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey(r'$message2')),
        matching: playButtons(),
      ),
    );
    await tester.pump();
    token = RoundPlaybackCoordinator.shared.beginContinuation();
    result = null;
    unawaited(
      RoundContinuationTargets.shared
          .targetFor(rows[2])!
          .startContinuation(const [], token: token, speed: 1, enlarge: false)
          .then((value) => result = value),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(result, RoundStartResult.failed);
    token.end();
    never.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  scenario('a decoder error mid-playback skips to the next round', (
    tester,
  ) async {
    final rows = [for (var i = 0; i < 2; i++) _message(i)];
    await tester.pumpWidget(app(rows: rows));
    await tester.tap(playButtons().first);
    await settle(tester);
    platform.fail(platform.players.keys.single);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Playback was interrupted. Try again.'), findsOneWidget);
    expect(loader.loads.last, r'$message1');
    expect(platform.players, hasLength(1));
    await cleanup(tester);
  });
}
