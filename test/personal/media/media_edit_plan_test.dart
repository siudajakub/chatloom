// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/media_quality.dart';
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

    test('a crop on the smaller stage maps back to the source', () {
      const crop = VideoCrop(
        x: 100,
        y: 200,
        width: 500,
        height: 900,
        quarterTurns: 3,
        flipX: true,
      );
      final source = crop.toSource(2, const Size(2160, 3840));
      expect(
        source,
        const VideoCrop(
          x: 200,
          y: 400,
          width: 1000,
          height: 1800,
          quarterTurns: 3,
          flipX: true,
        ),
      );
      expect(identical(crop.toSource(1, const Size(1080, 1920)), crop), isTrue);
    });

    test('a mapped crop never leaves the source frame', () {
      const crop = VideoCrop(x: 1000, y: 1900, width: 81, height: 21);
      final source = crop.toSource(2.0001, const Size(2160, 3840));
      expect(source.x + source.width, lessThanOrEqualTo(2160));
      expect(source.y + source.height, lessThanOrEqualTo(3840));
      expect(source.width, greaterThan(0));
    });
  });

  group('videoStageSize', () {
    test('keeps a 1080p stage and halves a 4K one', () {
      expect(videoStageSize(const Size(1080, 1920)), const Size(1080, 1920));
      expect(videoStageSize(const Size(3840, 2160)), const Size(1920, 1080));
      expect(videoStageSize(const Size(2160, 3840)), const Size(1080, 1920));
    });

    test('keeps the aspect of an odd size', () {
      final stage = videoStageSize(const Size(4000, 3000));
      expect(stage, const Size(1920, 1440));
    });
  });

  group('VideoEditPlan.reencodes', () {
    test('an end trim or mute copies, a later start or crop encodes', () {
      expect(
        const VideoEditPlan(
          duration: tenSeconds,
          end: Duration(seconds: 6),
          muted: true,
        ).reencodes,
        isFalse,
      );
      expect(
        const VideoEditPlan(
          duration: tenSeconds,
          start: Duration(seconds: 1),
        ).reencodes,
        isTrue,
      );
      expect(
        const VideoEditPlan(
          duration: tenSeconds,
          crop: VideoCrop(x: 0, y: 0, width: 10, height: 10),
        ).reencodes,
        isTrue,
      );
    });
  });

  group('VideoRenderTarget', () {
    const uhd = Size(2160, 3840);
    const later = VideoEditPlan(
      duration: tenSeconds,
      start: Duration(seconds: 2),
    );

    test('a copy asks for nothing the source does not have', () {
      final target = VideoRenderTarget.of(
        const VideoEditPlan(duration: tenSeconds, end: Duration(seconds: 6)),
        source: uhd,
        sourceBitrate: 40 * 1000 * 1000,
      );
      expect(target, const VideoRenderTarget(outputSize: uhd));
    });

    test('a re-encode of 4K60 lands on 1080p30 at the edit bitrate', () {
      final target = VideoRenderTarget.of(
        later,
        source: uhd,
        sourceBitrate: 40 * 1000 * 1000,
      );
      expect(target.scale, 0.5);
      expect(target.outputSize, const Size(1080, 1920));
      expect(target.bitrate, editedVideoBitrate);
      expect(target.maxFrameRate, editedVideoMaxFps);
      // An HD send can then keep it as it is.
      expect(
        target.bitrate! + MediaQuality.videoAudioBitrate,
        lessThan(MediaQuality.videoHdSkipBitrate),
      );
    });

    test('a lean or small source keeps its own size and bitrate', () {
      final target = VideoRenderTarget.of(
        later,
        source: const Size(720, 1280),
        sourceBitrate: 2 * 1000 * 1000,
      );
      expect(target.scale, isNull);
      expect(target.bitrate, 2 * 1000 * 1000);
      expect(target.outputSize, const Size(720, 1280));
    });

    test('an unknown bitrate takes the edit bitrate', () {
      final target = VideoRenderTarget.of(
        later,
        source: const Size(1080, 1920),
        sourceBitrate: 0,
      );
      expect(target.bitrate, editedVideoBitrate);
    });

    test('a crop is scaled by its own size, after the turn', () {
      final target = VideoRenderTarget.of(
        const VideoEditPlan(
          duration: tenSeconds,
          crop: VideoCrop(
            x: 0,
            y: 0,
            width: 2160,
            height: 2160,
            quarterTurns: 1,
          ),
        ),
        source: uhd,
        sourceBitrate: 40 * 1000 * 1000,
      );
      expect(target.scale, closeTo(1920 / 2160, 1e-9));
      expect(target.outputSize.width, closeTo(1920, 1e-6));
    });

    test('sent as a file, a 4K re-encode keeps size and bitrate at 30 fps', () {
      final target = VideoRenderTarget.of(
        later,
        source: uhd,
        sourceBitrate: 40 * 1000 * 1000,
        keepQuality: true,
      );
      expect(
        target,
        const VideoRenderTarget(
          outputSize: uhd,
          bitrate: 40 * 1000 * 1000,
          maxFrameRate: editedVideoMaxFps,
        ),
      );
    });

    test('sent as a file, 1080p keeps its frame rate; a copy stays a copy', () {
      expect(
        VideoRenderTarget.of(
          later,
          source: const Size(1080, 1920),
          sourceBitrate: 17 * 1000 * 1000,
          keepQuality: true,
        ),
        const VideoRenderTarget(
          outputSize: Size(1080, 1920),
          bitrate: 17 * 1000 * 1000,
        ),
      );
      expect(
        VideoRenderTarget.of(
          const VideoEditPlan(duration: tenSeconds, muted: true),
          source: uhd,
          sourceBitrate: 40 * 1000 * 1000,
          keepQuality: true,
        ),
        const VideoRenderTarget(outputSize: uhd),
      );
    });

    test('the HD fallback is the ceiling, whatever was asked', () {
      final hd = VideoRenderTarget.hd(
        later,
        source: uhd,
        sourceBitrate: 40 * 1000 * 1000,
      );
      expect(hd.scale, 0.5);
      expect(hd.maxFrameRate, editedVideoMaxFps);
      expect(hd.bitrate, editedVideoBitrate);
      expect(
        hd,
        VideoRenderTarget.of(
          later,
          source: uhd,
          sourceBitrate: 40 * 1000 * 1000,
        ),
      );
    });
  });

  group('redactMediaPaths', () {
    test('drops paths and URIs, names with spaces included', () {
      expect(
        redactMediaPaths('open failed: /storage/0/DCIM/Anna birthday.mp4'),
        'open failed: <path>',
      );
      expect(
        redactMediaPaths('No such file /data/user/0/app/a.mp4: ENOENT'),
        'No such file <path>: ENOENT',
      );
      expect(
        redactMediaPaths('source content://media/external/video/42, gone'),
        'source <path>, gone',
      );
      expect(
        redactMediaPaths("Cannot open file, path = '/data/a/Jan K.mp4'"),
        "Cannot open file, path = '<path>'",
      );
    });

    test('drops relative paths and bare media names', () {
      expect(
        redactMediaPaths('copy failed: cache/file_picker/Jan Kowalski.mp4'),
        'copy failed: <path>',
      );
      expect(
        redactMediaPaths('bad header: IMG_20261028 Anna.mp4'),
        'bad header: <path>',
      );
      expect(redactMediaPaths('Anna.MOV is broken'), '<path> is broken');
      final text = redactMediaPaths('Failed to open Jan Kowalski.mp4');
      expect(text, isNot(contains('Jan')));
      expect(text, isNot(contains('Kowalski')));
    });

    test('keeps MIME types and plain text', () {
      expect(
        redactMediaPaths('video/hevc 10-bit HLG at 5500 kbps'),
        'video/hevc 10-bit HLG at 5500 kbps',
      );
      expect(
        redactMediaPaths('sources: [video/avc, audio/mp4a-latm] mp4 output'),
        'sources: [video/avc, audio/mp4a-latm] mp4 output',
      );
      expect(
        redactMediaPaths('ERROR_CODE_DECODER_INIT_FAILED c2.qti.avc.decoder'),
        'ERROR_CODE_DECODER_INIT_FAILED c2.qti.avc.decoder',
      );
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

    test('with whole-second readouts, the end of a 12.7 s clip is 12 s', () {
      final tracker = TrimEdgeTracker(
        duration: const Duration(milliseconds: 12700),
        step: trimBarStep,
      )..reset(Duration.zero, const Duration(milliseconds: 12700));
      // The bar setting itself up at 0–12 s touches nothing new.
      expect(
        tracker.update(Duration.zero, const Duration(seconds: 12)),
        isFalse,
      );
      expect(
        tracker.update(Duration.zero, const Duration(seconds: 11)),
        isFalse,
      );
      expect(
        tracker.update(Duration.zero, const Duration(seconds: 12)),
        isTrue,
      );
      expect(
        tracker.update(const Duration(seconds: 1), const Duration(seconds: 12)),
        isFalse,
      );
      expect(
        tracker.update(Duration.zero, const Duration(seconds: 12)),
        isTrue,
      );
    });

    test('ticks when the span shrinks to the shortest length', () {
      final tracker = TrimEdgeTracker(duration: tenSeconds)
        ..reset(const Duration(seconds: 2), const Duration(seconds: 8));
      expect(
        tracker.update(const Duration(seconds: 2), const Duration(seconds: 3)),
        isTrue,
      );
    });
  });
}
