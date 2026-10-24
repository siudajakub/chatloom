import 'dart:async';

import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'played intent requires advancing after user start, including seek/resume',
    () {
      final intent = RoundPlaybackIntent();
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
      expect(
        intent.didAdvance(
          position: const Duration(seconds: 11),
          isPlaying: true,
          audiblePermit: false,
        ),
        isFalse,
      );
      intent.pause();
      expect(
        intent.didAdvance(
          position: const Duration(seconds: 11),
          isPlaying: true,
          audiblePermit: true,
        ),
        isFalse,
      );
    },
  );

  test('muted autoplay progress never creates played intent', () {
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
  });

  test('a new audible player waits until the old one pauses', () async {
    final coordinator = RoundPlaybackCoordinator();
    final pause = Completer<void>();
    final first = coordinator.register(
      pause: () => pause.future,
      stop: () async {},
    );
    final second = coordinator.register(pause: () async {}, stop: () async {});
    expect(await first.acquireAudible(), isTrue);
    final next = second.acquireAudible();
    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isFalse);
    pause.complete();
    expect(await next, isTrue);
    expect(second.isCurrent, isTrue);
  });

  test('suspension invalidates an acquisition while pausing', () async {
    final coordinator = RoundPlaybackCoordinator();
    final pause = Completer<void>();
    var stops = 0;
    final first = coordinator.register(
      pause: () => pause.future,
      stop: () async {
        stops++;
      },
    );
    final second = coordinator.register(
      pause: () async {},
      stop: () async {
        stops++;
      },
    );
    await first.acquireAudible();
    final pending = second.acquireAudible();
    await Future<void>.delayed(Duration.zero);
    final stopped = coordinator.stopAll();
    pause.complete();
    expect(await pending, isFalse);
    await stopped;
    expect(stops, 2);
    expect(await first.acquireAudible(), isFalse);
    coordinator.resume();
    expect(first.isCurrent, isFalse);
    expect(await first.acquireAudible(), isTrue);
  });

  test('failed pause cannot allow two audible players', () async {
    final coordinator = RoundPlaybackCoordinator();
    final first = coordinator.register(
      pause: () async {
        throw StateError('fixture');
      },
      stop: () async {},
    );
    final second = coordinator.register(pause: () async {}, stop: () async {});
    await first.acquireAudible();
    await expectLater(second.acquireAudible(), throwsStateError);
    expect(second.isCurrent, isFalse);
    await expectLater(second.acquireAudible(), throwsStateError);
  });

  test(
    'stop attempts every player and stays suspended after a failure',
    () async {
      final coordinator = RoundPlaybackCoordinator();
      var stopped = 0;
      coordinator.register(
        pause: () async {},
        stop: () async {
          throw StateError('fixture');
        },
      );
      final second = coordinator.register(
        pause: () async {},
        stop: () async {
          stopped++;
        },
      );
      await expectLater(coordinator.stopAll(suspend: false), throwsStateError);
      expect(stopped, 1);
      expect(coordinator.suspended, isTrue);
      coordinator.resume();
      expect(coordinator.suspended, isTrue);
      expect(await second.acquireAudible(), isFalse);
    },
  );

  test('a disposed player cannot reacquire an audible permit', () async {
    final coordinator = RoundPlaybackCoordinator();
    final handle = coordinator.register(pause: () async {}, stop: () async {});
    await handle.acquireAudible();
    handle.dispose();
    expect(handle.isCurrent, isFalse);
    expect(await handle.acquireAudible(), isFalse);
  });
  test('background retain pauses voice and stops everything else', () async {
    final coordinator = RoundPlaybackCoordinator();
    final calls = <String>[];
    final voice = coordinator.register(
      pause: () async => calls.add('voice pause'),
      stop: () async => calls.add('voice stop'),
      retain: () async => calls.add('voice retain'),
    );
    coordinator.register(
      pause: () async => calls.add('round pause'),
      stop: () async => calls.add('round stop'),
    );
    expect(await voice.acquireAudible(), isTrue);
    await coordinator.stopAll(retain: true);
    expect(calls, ['voice retain', 'round stop']);
    expect(voice.isCurrent, isFalse);
    expect(coordinator.suspended, isTrue);
    expect(await voice.acquireAudible(), isFalse);
    // A lock (or account switch) still stops the retained voice player.
    calls.clear();
    await coordinator.stopAll();
    expect(calls, ['voice stop', 'round stop']);
    coordinator.resume();
    expect(await voice.acquireAudible(), isTrue);
  });

  test('a hidden desktop window spares voice: it stays current and its '
      'queue may continue, while videos stop (MAC-04)', () async {
    final coordinator = RoundPlaybackCoordinator();
    final calls = <String>[];
    final voice = coordinator.register(
      pause: () async => calls.add('voice pause'),
      stop: () async => calls.add('voice stop'),
      retain: () async => calls.add('voice retain'),
      keepWhileHidden: true,
    );
    coordinator.register(
      pause: () async => calls.add('video pause'),
      stop: () async => calls.add('video stop'),
    );
    expect(await voice.acquireAudible(), isTrue);
    await coordinator.stopAll(retain: true, spareHidden: true);
    expect(calls, ['video stop']);
    expect(voice.isCurrent, isTrue);
    expect(coordinator.suspended, isFalse);
    final next = coordinator.beginContinuation();
    expect(next.active, isTrue, reason: 'the next voice note may play');
    next.end();

    // A lock (or phones' background) still stops or pauses voice.
    calls.clear();
    await coordinator.stopAll(retain: true);
    expect(calls, ['voice retain', 'video stop']);
    expect(voice.isCurrent, isFalse);
    expect(coordinator.suspended, isTrue);
  });

  test('sparing keeps nothing audible when the voice is not playing', () async {
    final coordinator = RoundPlaybackCoordinator();
    final voice = coordinator.register(
      pause: () async {},
      stop: () async {},
      keepWhileHidden: true,
    );
    final video = coordinator.register(pause: () async {}, stop: () async {});
    expect(await video.acquireAudible(), isTrue);
    await coordinator.stopAll(retain: true, spareHidden: true);
    expect(video.isCurrent, isFalse);
    expect(voice.isCurrent, isFalse);
    expect(coordinator.continuing, isFalse);
  });
}
