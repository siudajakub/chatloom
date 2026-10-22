// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_models.dart';

/// How a sticker or GIF goes out to a room.
enum StickerSendMode {
  /// `m.sticker` as it is. With `fi.mau.bridged_sticker` the Telegram
  /// bridge sends the original Telegram sticker.
  sticker,

  /// `m.image` with the same media: networks without stickers (Slack) or
  /// whose bridge rejects the sticker's format get an image.
  image,

  /// `m.video` flagged `fi.mau.gif` (looping, muted): Telegram and
  /// WhatsApp send it as a native GIF.
  gifVideo,

  /// A plain `m.video` (the network takes no video GIFs; it will not
  /// loop there).
  video,

  /// Nothing this room's bridge accepts.
  unsupported,
}

/// Per-network send adaptation (Telegram/WhatsApp native, Messenger and
/// Instagram as images, Slack as an image or file) decided from the room's
/// bridge capability declaration (`com.beeper.room_features`, the same
/// checks the outgoing gate applies), never from the network's name.
@immutable
class StickerSendPlan {
  const StickerSendPlan._(this.mode, this.type, this.content, this.reason);

  final StickerSendMode mode;

  /// The event type to send.
  final String type;

  /// The content to send (null when [mode] is unsupported).
  final Map<String, Object?>? content;

  /// Why it cannot be sent here, in words for people (unsupported only).
  final String? reason;

  bool get possible => mode != StickerSendMode.unsupported;

  static const _gifFlags = [
    'fi.mau.gif',
    'fi.mau.loop',
    'fi.mau.autoplay',
    'fi.mau.hide_controls',
    'fi.mau.no_audio',
  ];

  /// Sendable unless the declaration or Matrix refuses it: an undeclared
  /// (plain Matrix) or unverified feature goes out, exactly as the outgoing
  /// gate lets it.
  static bool _ok(BridgeCapabilityEvidence evidence) =>
      evidence.result.status != CapabilityStatus.unavailable;

  static StickerSendPlan forRoom(Room room, StickerItem item) {
    final media = _media(item);
    if (item.isVideo) return _video(room, item, media);
    if (item.kind == StickerKind.gif) return _imageGif(room, item, media);

    final sticker = RoomCapabilities.evidenceForFeature(
      BridgeFeature.sticker,
      room,
      media: media,
    );
    if (_ok(sticker)) {
      return StickerSendPlan._(
        StickerSendMode.sticker,
        EventTypes.Sticker,
        _stickerContent(item),
        null,
      );
    }
    final image = RoomCapabilities.evidenceForFeature(
      BridgeFeature.image,
      room,
      media: media,
    );
    if (_ok(image)) {
      return StickerSendPlan._(
        StickerSendMode.image,
        EventTypes.Message,
        _imageContent(item),
        null,
      );
    }
    return _unsupported(room, 'sticker', sticker, image);
  }

  static StickerSendPlan _imageGif(
    Room room,
    StickerItem item,
    BridgeMediaRequest? media,
  ) {
    final image = RoomCapabilities.evidenceForFeature(
      BridgeFeature.image,
      room,
      media: media,
    );
    if (_ok(image)) {
      return StickerSendPlan._(
        StickerSendMode.image,
        EventTypes.Message,
        {..._base(item), 'msgtype': MessageTypes.Image},
        null,
      );
    }
    return _unsupported(room, 'GIF', image, null);
  }

  static StickerSendPlan _video(
    Room room,
    StickerItem item,
    BridgeMediaRequest? media,
  ) {
    final video = RoomCapabilities.evidenceForFeature(
      BridgeFeature.video,
      room,
      media: media,
    );
    final gif = gifEvidence(room, media);
    if (_ok(gif) && _ok(video)) {
      return StickerSendPlan._(
        StickerSendMode.gifVideo,
        EventTypes.Message,
        {..._base(item), 'msgtype': MessageTypes.Video},
        null,
      );
    }
    if (_ok(video)) {
      final content = _base(item);
      final info = Map<String, Object?>.of(item.info)
        ..removeWhere((key, _) => _gifFlags.contains(key))
        ..remove('fi.mau.telegram.animated_sticker')
        ..remove('fi.mau.bridged_sticker');
      return StickerSendPlan._(StickerSendMode.video, EventTypes.Message, {
        ...content,
        'msgtype': MessageTypes.Video,
        'info': info,
      }, null);
    }
    return _unsupported(
      room,
      item.kind == StickerKind.gif ? 'GIF' : 'sticker',
      _ok(gif) ? video : gif,
      null,
    );
  }

  /// Support of video GIFs (`m.video` + `fi.mau.gif`): bridgev2 checks them
  /// against `file["fi.mau.gif"]`, not `file["m.video"]` (mautrix-go
  /// `event.MessageEventContent.GetCapMsgType`). The declaration is read the
  /// same way as every other feature, with that file entry in the video
  /// slot. Remove once the capability layer has its own GIF feature (ST-12).
  static BridgeCapabilityEvidence gifEvidence(
    Room room,
    BridgeMediaRequest? media,
  ) {
    final states = room.states[bridgeFeaturesEventType];
    if (states == null || states.isEmpty) {
      return BridgeRoomCapabilities.fromState(
        null,
      ).evidence(BridgeFeature.video, media: media);
    }
    final bridgeKeys = <String>{
      for (final type in const [
        'm.bridge',
        'uk.half-shot.bridge',
        'com.beeper.bridge',
      ])
        ...?room.states[type]?.keys,
    };
    Object? rekey(Object? content) {
      if (content is! Map) return content;
      final file = content['file'];
      return {
        ...content.cast<String, Object?>(),
        'file': file is Map
            ? {if (file['fi.mau.gif'] != null) 'm.video': file['fi.mau.gif']}
            : file,
      };
    }

    return BridgeRoomCapabilities.fromStateEvents(
      {for (final entry in states.entries) entry.key: rekey(entry.value.content)},
      bridgeStateKeys: bridgeKeys,
    ).evidence(BridgeFeature.video, media: media);
  }

  static BridgeMediaRequest? _media(StickerItem item) {
    final mime = item.mimetype;
    if (mime == null || mime.isEmpty) return null;
    final duration = item.info['duration'];
    return BridgeMediaRequest(
      mimeType: mime,
      sizeBytes: item.size,
      width: item.width,
      height: item.height,
      durationSeconds: duration is num ? duration / 1000 : null,
    );
  }

  /// The media reference with `body` and `info`, without library fields.
  static Map<String, Object?> _base(StickerItem item) => {
    if (item.url != null) 'url': item.url,
    if (item.url == null && item.file != null) 'file': item.file,
    'body': item.body,
    'info': Map<String, Object?>.of(item.info),
  };

  static Map<String, Object?> _stickerContent(StickerItem item) {
    final content = _base(item);
    // A sticker's body is its emoji or name (bridges use it as the alt).
    if ((content['body'] as String).trim().isEmpty) {
      content['body'] = item.emoji ?? 'Sticker';
    }
    return content;
  }

  /// A sticker as an image: no caption (bridgev2 reads a body that differs
  /// from the file name as one), no sticker tag.
  static Map<String, Object?> _imageContent(StickerItem item) {
    final info = Map<String, Object?>.of(item.info)
      ..remove('fi.mau.bridged_sticker');
    final extension = switch (item.mimetype) {
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/jpeg' => 'jpg',
      _ => 'webp',
    };
    return {
      ..._base(item),
      'msgtype': MessageTypes.Image,
      'body': 'sticker.$extension',
      'info': info,
    };
  }

  static StickerSendPlan _unsupported(
    Room room,
    String what,
    BridgeCapabilityEvidence first,
    BridgeCapabilityEvidence? second,
  ) {
    // Matrix permissions explain themselves; format refusals get a sentence.
    final permission = [first, ?second]
        .where((e) => e.source == 'matrix.permission')
        .firstOrNull;
    final network = canonicalNetwork(PersonalClient.networkOf(room));
    final label = network == null ? null : notionNetworkLabel(network);
    return StickerSendPlan._(
      StickerSendMode.unsupported,
      EventTypes.Message,
      null,
      permission?.result.reason ??
          (label == null
              ? 'This $what can’t be sent to this chat.'
              : 'This $what can’t be sent to $label.'),
    );
  }
}
