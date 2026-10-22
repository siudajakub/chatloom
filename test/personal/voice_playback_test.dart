// Offline: synthetic events only; nothing is downloaded, decrypted or sent.
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:chatloom/personal/voice_playback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Client extends Client {
  _Client() : super('offline voice queue fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

class _MemoryStorage implements VoicePlayedStorage {
  Map<String, dynamic>? value;
  bool fail = false;

  @override
  Future<Map<String, dynamic>?> read() async {
    if (fail) throw StateError('storage unavailable');
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('storage unavailable');
    this.value = Map.of(value);
  }
}

class _Target implements RoundContinuationTarget {
  final RoundStartResult Function(RoundContinuationToken token) result;
  final calls = <List<Event>>[];
  _Target(this.result);
  @override
  Future<RoundStartResult> startContinuation(
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
  }) async {
    calls.add(rest);
    return result(token);
  }
}

void main() {
  final client = _Client();
  final room = Room(id: '!chat:example.invalid', client: client);
  var clock = 0;
  Event message(
    String id, {
    bool voice = true,
    String sender = '@anna:example.invalid',
    Map<String, Object?> extra = const {},
    String type = EventTypes.Message,
    EventStatus status = EventStatus.synced,
  }) => Event(
    room: room,
    eventId: id,
    type: type,
    senderId: sender,
    status: status,
    originServerTs: DateTime.utc(2026, 1, 1, 12, 0, clock++),
    content: {
      'msgtype': voice ? MessageTypes.Audio : MessageTypes.Text,
      'body': voice ? 'Voice message' : 'Fictional text',
      if (voice) 'org.matrix.msc3245.voice': <String, Object?>{},
      ...extra,
    },
  );

  List<String> ids(List<Event> events) => [for (final e in events) e.eventId];

  group('VoicePlaybackQueue', () {
    test('plays the run of voice notes after the source, up to a gap', () {
      clock = 0;
      final source = message(r'$a');
      final b = message(r'$b');
      final reaction = message(r'$r', type: EventTypes.Reaction, voice: false);
      final c = message(r'$c');
      final text = message(r'$t', voice: false);
      final d = message(r'$d');
      // Timeline order is newest first; the queue sorts by time.
      final history = [d, text, c, reaction, b, source];
      expect(
        ids(
          VoicePlaybackQueue.after(
            source,
            history,
            unplayedOnly: true,
            played: (_) => false,
          ),
        ),
        [r'$b', r'$c'],
      );
    });

    test('from an unplayed note own and played notes are skipped', () {
      clock = 0;
      final source = message(r'$a');
      final own = message(r'$own', sender: '@me:example.invalid');
      final heard = message(r'$heard');
      final next = message(r'$next');
      final history = [source, own, heard, next];
      bool played(Event e) => e.eventId == r'$heard';
      expect(
        ids(
          VoicePlaybackQueue.after(
            source,
            history,
            unplayedOnly: true,
            played: played,
          ),
        ),
        [r'$next'],
      );
      // Replaying an old note continues through every later note.
      expect(
        ids(
          VoicePlaybackQueue.after(
            source,
            history,
            unplayedOnly: false,
            played: played,
          ),
        ),
        [r'$own', r'$heard', r'$next'],
      );
    });

    test('limited, unsent, threaded and non-voice audio never autoplay', () {
      clock = 0;
      final source = message(r'$a');
      final viewOnce = message(
        r'$once',
        extra: {
          'com.beeper.disappearing_timer': {'type': 'after_read', 'timer': 1},
        },
      );
      final pending = message(r'$local', status: EventStatus.sending);
      final threaded = message(
        r'$thread',
        extra: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.thread,
            'event_id': r'$root',
          },
        },
      );
      final next = message(r'$next');
      final history = [source, viewOnce, pending, threaded, next];
      expect(
        ids(
          VoicePlaybackQueue.after(
            source,
            history,
            unplayedOnly: false,
            played: (_) => false,
          ),
        ),
        [r'$next'],
      );
      // An attached audio file (not a voice note) does not continue.
      final song = Event(
        room: room,
        eventId: r'$song',
        type: EventTypes.Message,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2025),
        content: {'msgtype': MessageTypes.Audio, 'body': 'song.mp3'},
      );
      expect(
        VoicePlaybackQueue.after(
          song,
          [song, ...history],
          unplayedOnly: false,
          played: (_) => false,
        ),
        isEmpty,
      );
    });

    test('a chat with a disappearing timer never autoplays', () {
      clock = 0;
      final timed = Room(id: '!timed:example.invalid', client: client)
        ..setState(
          StrippedStateEvent(
            type: 'com.beeper.disappearing_timer',
            stateKey: '',
            senderId: '@bridge:example.invalid',
            content: {'type': 'after_send', 'timer': 60000},
          ),
        );
      Event note(String id) => Event(
        room: timed,
        eventId: id,
        type: EventTypes.Message,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026, 1, 1, 12, 0, clock++),
        content: {
          'msgtype': MessageTypes.Audio,
          'body': 'Voice message',
          'org.matrix.msc3245.voice': <String, Object?>{},
        },
      );
      final source = note(r'$a');
      expect(
        VoicePlaybackQueue.after(
          source,
          [source, note(r'$b')],
          unplayedOnly: false,
          played: (_) => false,
        ),
        isEmpty,
      );
    });

    test('played notes are bounded', () {
      clock = 0;
      final played = VoicePlayedNotes();
      final first = message(r'$first');
      played.add(first);
      for (var i = 0; i < VoicePlayedNotes.capacity; i++) {
        played.add(message('\$n$i'));
      }
      expect(played.length, VoicePlayedNotes.capacity);
      expect(played.contains(first), isFalse);
    });

    test('played notes survive a restart through private storage', () async {
      clock = 0;
      final storage = _MemoryStorage();
      final first = VoicePlayedNotes(storageFor: (_) => storage);
      final old = message(r'$old');
      // Loading: nothing is called unplayed yet (no flash on played notes).
      expect(first.unplayed(old), isFalse);
      await pumpEventQueue();
      // Notes from before the first load count as played (no dot on the
      // whole history after an update).
      expect(first.unplayed(old), isFalse);
      final since = DateTime.parse(storage.value!['since'] as String);
      Event fresh(String id) => Event(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: '@anna:example.invalid',
        originServerTs: since.add(const Duration(minutes: 1)),
        content: {
          'msgtype': MessageTypes.Audio,
          'body': 'Voice message',
          'org.matrix.msc3245.voice': <String, Object?>{},
        },
      );
      final note = fresh(r'$new');
      expect(first.unplayed(note), isTrue);
      first.add(note);
      expect(first.unplayed(note), isFalse);
      await pumpEventQueue();

      final restarted = VoicePlayedNotes(storageFor: (_) => storage);
      restarted.unplayed(note);
      await pumpEventQueue();
      expect(restarted.contains(note), isTrue);
      expect(restarted.unplayed(note), isFalse);
      expect(restarted.unplayed(fresh(r'$other')), isTrue);
      // Own notes and non-voice audio never get a dot.
      expect(
        restarted.unplayed(message(r'$own', sender: client.userID)),
        isFalse,
      );
    });

    test('unavailable storage keeps the session in memory', () async {
      clock = 0;
      final played = VoicePlayedNotes(
        storageFor: (_) => _MemoryStorage()..fail = true,
      );
      final note = message(r'$x');
      played.unplayed(note);
      await pumpEventQueue();
      played.add(note);
      expect(played.contains(note), isTrue);
    });

    test('speed cycle and stored values', () {
      expect(VoicePlayback.nextSpeed(1), 1.25);
      expect(VoicePlayback.nextSpeed(.5), 1);
      expect(VoicePlayback.validSpeed(2), 2);
      expect(VoicePlayback.validSpeed(3.7), 1);
      expect(VoicePlayback.validSpeed(null), 1);
    });
  });

  group('VoiceContinuation', () {
    late RoundPlaybackCoordinator coordinator;
    late RoundContinuationTargets targets;
    setUp(() {
      coordinator = RoundPlaybackCoordinator();
      targets = RoundContinuationTargets();
    });

    Future<List<List<Event>>> run(
      List<Event> queue,
      RoundContinuationToken token,
    ) async {
      final detached = <List<Event>>[];
      await VoiceContinuation.run(
        queue,
        token: token,
        speed: 1.5,
        allowed: () => !coordinator.suspended,
        detached: (items) async => detached.add(items),
        targets: targets,
      );
      return detached;
    }

    test('a mounted next note plays in its row and ends the token', () async {
      clock = 0;
      final b = message(r'$b'), c = message(r'$c');
      final row = _Target((token) => RoundStartResult.started);
      targets.register(b, row);
      final token = coordinator.beginContinuation();
      final detached = await run([b, c], token);
      expect(row.calls.single, [c]);
      expect(detached, isEmpty);
      expect(coordinator.continuing, isFalse);
    });

    test('a failing note is skipped; a note without a row plays detached '
        'with the rest', () async {
      clock = 0;
      final b = message(r'$b'), c = message(r'$c'), d = message(r'$d');
      final failing = _Target((_) => RoundStartResult.failed);
      targets.register(b, failing);
      final token = coordinator.beginContinuation();
      final detached = await run([b, c, d], token);
      expect(failing.calls, hasLength(1));
      expect(ids(detached.single), [r'$c', r'$d']);
    });

    test('an explicit play elsewhere stops the walk', () async {
      clock = 0;
      final b = message(r'$b'), c = message(r'$c');
      final other = coordinator.register(pause: () async {}, stop: () async {});
      final first = _Target((token) {
        // The user taps another player while this note prepares.
        other.acquireAudible();
        return token.active
            ? RoundStartResult.started
            : RoundStartResult.aborted;
      });
      final second = _Target((_) => RoundStartResult.started);
      targets
        ..register(b, first)
        ..register(c, second);
      final token = coordinator.beginContinuation();
      final detached = await run([b, c], token);
      expect(first.calls, hasLength(1));
      expect(second.calls, isEmpty);
      expect(detached, isEmpty);
      expect(token.active, isFalse);
    });

    test('lock or background stops the walk before the next note', () async {
      clock = 0;
      final b = message(r'$b');
      final row = _Target((_) => RoundStartResult.started);
      targets.register(b, row);
      final token = coordinator.beginContinuation();
      await coordinator.stopAll();
      final detached = await run([b], token);
      expect(row.calls, isEmpty);
      expect(detached, isEmpty);
    });

    test('a row recycled while preparing hands the note to the detached '
        'player', () async {
      clock = 0;
      final b = message(r'$b'), c = message(r'$c');
      late _Target row;
      row = _Target((_) {
        targets.unregister(b, row);
        return RoundStartResult.aborted;
      });
      targets.register(b, row);
      final token = coordinator.beginContinuation();
      final detached = await run([b, c], token);
      expect(ids(detached.single), [r'$b', r'$c']);
    });
  });
}
