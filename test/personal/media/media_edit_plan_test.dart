// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tenSeconds = Duration(seconds: 10);

  group('EditedPhotoFormat', () {
    test('opaque photos become JPEG, transparent ones PNG', () {
      expect(EditedPhotoFormat.of(hasAlpha: false), EditedPhotoFormat.jpeg);
      expect(EditedPhotoFormat.of(hasAlpha: true), EditedPhotoFormat.png);
      expect(EditedPhotoFormat.jpeg.mimeType, 'image/jpeg');
      expect(EditedPhotoFormat.png.extension, 'png');
    });
  });

  group('editedFileName', () {
    test('replaces the extension', () {
      expect(editedFileName('IMG_0001.HEIC', 'jpg'), 'IMG_0001.jpg');
      expect(editedFileName('clip.final.mov', 'mp4'), 'clip.final.mp4');
    });

    test('adds one to a bare name and names an empty one', () {
      expect(editedFileName('photo', 'png'), 'photo.png');
      expect(editedFileName('.hidden', 'jpg'), '.hidden.jpg');
      expect(editedFileName('', 'jpg'), 'edited.jpg');
    });
  });

  group('VideoEditPlan', () {
    test('a full span, no crop and sound is unchanged', () {
      const plan = VideoEditPlan(
        duration: tenSeconds,
        start: Duration.zero,
        end: tenSeconds,
      );
      expect(plan.isUnchanged, isTrue);
      expect(plan.renderStart, isNull);
      expect(plan.renderEnd, isNull);
    });

    test('ends within the snap slack are no trim', () {
      const plan = VideoEditPlan(
        duration: tenSeconds,
        start: Duration(milliseconds: 30),
        end: Duration(milliseconds: 9970),
      );
      expect(plan.trimmed, isFalse);
      expect(plan.isUnchanged, isTrue);
    });

    test('a trim renders only the trimmed sides', () {
      const plan = VideoEditPlan(
        duration: tenSeconds,
        start: Duration(seconds: 2),
        end: tenSeconds,
      );
      expect(plan.trimmed, isTrue);
      expect(plan.renderStart, const Duration(seconds: 2));
      expect(plan.renderEnd, isNull);
      expect(plan.keptLength, const Duration(seconds: 8));
    });

    test('an end before the start keeps an empty span, never negative', () {
      const plan = VideoEditPlan(
        duration: tenSeconds,
        start: Duration(seconds: 6),
        end: Duration(seconds: 4),
      );
      expect(plan.keptLength, Duration.zero);
    });

    test('mute alone or a crop alone is a change', () {
      expect(
        const VideoEditPlan(duration: tenSeconds, muted: true).isUnchanged,
        isFalse,
      );
      expect(
        const VideoEditPlan(
          duration: tenSeconds,
          crop: VideoCrop(x: 0, y: 0, width: 100, height: 50),
        ).isUnchanged,
        isFalse,
      );
    });
  });

  group('VideoCrop', () {
    test('a quarter turn swaps the shown size', () {
      const crop = VideoCrop(x: 0, y: 0, width: 1920, height: 1080);
      expect(crop.outputSize, const Size(1920, 1080));
      const turned = VideoCrop(
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        quarterTurns: 1,
      );
      expect(turned.outputSize, const Size(1080, 1920));
    });
  });

  group('formatClipLength', () {
    test('minutes and seconds, rounded down', () {
      expect(formatClipLength(const Duration(seconds: 7)), '0:07');
      expect(formatClipLength(const Duration(milliseconds: 59600)), '0:59');
      expect(formatClipLength(const Duration(minutes: 1, seconds: 5)), '1:05');
      expect(
        formatClipLength(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
      expect(formatClipLength(const Duration(seconds: -3)), '0:00');
    });
  });

  group('TrimEdgeTracker', () {
    test('ticks once when a handle reaches a bound', () {
      final tracker = TrimEdgeTracker(duration: tenSeconds)
        ..reset(const Duration(seconds: 2), const Duration(seconds: 8));
      expect(
        tracker.update(const Duration(seconds: 1), const Duration(seconds: 8)),
        isFalse,
      );
      expect(tracker.update(Duration.zero, const Duration(seconds: 8)), isTrue);
      // Resting on the start does not tick again.
      expect(
        tracker.update(Duration.zero, const Duration(seconds: 8)),
        isFalse,
      );
      expect(tracker.update(Duration.zero, tenSeconds), isTrue);
    });

    test('ticks when the span shrinks to the shortest length', () {
      final tracker = TrimEdgeTracker(duration: tenSeconds)
        ..reset(const Duration(seconds: 2), const Duration(seconds: 8));
      expect(
        tracker.update(
          const Duration(seconds: 2),
          const Duration(seconds: 3),
        ),
        isTrue,
      );
    });
  });
}
