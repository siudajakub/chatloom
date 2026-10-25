// SPDX-License-Identifier: AGPL-3.0-or-later
// Per-network send adaptation (ST-09). The room_features fixtures follow
// the bridges' declared file capabilities (mautrix-telegram fork,
// mautrix-whatsapp with ffmpeg, mautrix-meta, mautrix-slack). Offline.
import 'package:chatloom/pages/chat/events/sticker_event.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_send_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

Map<String, Object?> _mimes(Map<String, int> levels) => {
  'mime_types': levels,
  'caption': 2,
};

final _features = <String, Map<String, Object?>>{
  'telegram': {
    'file': {
      'm.image': _mimes({
        'image/jpeg': 2,
        'image/webp': 1,
        'image/png': 1,
        'image/gif': 1,
      }),
      'm.video': _mimes({'video/mp4': 2}),
      'fi.mau.gif': _mimes({'image/gif': 1, 'video/mp4': 2}),
      'm.sticker': _mimes({
        'image/webp': 2,
        'video/lottie+json': 2,
        'video/webm': 2,
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
      'm.video': _mimes({'video/mp4': 2, 'video/3gpp': 2}),
      'fi.mau.gif': _mimes({'video/mp4': 2, 'image/gif': 1}),
      'm.sticker': _mimes({
        'image/webp': 2,
        'image/png': 1,
        'image/jpeg': 1,
        'video/lottie+json': 1,
      }),
    },
  },
  'facebookgo': {
    'file': {
      'm.image': _mimes({
        'image/jpeg': 2,
        'image/png': 2,
        'image/gif': 2,
        'image/webp': 2,
      }),
      'm.video': _mimes({'video/mp4': 2, 'video/webm': 2}),
      'fi.mau.gif': _mimes({'image/gif': 2}),
      'm.sticker': _mimes({'image/png': 2, 'image/webp': 2}),
    },
  },
  'slackgo': {
    'file': {
      'm.image': _mimes({
        'image/jpeg': 2,
        'image/png': 2,
        'image/gif': 2,
        'image/webp': 2,
      }),
      'm.video': _mimes({'video/mp4': 2, 'video/webm': 2}),
      'fi.mau.gif': _mimes({'image/gif': 2}),
    },
  },
};

ConversationRoom _room(String network) {
  final room = ConversationRoom(
    ConversationClient(),
    '!$network:example.invalid',
    network: network,
  );
  final features = _features[network];
  if (features != null) {
    room.state(bridgeFeaturesEventType, features, key: 'fixture');
  }
  return room;
}

StickerItem _sticker(String mime, {bool tagged = true}) =>
    StickerItem.fromJson({
      'url': 'mxc://example.invalid/s',
      'body': '😀',
      'info': {
        'mimetype': mime,
        'w': 256,
        'h': 256,
        if (tagged)
          'fi.mau.bridged_sticker': {
            'network': 'telegram',
            'id': '42',
            'emoji': '😀',
            'pack_url': 'https://t.me/addstickers/FictionalPack',
          },
      },
    }, StickerKind.sticker)!;

void main() {
  group('stickers', () {
    test('Telegram: a webp sticker goes as a sticker with its tag', () {
      final plan = StickerSendPlan.forRoom(
        _room('telegram'),
        _sticker('image/webp'),
      );
      expect(plan.mode, StickerSendMode.sticker);
      expect(plan.type, EventTypes.Sticker);
      final info = plan.content!['info'] as Map;
      expect(info['fi.mau.bridged_sticker'], isA<Map>());
      expect(plan.content!.containsKey('msgtype'), isFalse);
    });

    test('Telegram: a GIF sticker the bridge rejects goes as an image', () {
      final plan = StickerSendPlan.forRoom(
        _room('telegram'),
        _sticker('image/gif'),
      );
      expect(plan.mode, StickerSendMode.image);
      expect(plan.content!['msgtype'], MessageTypes.Image);
      expect(plan.content!['body'], 'sticker.gif');
      expect(
        (plan.content!['info'] as Map).containsKey('fi.mau.bridged_sticker'),
        isFalse,
      );
      // ChatLoom draws it at sticker size, not as a photo.
      expect((plan.content!['info'] as Map)[StickerEvents.marker], isTrue);
    });

    test('Telegram: a raw TGS sticker cannot be sent', () {
      final plan = StickerSendPlan.forRoom(
        _room('telegram'),
        _sticker('application/x-tgsticker'),
      );
      expect(plan.possible, isFalse);
      expect(plan.reason, 'This sticker can’t be sent to Telegram.');
    });

    test('WhatsApp: webp is native, a GIF sticker becomes an image', () {
      final room = _room('whatsapp');
      expect(
        StickerSendPlan.forRoom(room, _sticker('image/webp')).mode,
        StickerSendMode.sticker,
      );
      expect(
        StickerSendPlan.forRoom(room, _sticker('image/gif')).mode,
        StickerSendMode.image,
      );
      expect(
        StickerSendPlan.forRoom(
          room,
          _sticker('application/x-tgsticker'),
        ).reason,
        'This sticker can’t be sent to WhatsApp.',
      );
    });

    test('Messenger: png/webp stickers, GIF stickers as images', () {
      final room = _room('facebookgo');
      expect(
        StickerSendPlan.forRoom(room, _sticker('image/webp')).mode,
        StickerSendMode.sticker,
      );
      expect(
        StickerSendPlan.forRoom(room, _sticker('image/gif')).mode,
        StickerSendMode.image,
      );
    });

    test('Slack has no stickers: an image without the sticker tag', () {
      final plan = StickerSendPlan.forRoom(
        _room('slackgo'),
        _sticker('image/webp'),
      );
      expect(plan.mode, StickerSendMode.image);
      expect(plan.content!['body'], 'sticker.webp');
      expect(plan.content!['url'], 'mxc://example.invalid/s');
    });

    test('a plain Matrix room takes the sticker as it is', () {
      final plan = StickerSendPlan.forRoom(
        _room('matrixfixture'),
        _sticker('image/webp', tagged: false),
      );
      expect(plan.mode, StickerSendMode.sticker);
    });

    test('Matrix permissions explain themselves', () {
      final room = _room('telegram')..sendingAllowed = false;
      final plan = StickerSendPlan.forRoom(room, _sticker('image/webp'));
      expect(plan.possible, isFalse);
      // The capability's own plain-language reason (bridge-health lane).
      expect(plan.reason, 'You can’t send messages in this chat.');
    });

    test('an encrypted favourite keeps its file reference', () {
      final item = sticker('enc', encrypted: true);
      final plan = StickerSendPlan.forRoom(_room('telegram'), item);
      expect(plan.content!['file'], isA<Map>());
      expect(plan.content!.containsKey('url'), isFalse);
    });
  });

  group('GIFs', () {
    test('Telegram and WhatsApp get a looping video GIF', () {
      for (final network in ['telegram', 'whatsapp']) {
        final plan = StickerSendPlan.forRoom(_room(network), videoGif('g'));
        expect(plan.mode, StickerSendMode.gifVideo, reason: network);
        expect((plan.content!['info'] as Map)['fi.mau.gif'], isTrue);
        expect(
          (plan.content!['info'] as Map).containsKey(StickerEvents.marker),
          isFalse,
        );
        expect(plan.content!['msgtype'], MessageTypes.Video);
      }
    });

    test('Messenger and Slack take only image GIFs: mp4 goes as a video', () {
      for (final network in ['facebookgo', 'slackgo']) {
        final plan = StickerSendPlan.forRoom(_room(network), videoGif('g'));
        expect(plan.mode, StickerSendMode.video, reason: network);
        final info = plan.content!['info'] as Map;
        expect(info.containsKey('fi.mau.gif'), isFalse, reason: network);
        expect(info.containsKey('fi.mau.loop'), isFalse, reason: network);
        // A GIF is not a sticker: it keeps the media width.
        expect(info.containsKey(StickerEvents.marker), isFalse);
      }
    });

    test('a video sticker sent as a video stays sticker-sized here', () {
      final item = StickerItem.fromJson({
        'url': 'mxc://example.invalid/v',
        'body': '😀',
        'msgtype': MessageTypes.Video,
        'info': {'mimetype': 'video/mp4', 'w': 512, 'h': 512},
      }, StickerKind.sticker)!;
      for (final (network, mode) in [
        ('telegram', StickerSendMode.gifVideo),
        ('facebookgo', StickerSendMode.video),
      ]) {
        final plan = StickerSendPlan.forRoom(_room(network), item);
        expect(plan.mode, mode, reason: network);
        final info = plan.content!['info'] as Map;
        expect(info[StickerEvents.marker], isTrue, reason: network);
      }
      // The library's own entry is untouched.
      expect(item.info.containsKey(StickerEvents.marker), isFalse);
    });

    test('image GIFs go as images everywhere they are accepted', () {
      for (final network in ['telegram', 'whatsapp', 'facebookgo', 'slackgo']) {
        final plan = StickerSendPlan.forRoom(_room(network), imageGif('i'));
        expect(plan.mode, StickerSendMode.image, reason: network);
        expect(plan.content!['msgtype'], MessageTypes.Image);
      }
    });

    test('the GIF declaration is read from fi.mau.gif, not m.video', () {
      final evidence = StickerSendPlan.gifEvidence(
        _room('facebookgo'),
        const BridgeMediaRequest(mimeType: 'video/mp4'),
      );
      expect(evidence.result.status, CapabilityStatus.unavailable);
      expect(
        StickerSendPlan.gifEvidence(
          _room('telegram'),
          const BridgeMediaRequest(mimeType: 'video/mp4'),
        ).result.allowed,
        isTrue,
      );
    });
  });
}
