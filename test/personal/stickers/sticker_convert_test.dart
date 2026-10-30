// SPDX-License-Identifier: AGPL-3.0-or-later
// On-device sticker conversion for networks that reject the source format
// (wave 12). The room_features fixtures follow the bridges' declared
// m.sticker capabilities (ChatLoom's mautrix-telegram and mautrix-meta
// forks, upstream mautrix-whatsapp and mautrix-signal, mautrix-slack).
// Offline: fictional media, fake download and upload.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/stickers/sticker_convert.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_send_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';

Map<String, Object?> _mimes(Map<String, int> levels) => {
  'mime_types': levels,
  'caption': 2,
};

final _images = _mimes({
  'image/jpeg': 2,
  'image/png': 2,
  'image/gif': 2,
  'image/webp': 2,
});

final _features = <String, Map<String, Object?>>{
  'telegram': {
    'file': {
      'm.image': _images,
      'm.sticker': _mimes({
        'image/webp': 2,
        'video/lottie+json': 2,
        'video/webm': 2,
        'application/x-tgsticker': 2,
        'image/gif': 1,
        'image/jpeg': 1,
        'image/png': 1,
      }),
    },
  },
  'whatsapp': {
    'file': {
      'm.image': _mimes({
        'image/jpeg': 2,
        'image/png': 1,
        'image/webp': 1,
        'image/gif': 1,
      }),
      'm.sticker': _mimes({
        'image/webp': 2,
        'image/png': 1,
        'image/jpeg': 1,
        'video/lottie+json': 1,
      }),
    },
  },
  'signal': {
    'file': {
      'm.image': _images,
      'm.sticker': _mimes({
        'image/png': 2,
        'image/apng': 2,
        'image/webp': 1,
        'image/gif': 1,
      }),
    },
  },
  'facebookgo': {
    'file': {
      'm.image': _images,
      'm.sticker': _mimes({'image/png': 2, 'image/webp': 2}),
    },
  },
  'slackgo': {
    'file': {'m.image': _images},
  },
};

ConversationRoom _room(String network) {
  final room = ConversationRoom(
    ConversationClient(),
    '!$network:example.invalid',
    network: network,
  );
  room.state(bridgeFeaturesEventType, _features[network]!, key: 'fixture');
  return room;
}

StickerItem _sticker(
  String mime, {
  String origin = 'telegram',
  Map<String, Object?> extra = const {},
}) => StickerItem.fromJson({
  'url': 'mxc://example.invalid/s',
  'body': '😀',
  'info': {
    'mimetype': mime,
    'w': 512,
    'h': 512,
    'fi.mau.bridged_sticker': {
      'network': origin,
      'id': '42',
      'emoji': '😀',
      'pack_url': 'https://t.me/addstickers/FictionalPack',
    },
    ...extra,
  },
}, StickerKind.sticker)!;

/// An animated GIF of [frames] opaque 100×60 frames, 100 ms each.
Uint8List _gif({int frames = 3}) {
  final first = img.Image(width: 100, height: 60, numChannels: 4)
    ..frameDuration = 100;
  img.fill(first, color: img.ColorRgba8(255, 0, 0, 255));
  for (var i = 1; i < frames; i++) {
    final frame = img.Image(width: 100, height: 60, numChannels: 4)
      ..frameDuration = 100;
    img.fill(frame, color: img.ColorRgba8(0, (i * 37) % 256, 255, 255));
    first.addFrame(frame);
  }
  return img.encodeGif(first);
}

/// A 3-frame lossless animated WebP, 24×16 (ffmpeg testsrc, libwebp_anim).
final _animatedWebp = base64Decode(
  'UklGRn4BAABXRUJQVlA4WAoAAAACAAAAFwAADwAAQU5JTQYAAAD/////AABBTk1GfAAAAAAA'
  'AAAAABcAAA8AAGQAAAJWUDhMZAAAAC8XwAMAcBxJkhOVZ+AZeAaeJeq0eCNo2zZmtjH7mf3M'
  'gqBt25jZxuxn9jNL/yciIkopqKqUkogAICKl1AVVd5XyOnqoXNET4p8qY+asEY/DAMvl06JJ'
  'g1Jbt35VvTo17/f0lwJBTk1GYgAAAAAAAAYAABcAAAIAAGQAAABWUDhMSgAAAC8XgAAAmQpE'
  '9D82EdH/MCCEbEVPI4E4Qo8jgXM5gv8MQpKyGi8QR+hxJBBGBtlGqsYJHMehv81rRNYbkj4M'
  'ZYPp0yW5oCn1OIXvQU5NRmQAAAAAAAAGAAAXAAACAABkAAAAVlA4TEsAAAAvF4AAAJkKRPQ/'
  'NhHR/zAghGxFDyCbBEJPIJujOIL/TEWysQFeGwVEV0Ab/wyyjVSAszmBQ3+Bd4rsNyS1GMoV'
  '05MleYWm5HEK3wEA',
);

/// A 64×64, 1 s, 30 fps Lottie: a red square sliding right.
final _lottie = Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'v': '5.7.0',
      'fr': 30,
      'ip': 0,
      'op': 30,
      'w': 64,
      'h': 64,
      'layers': [
        {
          'ty': 4,
          'ind': 1,
          'ip': 0,
          'op': 30,
          'st': 0,
          'ks': {
            'o': {'a': 0, 'k': 100},
            'r': {'a': 0, 'k': 0},
            'p': {
              'a': 1,
              'k': [
                {
                  't': 0,
                  's': [16, 32, 0],
                  'e': [48, 32, 0],
                  'i': {
                    'x': [0.5],
                    'y': [0.5],
                  },
                  'o': {
                    'x': [0.5],
                    'y': [0.5],
                  },
                },
                {'t': 30},
              ],
            },
            'a': {
              'a': 0,
              'k': [0, 0, 0],
            },
            's': {
              'a': 0,
              'k': [100, 100, 100],
            },
          },
          'shapes': [
            {
              'ty': 'rc',
              'p': {
                'a': 0,
                'k': [0, 0],
              },
              's': {
                'a': 0,
                'k': [16, 16],
              },
              'r': {'a': 0, 'k': 0},
            },
            {
              'ty': 'fl',
              'c': {
                'a': 0,
                'k': [1, 0, 0, 1],
              },
              'o': {'a': 0, 'k': 100},
            },
          ],
        },
      ],
    }),
  ),
);

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4e &&
    bytes[3] == 0x47;

/// Whether the PNG has an `acTL` chunk (APNG) before its image data.
bool _isApng(Uint8List bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  final actl = text.indexOf('acTL');
  return actl > 0 && actl < text.indexOf('IDAT');
}

void main() {
  group('plan per network', () {
    StickerSendPlan plan(String network, StickerItem item) =>
        StickerSendPlan.forRoom(_room(network), item);

    test('Telegram takes every Telegram format as it is', () {
      for (final mime in [
        'image/webp',
        'image/gif',
        'application/x-tgsticker',
        'video/lottie+json',
        'video/webm',
      ]) {
        final p = plan('telegram', _sticker(mime));
        expect(p.mode, StickerSendMode.sticker, reason: mime);
        expect(p.conversion, isNull, reason: mime);
        expect(
          (p.content!['info'] as Map)['fi.mau.bridged_sticker'],
          isA<Map>(),
        );
      }
    });

    test('WhatsApp: WebP as it is, GIF and TGS as a still PNG sticker', () {
      expect(
        plan('whatsapp', _sticker('image/webp')).conversion,
        isNull,
        reason: 'static or animated WebP goes out untouched',
      );
      for (final mime in [
        'image/gif',
        'application/x-tgsticker',
        'video/lottie+json',
      ]) {
        final p = plan('whatsapp', _sticker(mime));
        expect(p.mode, StickerSendMode.convertedSticker, reason: mime);
        expect(p.type, EventTypes.Sticker);
        // No Dart WebP encoder: WhatsApp gets stills, never APNG.
        expect(p.conversion!.animatedMime, isNull, reason: mime);
        expect(p.conversion!.staticMime, 'image/png', reason: mime);
        expect(p.content!['body'], '😀');
      }
      // The GIF's fallback is the image it was before.
      expect(
        plan('whatsapp', _sticker('image/gif')).fallback!.mode,
        StickerSendMode.image,
      );
      // TGS has no image fallback.
      expect(
        plan('whatsapp', _sticker('application/x-tgsticker')).fallback!.reason,
        'This sticker can’t be sent to WhatsApp.',
      );
    });

    test('WhatsApp still sends its own Lottie stickers as they are', () {
      final p = plan(
        'whatsapp',
        _sticker('video/lottie+json', origin: 'whatsapp'),
      );
      expect(p.mode, StickerSendMode.sticker);
      expect(p.conversion, isNull);
    });

    test('Signal: animated formats become APNG', () {
      for (final mime in ['application/x-tgsticker', 'video/lottie+json']) {
        final p = plan('signal', _sticker(mime));
        expect(p.mode, StickerSendMode.convertedSticker, reason: mime);
        expect(p.conversion!.animatedMime, 'image/apng');
        expect(p.conversion!.staticMime, 'image/png');
      }
      // WebP and GIF are taken partially: sent as they are unless they
      // animate (Signal clients draw WebP still).
      for (final mime in ['image/webp', 'image/gif']) {
        final p = plan('signal', _sticker(mime));
        expect(p.mode, StickerSendMode.sticker, reason: mime);
        expect(p.conversion!.onlyIfAnimated, isTrue, reason: mime);
        expect(p.fallback!.mode, StickerSendMode.sticker);
        expect(p.fallback!.conversion, isNull);
      }
    });

    test('Messenger: GIF and TGS as a still PNG sticker', () {
      for (final mime in ['image/gif', 'application/x-tgsticker']) {
        final p = plan('facebookgo', _sticker(mime));
        expect(p.mode, StickerSendMode.convertedSticker, reason: mime);
        expect(p.conversion!.animatedMime, isNull);
        expect(p.conversion!.staticMime, 'image/png');
      }
      expect(plan('facebookgo', _sticker('image/webp')).conversion, isNull);
    });

    test('Slack has no stickers: images, no conversion', () {
      expect(
        plan('slackgo', _sticker('image/webp')).mode,
        StickerSendMode.image,
      );
      expect(
        plan('slackgo', _sticker('application/x-tgsticker')).possible,
        isFalse,
      );
    });

    test('a video sticker converts from its poster, else stays as before', () {
      final poster = plan(
        'whatsapp',
        _sticker(
          'video/webm',
          extra: {
            'thumbnail_url': 'mxc://example.invalid/poster',
            'thumbnail_info': {'mimetype': 'image/jpeg'},
          },
        ),
      );
      expect(poster.mode, StickerSendMode.convertedSticker);
      expect(poster.conversion!.fromThumbnail, isTrue);
      expect(poster.conversion!.animatedMime, isNull);

      final bare = plan('whatsapp', _sticker('video/webm'));
      expect(bare.possible, isFalse);
    });

    test('Matrix permissions still win over conversion', () {
      final room = _room('whatsapp')..sendingAllowed = false;
      final p = StickerSendPlan.forRoom(room, _sticker('image/gif'));
      expect(p.possible, isFalse);
      expect(p.conversion, isNull);
    });
  });

  group('converter', () {
    test('GIF → APNG: square, capped side, animated', () async {
      final out = (await StickerConverter.raster(_gif(), animate: true))!;
      expect(out.animated, isTrue);
      expect(_isPng(out.bytes) && _isApng(out.bytes), isTrue);
      final decoded = img.decodePng(out.bytes)!;
      expect(decoded.width, 320);
      expect(decoded.height, 320);
      expect(decoded.numFrames, 3);
    });

    test('GIF → still PNG: 512 square, transparent padding', () async {
      final out = (await StickerConverter.raster(_gif(), animate: false))!;
      expect(out.animated, isFalse);
      expect(_isApng(out.bytes), isFalse);
      final decoded = img.decodePng(out.bytes)!;
      expect((decoded.width, decoded.height), (512, 512));
      expect(decoded.numFrames, 1);
      // 100×60 scaled to 512×307, centred: bands above and below.
      expect(decoded.getPixel(256, 10).a, 0);
      expect(decoded.getPixel(256, 256).a, 255);
      expect(decoded.getPixel(256, 256).r, 255);
    });

    test('a long GIF is cut to 3 s at 15 fps', () async {
      final out = (await StickerConverter.raster(
        _gif(frames: 50),
        animate: true,
      ))!;
      final decoded = img.decodePng(out.bytes)!;
      expect(decoded.numFrames, lessThanOrEqualTo(45));
      final total = decoded.frames.fold<int>(0, (s, f) => s + f.frameDuration);
      expect(total, lessThanOrEqualTo(3000));
      expect(total, greaterThan(2500));
    });

    test('over the byte budget an animation becomes a still', () async {
      final out = (await StickerConverter.raster(
        _gif(frames: 6),
        animate: true,
        limits: const StickerConvertLimits(maxAnimatedBytes: 64),
      ))!;
      expect(out.animated, isFalse);
      expect(_isApng(out.bytes), isFalse);
    });

    test('animated WebP → APNG', () async {
      final out = (await StickerConverter.raster(
        _animatedWebp,
        animate: true,
      ))!;
      expect(out.animated, isTrue);
      expect(img.decodePng(out.bytes)!.numFrames, greaterThan(1));
    });

    test('an upgrade of a still source is skipped', () async {
      final still = img.encodePng(img.Image(width: 8, height: 8));
      expect(
        await StickerConverter.raster(
          Uint8List.fromList(still),
          animate: true,
          onlyIfAnimated: true,
        ),
        isNull,
      );
    });

    test('undecodable data throws', () async {
      await expectLater(
        StickerConverter.raster(
          Uint8List.fromList(List.filled(64, 7)),
          animate: false,
        ),
        throwsA(isA<StickerConvertException>()),
      );
    });

    testWidgets('Lottie → APNG and still', (tester) async {
      await tester.runAsync(() async {
        final animated = await StickerConverter.lottie(_lottie, animate: true);
        expect(animated.animated, isTrue);
        final frames = img.decodePng(animated.bytes)!;
        expect((frames.width, frames.height), (320, 320));
        // 1 s at 15 fps.
        expect(frames.numFrames, inInclusiveRange(2, 15));

        final still = await StickerConverter.lottie(_lottie, animate: false);
        expect(still.animated, isFalse);
        final image = img.decodePng(still.bytes)!;
        expect((image.width, image.height), (512, 512));
        // The square starts at (16, 32) of 64: (128, 256) at 8×.
        expect(image.getPixel(128, 256).a, greaterThan(0));
        expect(image.getPixel(500, 10).a, 0);
      });
    });

    test('not Lottie throws', () async {
      await expectLater(
        StickerConverter.lottie(
          Uint8List.fromList(utf8.encode('{"x":1}')),
          animate: false,
        ),
        throwsA(isA<StickerConvertException>()),
      );
    });
  });

  group('prepared media', () {
    late int downloads;
    late List<MatrixFile> uploads;

    setUp(() {
      StickerConvertedMedia.clear();
      downloads = 0;
      uploads = [];
      StickerConvertedMedia.loader = (client, mxc, file) async {
        downloads++;
        return _gif();
      };
      StickerConvertedMedia.uploader = (room, file) async {
        uploads.add(file);
        return {'url': 'mxc://example.invalid/converted${uploads.length}'};
      };
    });

    test('a converted sticker has fresh info and is cached', () async {
      final room = _room('whatsapp');
      final item = _sticker('image/gif');
      final plan = StickerSendPlan.forRoom(room, item);
      final content = (await StickerConvertedMedia.prepare(
        room,
        item,
        plan.conversion!,
        plan.content!,
      ))!;
      expect(content['url'], 'mxc://example.invalid/converted1');
      expect(content['body'], '😀');
      final info = content['info'] as Map;
      expect(info['mimetype'], 'image/png');
      expect((info['w'], info['h']), (512, 512));
      expect(info['size'], uploads.single.bytes.length);
      expect(info.containsKey('fi.mau.bridged_sticker'), isFalse);
      expect(uploads.single.mimeType, 'image/png');

      final again = await StickerConvertedMedia.prepare(
        room,
        item,
        plan.conversion!,
        plan.content!,
      );
      expect(again, content);
      expect(downloads, 1);
      expect(uploads, hasLength(1));
    });

    test('Signal gets an animated PNG sticker', () async {
      final room = _room('signal');
      final item = _sticker('image/gif');
      final plan = StickerSendPlan.forRoom(room, item);
      final content = (await StickerConvertedMedia.prepare(
        room,
        item,
        plan.conversion!,
        plan.content!,
      ))!;
      expect((content['info'] as Map)['mimetype'], 'image/apng');
      expect(_isApng(uploads.single.bytes), isTrue);
    });

    test('a still source skips the upgrade once', () async {
      StickerConvertedMedia.loader = (client, mxc, file) async {
        downloads++;
        return Uint8List.fromList(
          img.encodePng(img.Image(width: 4, height: 4)),
        );
      };
      final room = _room('signal');
      final item = _sticker('image/webp');
      final plan = StickerSendPlan.forRoom(room, item);
      for (var i = 0; i < 2; i++) {
        expect(
          await StickerConvertedMedia.prepare(
            room,
            item,
            plan.conversion!,
            plan.content!,
          ),
          isNull,
        );
      }
      expect(downloads, 1);
      expect(uploads, isEmpty);
    });

    test('a failed download throws (the sender falls back)', () async {
      StickerConvertedMedia.loader = (client, mxc, file) async =>
          throw Exception('offline');
      final room = _room('whatsapp');
      final item = _sticker('image/gif');
      final plan = StickerSendPlan.forRoom(room, item);
      await expectLater(
        StickerConvertedMedia.prepare(
          room,
          item,
          plan.conversion!,
          plan.content!,
        ),
        throwsException,
      );
      expect(uploads, isEmpty);
    });
  });
}
