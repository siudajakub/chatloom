// SPDX-License-Identifier: AGPL-3.0-or-later
// The photo encoder on synthetic images (MD-01, MD-02): decoded by the real
// engine of `flutter test`; no file leaves the test.
import 'dart:typed_data';

import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

img.Image _gradient(int width, int height, {bool alpha = false}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  );
  for (final p in image) {
    final transparent = alpha && p.x < width ~/ 2;
    p
      ..r = (p.x * 255 ~/ width)
      ..g = (p.y * 255 ~/ height)
      ..b = 128;
    if (alpha) p.a = transparent ? 0 : 255;
  }
  return image;
}

/// A JPEG whose EXIF holds a GPS position (and optionally an orientation).
Uint8List _jpegWithGps(img.Image image, {int? orientation, int quality = 95}) {
  image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(52, 1);
  image.exif.gpsIfd['GPSLongitude'] = img.IfdValueRational(21, 1);
  image.exif.imageIfd['Make'] = img.IfdValueAscii('Fictional');
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(image, quality: quality);
}

Future<MatrixImageFileResizedResponse?> _encode(
  Uint8List bytes, {
  int maxSide = MediaQuality.photoMaxSide,
  bool blurhash = false,
}) => encodePhoto(
  MatrixImageFileResizeArguments(
    bytes: bytes,
    maxDimension: maxSide,
    fileName: 'fictional',
    calcBlurhash: blurhash,
  ),
);

bool _hasGps(Uint8List jpeg) {
  final exif = img.decodeJpgExif(jpeg);
  return exif != null && !exif.gpsIfd.isEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('header', () {
    test('reads format, transparency and orientation', () {
      expect(
        PhotoHeader.sniff(img.encodePng(_gradient(4, 4, alpha: true))).hasAlpha,
        isTrue,
      );
      expect(
        PhotoHeader.sniff(img.encodePng(_gradient(4, 4))).hasAlpha,
        isFalse,
      );
      final jpeg = PhotoHeader.sniff(
        _jpegWithGps(_gradient(40, 20), orientation: 6),
      );
      expect(jpeg.format, PhotoFormat.jpeg);
      expect(jpeg.orientation, 6);
      expect((jpeg.width, jpeg.height), (40, 20));
      expect(
        PhotoHeader.sniff(Uint8List.fromList('GIF89a....'.codeUnits)).format,
        PhotoFormat.gif,
      );
      expect(
        PhotoHeader.sniff(Uint8List.fromList([1, 2, 3])).format,
        PhotoFormat.other,
      );
    });

    test('reads the VP8X alpha and animation flags of WebP', () {
      final header = PhotoHeader.sniff(_webp(flags: 0x10 | 0x02));
      expect(header.format, PhotoFormat.webp);
      expect(header.hasAlpha, isTrue);
      expect(header.animated, isTrue);
      expect((header.width, header.height), (64, 32));
    });
  });

  group('lossless metadata removal', () {
    test('a JPEG loses EXIF and GPS, its pixels stay identical', () {
      final original = _jpegWithGps(_gradient(64, 48));
      expect(_hasGps(original), isTrue);
      final stripped = stripPhotoMetadata(original);
      expect(_hasGps(stripped), isFalse);
      expect(stripped.length, lessThan(original.length));
      final a = img.decodeJpg(original)!;
      final b = img.decodeJpg(stripped)!;
      expect(b.width, a.width);
      for (var i = 0; i < 64; i += 7) {
        expect(b.getPixel(i, i ~/ 2), a.getPixel(i, i ~/ 2));
      }
    });

    test('a PNG loses its text chunks, nothing else', () {
      final image = _gradient(16, 16, alpha: true)
        ..textData = {'Location': 'fictional place'};
      final original = img.encodePng(image);
      final stripped = stripPhotoMetadata(original);
      expect(
        String.fromCharCodes(stripped).contains('fictional place'),
        isFalse,
      );
      expect(img.decodePng(stripped)!.getPixel(0, 0).a, 0);
    });

    test('a WebP loses EXIF and XMP chunks and their flags', () {
      final original = _webp(flags: 0x08 | 0x04, exif: true);
      final stripped = stripPhotoMetadata(original);
      expect(String.fromCharCodes(stripped).contains('EXIF'), isFalse);
      expect(String.fromCharCodes(stripped).contains('XMP '), isFalse);
      expect(stripped[20] & 0x0C, 0, reason: 'VP8X flags cleared');
      final riff = ByteData.sublistView(stripped).getUint32(4, Endian.little);
      expect(riff, stripped.length - 8);
    });

    test('unknown input is returned unchanged', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      expect(identical(stripPhotoMetadata(bytes), bytes), isTrue);
    });
  });

  group('encoder', () {
    test('a large camera JPEG becomes 2048 px JPEG without GPS', () async {
      final source = _jpegWithGps(_gradient(4000, 3000), quality: 100);
      final out = (await _encode(source))!;
      expect(out.mimeType, 'image/jpeg');
      expect((out.width, out.height), (2048, 1536));
      expect((out.originalWidth, out.originalHeight), (4000, 3000));
      expect(_hasGps(out.bytes), isFalse);
      expect(img.decodeJpgExif(out.bytes)?.imageIfd.isEmpty ?? true, isTrue);
      expect(out.bytes.length, lessThan(700 * 1000));
      final decoded = img.decodeJpg(out.bytes)!;
      expect((decoded.width, decoded.height), (2048, 1536));
    });

    test('a small JPEG is neither upscaled nor re-encoded', () async {
      final source = img.encodeJpg(_gradient(400, 300), quality: 85);
      final out = (await _encode(source))!;
      expect((out.width, out.height), (400, 300));
      expect(out.bytes, source, reason: 'no metadata to remove: same bytes');
    });

    test(
      'a small JPEG with GPS keeps its pixels but not its location',
      () async {
        final source = _jpegWithGps(_gradient(400, 300), quality: 85);
        final out = (await _encode(source))!;
        expect(_hasGps(out.bytes), isFalse);
        expect(out.bytes, stripPhotoMetadata(source));
      },
    );

    test('EXIF orientation 6 ends up upright', () async {
      // Stored 40 × 20, shown rotated: 20 × 40.
      final source = _jpegWithGps(_gradient(40, 20), orientation: 6);
      final out = (await _encode(source))!;
      expect(out.mimeType, 'image/jpeg');
      expect((out.width, out.height), (20, 40));
      final decoded = img.decodeJpg(out.bytes)!;
      expect((decoded.width, decoded.height), (20, 40));
      expect(_hasGps(out.bytes), isFalse);
    });

    test('a transparent PNG stays transparent (never a black JPEG)', () async {
      final small = img.encodePng(_gradient(300, 200, alpha: true));
      final kept = (await _encode(small))!;
      expect(kept.mimeType, 'image/png');
      expect(kept.bytes, small);

      final large = img.encodePng(_gradient(3000, 1000, alpha: true));
      final shrunk = (await _encode(large))!;
      expect(shrunk.mimeType, 'image/png');
      expect((shrunk.width, shrunk.height), (2048, 683));
      final decoded = img.decodePng(shrunk.bytes)!;
      expect(decoded.getPixel(10, 10).a, 0, reason: 'transparent stays so');
      expect(decoded.getPixel(2000, 10).a, 255);
    });

    test('an animated GIF is kept whole', () async {
      final frames = _gradient(120, 80);
      final second = _gradient(120, 80)..clear(img.ColorRgb8(255, 0, 0));
      frames.addFrame(second);
      final gif = img.encodeGif(frames);
      final out = (await _encode(gif, maxSide: 64))!;
      expect(out.bytes, gif);
      expect((out.width, out.height), (120, 80));
    });

    test('thumbnails are 800 px JPEG with a blurhash', () async {
      final source = img.encodeJpg(_gradient(2048, 1536), quality: 90);
      final out = (await _encode(
        source,
        maxSide: MediaQuality.thumbnailMaxSide,
        blurhash: true,
      ))!;
      expect((out.width, out.height), (800, 600));
      expect(out.mimeType, 'image/jpeg');
      expect(out.blurhash, isNotNull);
      expect(out.bytes.length, lessThan(150 * 1000));
    });

    test('unreadable bytes are left to the SDK (null)', () async {
      expect(await _encode(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });
}

/// A minimal RIFF/WebP container: a VP8X chunk (64 × 32 canvas, [flags])
/// and optionally EXIF and XMP chunks; the image chunk is a stub, which is
/// enough for header reading and chunk removal.
Uint8List _webp({required int flags, bool exif = false}) {
  final chunks = BytesBuilder();
  void chunk(String type, List<int> data) {
    chunks.add(type.codeUnits);
    chunks.add(
      Uint8List(4)
        ..buffer.asByteData().setUint32(0, data.length, Endian.little),
    );
    chunks.add(data);
    if (data.length.isOdd) chunks.addByte(0);
  }

  chunk('VP8X', [flags, 0, 0, 0, 63, 0, 0, 31, 0, 0]);
  chunk('VP8L', [0x2f, 0, 0, 0, 0]);
  if (exif) {
    chunk('EXIF', 'fictional-gps'.codeUnits);
    chunk('XMP ', 'fictional-xmp'.codeUnits);
  }
  final body = chunks.takeBytes();
  return (BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(
          Uint8List(4)
            ..buffer.asByteData().setUint32(0, body.length + 4, Endian.little),
        )
        ..add('WEBP'.codeUnits)
        ..add(body))
      .takeBytes();
}
