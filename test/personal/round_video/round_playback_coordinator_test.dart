import 'dart:async';

import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
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
}
