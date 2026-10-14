// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

// Import actual Dart-only app sources without the Flutter plugin build graph.
// ignore: avoid_relative_lib_imports
import '../../lib/personal/round_video/round_playback_coordinator.dart';
// ignore: avoid_relative_lib_imports
import '../../lib/personal/round_video/round_playback_queue.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('queue assembly must not access storage/network');
}

Event _event(
  Room room,
  String id,
  int seconds, {
  String type = 'm.video',
  Map<String, dynamic> extra = const {},
}) => Event(
  room: room,
  eventId: id,
  senderId: '@fixture:example.invalid',
  originServerTs: DateTime.utc(2026, 1, 1).add(Duration(seconds: seconds)),
  type: EventTypes.Message,
  content: {
    'msgtype': type,
    'body': 'fixture',
    'info': {'fi.mau.telegram.round_message': true},
    ...extra,
  },
);

void main() {
  test(
    'source switch can dispose the previous mini-player without revoking the new permit',
    () async {
      final coordinator = RoundPlaybackCoordinator();
      late RoundPlaybackHandle previous;
      previous = coordinator.register(
        pause: () async {
          previous.dispose();
        },
        stop: () async {},
      );
      expect(await previous.acquireAudible(), isTrue);
      final next = coordinator.register(pause: () async {}, stop: () async {});
      expect(await next.acquireAudible(), isTrue);
      expect(next.isCurrent, isTrue);
    },
  );

  test(
    'live playback transfer retains one audible handle and rebinds cleanup',
    () async {
      final coordinator = RoundPlaybackCoordinator();
      var oldStops = 0, transferredStops = 0, transferredPauses = 0;
      final handle = coordinator.register(
        pause: () async {},
        stop: () async {
          oldStops++;
        },
      );
      expect(await handle.acquireAudible(), isTrue);
      handle.rebind(
        pause: () async {
          transferredPauses++;
        },
        stop: () async {
          transferredStops++;
        },
      );
      expect(handle.isCurrent, isTrue);
      final other = coordinator.register(pause: () async {}, stop: () async {});
      expect(await other.acquireAudible(), isTrue);
      expect(transferredPauses, 1);
      await coordinator.stopAll();
      expect(oldStops, 0);
      expect(transferredStops, 1);
    },
  );

  test(
    'continuation autoplay and a paused seek do not create played intent',
    () {
      final intent = RoundPlaybackIntent();
      intent.begin(position: Duration.zero, userInitiated: false);
      expect(
        intent.didAdvance(
          position: const Duration(seconds: 10),
          isPlaying: true,
          audiblePermit: true,
        ),
        isFalse,
      );
      intent.begin(position: const Duration(seconds: 10), userInitiated: true);
      expect(
        intent.didAdvance(
          position: const Duration(seconds: 10),
          isPlaying: true,
          audiblePermit: true,
        ),
        isFalse,
      );
      expect(
        intent.didAdvance(
          position: const Duration(milliseconds: 10001),
          isPlaying: true,
          audiblePermit: true,
        ),
        isTrue,
      );
      intent.pause();
      expect(
        intent.didAdvance(
          position: const Duration(seconds: 20),
          isPlaying: true,
          audiblePermit: true,
        ),
        isFalse,
      );
    },
  );

  test(
    'queue is chronological, source-bound and never includes limited/protected/video fallback',
    () {
      final client = Client('queue fixture', database: _UnusedDatabase());
      final foreign = Client('foreign fixture', database: _UnusedDatabase());
      final room = Room(id: '!fixture:example.invalid', client: client);
      final source = _event(room, r'$source', 1);
      final voice = _event(room, r'$voice', 2, type: MessageTypes.Audio);
      final round = _event(room, r'$next', 3);
      final wrong = _event(Room(id: room.id, client: foreign), r'$foreign', 4);
      final otherRoom = _event(
        Room(id: '!other:example.invalid', client: client),
        r'$other',
        4,
      );
      final limited = _event(room, r'$limited', 5, extra: {'view_once': true});
      final protected = _event(
        room,
        r'$protected',
        6,
        extra: {'protected_content': true},
      );
      final fallback = _event(
        room,
        r'$ordinary',
        7,
        extra: {
          'info': {'w': 384, 'h': 384},
        },
      );
      final thread = _event(
        room,
        r'$thread',
        8,
        extra: {
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': r'$root'},
        },
      );
      final queue = RoundPlaybackQueue.after(source, [
        thread,
        fallback,
        protected,
        limited,
        otherRoom,
        wrong,
        round,
        source,
        voice,
        round,
      ]);
      expect(queue.map((e) => e.eventId), [r'$voice', r'$next']);
      expect(() => queue.add(round), throwsUnsupportedError);
    },
  );
}
