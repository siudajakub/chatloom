// SPDX-License-Identifier: AGPL-3.0-or-later
// The media quality profile's decisions (MD-01, MD-03, MD-04): pure inputs,
// no images or videos are decoded.
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PhotoPlan photo(
    PhotoFormat format,
    int width,
    int height,
    int bytes, {
    int maxSide = MediaQuality.photoMaxSide,
    bool alpha = false,
    bool animated = false,
    int? orientation,
  }) => PhotoPlan.decide(
    format: format,
    width: width,
    height: height,
    bytes: bytes,
    maxSide: maxSide,
    hasAlpha: alpha,
    animated: animated,
    orientation: orientation,
  );

  group('photos', () {
    test('a 12 MP camera photo becomes a 2048 px JPEG q80 4:2:0', () {
      final plan = photo(PhotoFormat.jpeg, 4080, 3072, 4200000);
      expect(plan.action, PhotoAction.jpeg);
      expect((plan.width, plan.height), (2048, 1542));
      expect(plan.quality, 80);
      expect(plan.fullChroma, isFalse);
    });

    test('portrait keeps its aspect on the long side', () {
      final plan = photo(PhotoFormat.jpeg, 3072, 4080, 4200000);
      expect((plan.width, plan.height), (1542, 2048));
    });

    test('a small efficient JPEG is sent as is, never upscaled', () {
      final plan = photo(PhotoFormat.jpeg, 400, 300, 40000);
      expect(plan.action, PhotoAction.keep);
      expect((plan.width, plan.height), (400, 300));
    });

    test('a JPEG within size but bloated (q100) is re-encoded at its size', () {
      final plan = photo(PhotoFormat.jpeg, 1600, 1200, 1600 * 1200);
      expect(plan.action, PhotoAction.jpeg);
      expect((plan.width, plan.height), (1600, 1200));
    });

    test('a JPEG that still needs rotating is re-encoded upright', () {
      final plan = photo(PhotoFormat.jpeg, 400, 300, 40000, orientation: 6);
      expect(plan.action, PhotoAction.jpeg);
    });

    test('transparent PNG and WebP never become JPEG', () {
      expect(
        photo(PhotoFormat.png, 512, 512, 90000, alpha: true).action,
        PhotoAction.keep,
      );
      final large = photo(PhotoFormat.png, 4000, 2000, 9000000, alpha: true);
      expect(large.action, PhotoAction.png);
      expect((large.width, large.height), (2048, 1024));
      expect(
        photo(PhotoFormat.webp, 3000, 3000, 900000, alpha: true).action,
        PhotoAction.png,
      );
      expect(
        photo(PhotoFormat.gif, 3000, 3000, 900000).action,
        PhotoAction.png,
        reason: 'GIF transparency is per frame: never JPEG',
      );
    });

    test('animated images are kept whole', () {
      expect(
        photo(PhotoFormat.webp, 4000, 4000, 9000000, animated: true).action,
        PhotoAction.keep,
      );
    });

    test('screenshots stay PNG up to 1.5 MB, else JPEG q85 4:4:4', () {
      expect(
        photo(PhotoFormat.png, 1080, 1920, 1200000).action,
        PhotoAction.keep,
      );
      final big = photo(PhotoFormat.png, 1440, 3120, 3000000);
      expect(big.action, PhotoAction.jpeg);
      expect(big.quality, 85);
      expect(big.fullChroma, isTrue);
      expect(big.height, 2048);
    });

    test('HEIF and other formats always become JPEG', () {
      expect(
        photo(PhotoFormat.heif, 1000, 800, 200000).action,
        PhotoAction.jpeg,
      );
      expect(
        photo(PhotoFormat.other, 1000, 800, 200000).action,
        PhotoAction.jpeg,
      );
    });

    test('thumbnails are 800 px JPEG q75', () {
      final plan = photo(
        PhotoFormat.jpeg,
        2048,
        1536,
        500000,
        maxSide: MediaQuality.thumbnailMaxSide,
      );
      expect(plan.action, PhotoAction.jpeg);
      expect((plan.width, plan.height), (800, 600));
      expect(plan.quality, 75);
    });
  });

  group('videos', () {
    test('1080p60 becomes 720p30 at about 2.5 Mbit/s', () {
      final plan = VideoPlan.decide(
        width: 1920,
        height: 1080,
        durationMs: 60000,
        bytes: 120 * 1000 * 1000,
        bitrate: 16000000,
        frameRate: 60,
        mimeType: 'video/mp4',
      );
      expect(plan.skip, isFalse);
      expect((plan.width, plan.height), (1280, 720));
      expect(plan.fps, 30);
      // 60 s × (2.5 + 0.128) Mbit/s ÷ 8 ≈ 19.7 MB.
      expect(plan.targetSizeMb, 20);
    });

    test('4K portrait (stored rotated) keeps the stored frame orientation', () {
      final plan = VideoPlan.decide(
        width: 3840,
        height: 2160,
        durationMs: 10000,
        bytes: 60 * 1000 * 1000,
        bitrate: 48000000,
        frameRate: 30,
      );
      expect((plan.width, plan.height), (1280, 720));
      expect(plan.targetSizeMb, 4);
    });

    test('a lean 720p clip is sent as is', () {
      final plan = VideoPlan.decide(
        width: 1280,
        height: 720,
        durationMs: 30000,
        bytes: 9 * 1000 * 1000,
        bitrate: 2400000,
        frameRate: 30,
        mimeType: 'video/mp4',
      );
      expect(plan.skip, isTrue);
    });

    test('a lean but 60 fps or non-MP4 clip is still re-encoded', () {
      expect(
        VideoPlan.decide(
          width: 1280,
          height: 720,
          durationMs: 30000,
          bytes: 9 * 1000 * 1000,
          bitrate: 2400000,
          frameRate: 60,
          mimeType: 'video/mp4',
        ).skip,
        isFalse,
      );
      expect(
        VideoPlan.decide(
          width: 1280,
          height: 720,
          durationMs: 30000,
          bytes: 9 * 1000 * 1000,
          bitrate: 2400000,
          frameRate: 30,
          mimeType: 'video/quicktime',
        ).skip,
        isFalse,
      );
    });

    test('a tiny clip and an unprobed one are kept', () {
      expect(
        VideoPlan.decide(
          width: 1920,
          height: 1080,
          durationMs: 1000,
          bytes: 900 * 1000,
          frameRate: 30,
        ).skip,
        isTrue,
      );
      expect(
        VideoPlan.decide(
          width: null,
          height: null,
          durationMs: null,
          bytes: 50 * 1000 * 1000,
        ).skip,
        isTrue,
      );
    });

    test('the target never asks for more than the source holds', () {
      final plan = VideoPlan.decide(
        width: 1920,
        height: 1080,
        durationMs: 60000,
        bytes: 12 * 1000 * 1000,
        frameRate: 60,
      );
      expect(plan.targetSizeMb, 12);
    });

    test('dimensions are even', () {
      final plan = VideoPlan.decide(
        width: 1918,
        height: 1077,
        durationMs: 5000,
        bytes: 20 * 1000 * 1000,
        frameRate: 30,
      );
      expect(plan.width.isEven && plan.height.isEven, isTrue);
    });

    test('receivers get the displayed size of a rotated clip', () {
      expect(displaySize(1920, 1080, 90), (1080, 1920));
      expect(displaySize(1920, 1080, 270), (1080, 1920));
      expect(displaySize(1920, 1080, 180), (1920, 1080));
      expect(displaySize(1920, 1080, 0), (1920, 1080));
      expect(displaySize(1920, 1080, null), (1920, 1080));
    });
  });

  group('profiles: automatic by default, HD per send', () {
    test('the default profile is the sweet spot, HD is Telegram HD', () {
      expect(MediaProfile.standard.photoMaxSide, 2048);
      expect(MediaProfile.standard.photoJpegQuality, 80);
      expect(MediaProfile.standard.videoMaxSide, 1280);
      expect(MediaProfile.standard.videoBitrate, 2500000);
      expect(MediaProfile.hd.photoMaxSide, 2560);
      expect(MediaProfile.hd.photoJpegQuality, 85);
      expect(MediaProfile.hd.videoMaxSide, 1920);
      expect(MediaProfile.hd.videoBitrate, 5000000);
      expect(MediaProfile.hd.videoMaxFps, 30);
    });

    test('the photo long side selects the profile (and survives Retry)', () {
      expect(MediaProfile.ofPhotoMaxSide(2048), MediaProfile.standard);
      expect(MediaProfile.ofPhotoMaxSide(2560), MediaProfile.hd);
      expect(
        MediaProfile.ofPhotoMaxSide(MediaQuality.thumbnailMaxSide),
        MediaProfile.standard,
      );
    });

    test('a 50 MP photo: 2048 q80 by default, 2560 q85 in HD', () {
      final normal = photo(PhotoFormat.jpeg, 8160, 6144, 12000000);
      expect(normal.action, PhotoAction.jpeg);
      expect((normal.width, normal.height), (2048, 1542));
      expect(normal.quality, 80);
      final hd = photo(
        PhotoFormat.jpeg,
        8160,
        6144,
        12000000,
        maxSide: MediaProfile.hd.photoMaxSide,
      );
      expect(hd.action, PhotoAction.jpeg);
      expect((hd.width, hd.height), (2560, 1928));
      expect(hd.quality, 85);
      expect(hd.fullChroma, isFalse);
    });

    test('HD still re-encodes HEIF (no EXIF/GPS) and never upscales', () {
      final heif = photo(
        PhotoFormat.heif,
        1600,
        1200,
        900000,
        maxSide: MediaQuality.photoHdMaxSide,
      );
      expect(heif.action, PhotoAction.jpeg);
      expect((heif.width, heif.height), (1600, 1200));
      expect(heif.quality, 85);
    });

    test('HD thumbnails stay 800 px q75', () {
      final thumb = photo(
        PhotoFormat.jpeg,
        8160,
        6144,
        12000000,
        maxSide: MediaQuality.thumbnailMaxSide,
      );
      expect(thumb.quality, 75);
    });

    test('a 4K60 clip: 720p30 ~2.5 Mbit/s by default, 1080p30 ~5 in HD', () {
      VideoPlan plan(MediaProfile profile) => VideoPlan.decide(
        width: 3840,
        height: 2160,
        durationMs: 60000,
        bytes: 400 * 1000 * 1000,
        bitrate: 50000000,
        frameRate: 60,
        mimeType: 'video/mp4',
        profile: profile,
      );
      final normal = plan(MediaProfile.standard);
      expect((normal.width, normal.height), (1280, 720));
      expect(normal.fps, 30);
      expect(normal.targetSizeMb, 20);
      expect(normal.profile, MediaProfile.standard);
      final hd = plan(MediaProfile.hd);
      expect(hd.skip, isFalse);
      expect((hd.width, hd.height), (1920, 1080));
      expect(hd.fps, 30);
      // 60 s × (5 + 0.128) Mbit/s ÷ 8 ≈ 38.5 MB.
      expect(hd.targetSizeMb, 39);
      expect(hd.profile, MediaProfile.hd);
    });

    test('the default is the standard profile', () {
      final plan = VideoPlan.decide(
        width: 1920,
        height: 1080,
        durationMs: 10000,
        bytes: 20 * 1000 * 1000,
        bitrate: 16000000,
        frameRate: 30,
      );
      expect(plan.profile, MediaProfile.standard);
      expect((plan.width, plan.height), (1280, 720));
    });

    test('a lean 1080p30 clip is kept in HD but shrunk by default', () {
      VideoPlan plan(MediaProfile profile) => VideoPlan.decide(
        width: 1920,
        height: 1080,
        durationMs: 30000,
        bytes: 22 * 1000 * 1000,
        bitrate: 6000000,
        frameRate: 30,
        mimeType: 'video/mp4',
        profile: profile,
      );
      expect(plan(MediaProfile.hd).skip, isTrue);
      expect(plan(MediaProfile.standard).skip, isFalse);
    });

    test('HD never upscales a 720p clip', () {
      final plan = VideoPlan.decide(
        width: 1280,
        height: 720,
        durationMs: 30000,
        bytes: 40 * 1000 * 1000,
        bitrate: 10000000,
        frameRate: 60,
        mimeType: 'video/mp4',
        profile: MediaProfile.hd,
      );
      expect(plan.skip, isFalse);
      expect((plan.width, plan.height), (1280, 720));
    });
  });

  test('voice notes are 32 kbit/s Opus', () {
    expect(MediaQuality.voiceOpusBitrate, 32000);
  });
}
