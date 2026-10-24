// SPDX-License-Identifier: AGPL-3.0-or-later

/// Captions a network drops or cannot take (BR-04): Instagram declares
/// captions on media as dropped, encrypted Messenger chats too, and
/// Telegram refuses captions over its `max_caption_length` (1024). Telegram
/// and Instagram themselves send such a caption as a text right after the
/// media, so ChatLoom does the same instead of losing it or refusing the
/// whole send.
library;

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

abstract final class CaptionFollowUp {
  /// Test seam: replaces the durable text send.
  @visibleForTesting
  static Future<void> Function(Room room, String text, String? threadId)?
  debugSender;

  /// Shown once in the send preview when the caption will be split.
  static const notice = 'This network shows the caption as a separate message.';

  /// Whether a [caption] on media of [mimeType] must travel as its own
  /// message in [room]: the bridge accepts the media itself but declares the
  /// caption dropped, rejected or too long. Unknown or unverified
  /// declarations keep the caption on the media (as before).
  static bool needsSplit(
    Room room, {
    required String mimeType,
    required String caption,
  }) {
    if (caption.trim().isEmpty) return false;
    final feature = switch (MatrixFile.msgTypeFromMime(mimeType)) {
      MessageTypes.Image => BridgeFeature.image,
      MessageTypes.Video => BridgeFeature.video,
      MessageTypes.Audio => BridgeFeature.audio,
      _ => BridgeFeature.upload,
    };
    // Measurements of 0 pass every size limit, so the two probes differ
    // only in the caption.
    BridgeMediaRequest probe(String? text) => BridgeMediaRequest(
      mimeType: mimeType,
      sizeBytes: 0,
      width: 0,
      height: 0,
      durationSeconds: 0,
      caption: text,
    );
    try {
      final media = RoomCapabilities.forFeature(
        feature,
        room,
        media: probe(null),
      );
      if (!media.allowed) return false;
      final captioned = RoomCapabilities.forFeature(
        feature,
        room,
        media: probe(caption),
      );
      return captioned.status == CapabilityStatus.unavailable;
    } catch (_) {
      return false;
    }
  }

  /// Sends [caption] as a text through the encrypted outbox (the composer's
  /// own path), in the media's thread, after the media.
  static Future<void> send(Room room, String caption, {String? threadId}) {
    final sender = debugSender;
    if (sender != null) return sender(room, caption, threadId);
    return PersonalClient.of(room.client)
        .sendImmediate(room, caption, threadId: threadId)
        .then<void>((_) {});
  }
}
