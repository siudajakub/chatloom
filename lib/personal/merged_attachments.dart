// SPDX-License-Identifier: AGPL-3.0-or-later

/// A merged chat sends attachments with the same dialog as every other chat
/// ([SendFileDialog]: preview, caption, image editing, compression, an
/// optimistic bubble per file). This file adds what is specific to a merged
/// chat's frozen source: the bridge's declared media limits and reply
/// support, checked before anything appears in the chat.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:cross_file/cross_file.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

/// The bridge feature and measurements of one picked file.
typedef MergedAttachmentMeasure = ({
  BridgeFeature feature,
  BridgeMediaRequest media,
});

/// Measures [file] without loading a video into memory: images are decoded
/// only for their size, videos are probed natively (best effort).
Future<MergedAttachmentMeasure> measureMergedAttachment(XFile file) async {
  final size = await file.length();
  final header = size <= 0
      ? null
      : await file
            .openRead(0, size < 64 ? size : 64)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  final mime =
      lookupMimeType(file.name, headerBytes: header) ??
      file.mimeType ??
      'application/octet-stream';
  final kind = MatrixFile.msgTypeFromMime(mime);
  int? width, height;
  double? seconds;
  if (kind == MessageTypes.Image) {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        await file.readAsBytes(),
      );
      ui.ImageDescriptor? descriptor;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        width = descriptor.width;
        height = descriptor.height;
      } finally {
        descriptor?.dispose();
        buffer.dispose();
      }
    } catch (_) {}
  } else if (kind == MessageTypes.Video && file.path.isNotEmpty) {
    try {
      final info = await LightCompressor()
          .getMediaInfo(file.path)
          .timeout(const Duration(seconds: 5));
      width = info.width;
      height = info.height;
      final ms = info.duration?.inMilliseconds;
      seconds = ms == null ? null : ms / 1000;
    } catch (_) {}
  }
  return (
    feature: switch (kind) {
      MessageTypes.Image => BridgeFeature.image,
      MessageTypes.Video => BridgeFeature.video,
      MessageTypes.Audio => BridgeFeature.audio,
      _ => BridgeFeature.upload,
    },
    media: BridgeMediaRequest(
      mimeType: mime,
      sizeBytes: size,
      width: width,
      height: height,
      durationSeconds: seconds,
    ),
  );
}

/// [SendFileDialog.preflight] for a merged chat's source [room]. Refuses
/// what the bridge declares unsupported (with its reason), and asks once
/// before sending what it has not verified (merged chats only offer
/// verified features). [replyTo] must still be in [room] and replyable.
Future<bool> mergedAttachmentPreflight(
  BuildContext context, {
  required Room room,
  required Event? replyTo,
  required List<XFile> files,
  required String caption,
  Future<MergedAttachmentMeasure> Function(XFile file) measure =
      measureMergedAttachment,
}) async {
  final unknown = <String>{};
  for (final file in files) {
    final measured = await measure(file);
    final media = measured.media;
    final result = RoomCapabilities.forFeature(
      measured.feature,
      room,
      media: BridgeMediaRequest(
        mimeType: media.mimeType,
        sizeBytes: media.sizeBytes,
        width: media.width,
        height: media.height,
        durationSeconds: media.durationSeconds,
        caption: caption.isEmpty ? null : caption,
      ),
    );
    if (result.status == CapabilityStatus.unavailable) {
      throw PersonalCapabilityUnavailable(result.reason);
    }
    if (result.status == CapabilityStatus.unverified) {
      unknown.add(result.reason);
    }
  }
  if (replyTo != null) {
    final reply = await room.getEventById(replyTo.eventId);
    final capability = reply == null
        ? null
        : RoomCapabilities.forFeature(BridgeFeature.reply, room, event: reply);
    if (reply == null ||
        reply.redacted ||
        reply.room.id != room.id ||
        capability?.status == CapabilityStatus.unavailable) {
      throw const PersonalCapabilityUnavailable(
        'The message you are replying to is unavailable in this network.',
      );
    }
    if (capability?.status == CapabilityStatus.unverified) {
      unknown.add(capability!.reason);
    }
  }
  if (unknown.isEmpty) return true;
  if (!context.mounted) return false;
  return showNotionConfirmDialog(
    context: context,
    title: 'Not verified for this network',
    message:
        '${unknown.join('\n')}\n\nYou can send it anyway and see whether it arrives.',
    confirmLabel: 'Send anyway',
    cancelLabel: 'Back',
  );
}
