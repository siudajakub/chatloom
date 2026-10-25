// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Stickers that do not arrive as `m.sticker`: a sticker ChatLoom sent as
/// an `m.image` or plain `m.video` to a network without stickers
/// (Messenger, Instagram, Slack), or a bridged sticker tagged as one. They
/// are drawn at sticker size, never as a bubble-wide photo.
abstract final class StickerEvents {
  /// `info` flag ChatLoom adds when it sends a sticker as another msgtype.
  /// Bridges ignore unknown `info` keys.
  static const marker = 'pl.personal.chat.sticker';

  /// The body ChatLoom gave stickers sent as images before [marker]
  /// existed (`StickerSendPlan`): `sticker.webp`, `sticker.png`, ...
  static final _legacyBody = RegExp(r'^sticker\.(webp|png|gif|jpe?g)$');

  static Map<String, Object?>? _info(Event event) =>
      event.content.tryGetMap<String, Object?>('info');

  /// Whether [info] carries a sticker hint ([marker] or a bridge's
  /// `fi.mau.bridged_sticker` tag).
  static bool hinted(Map<String, Object?>? info) =>
      info != null &&
      (info[marker] == true || info['fi.mau.bridged_sticker'] is Map);

  /// An `m.image` that is a sticker.
  static bool isImageSticker(Event event) {
    if (event.redacted) return false;
    if (event.messageType != MessageTypes.Image) return false;
    if (hinted(_info(event))) return true;
    final body = event.content['body'];
    return body is String && _legacyBody.hasMatch(body);
  }

  /// An `m.video` ChatLoom sent as a sticker (no GIF flags on that network).
  static bool isVideoStickerHint(Event event) =>
      !event.redacted &&
      event.messageType == MessageTypes.Video &&
      hinted(_info(event));
}
