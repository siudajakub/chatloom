// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/upload_progress.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Whether [event] is an own photo, video, voice message or file that the
/// server does not have yet: its bubble shows the upload.
bool isOutgoingUpload(Event event) =>
    event.status.isSending &&
    event.senderId == event.room.client.userID &&
    const {
      MessageTypes.Image,
      MessageTypes.Video,
      MessageTypes.Audio,
      MessageTypes.File,
    }.contains(event.messageType);

/// Upload progress of [event] (see [UploadProgress]). It carries the
/// event, so the upload disc can offer to cancel it (MD-17).
ValueListenable<double?> uploadProgressOf(Event event) =>
    OutgoingUploadProgress._(
      event,
      UploadProgress.of(event.transactionId ?? event.eventId),
    );

/// [uploadProgressOf]: the progress of one own upload and its event.
class OutgoingUploadProgress implements ValueListenable<double?> {
  final Event event;
  final ValueListenable<double?> _progress;

  OutgoingUploadProgress._(this.event, this._progress);

  @override
  double? get value => _progress.value;

  @override
  void addListener(VoidCallback listener) => _progress.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _progress.removeListener(listener);

  /// Equal for the same upload, so a rebuilt bubble keeps its listener.
  @override
  bool operator ==(Object other) =>
      other is OutgoingUploadProgress &&
      identical(other._progress, _progress) &&
      other.event.eventId == event.eventId;

  @override
  int get hashCode => Object.hash(identityHashCode(_progress), event.eventId);
}

/// Whether the upload behind [progress] can be cancelled from its disc:
/// a photo, video or file ChatLoom's own send job is still sending.
bool canCancelUpload(ValueListenable<double?> progress) =>
    progress is OutgoingUploadProgress &&
    OutgoingMedia.isActive(progress.event);

/// Telegram's "×" on an upload: the compression or upload stops, the
/// bubble goes and nothing is sent (an upload the server already
/// accepted cannot be called back).
Future<void> cancelUpload(OutgoingUploadProgress progress) async {
  final event = progress.event;
  if (!OutgoingMedia.isActive(event)) return;
  try {
    await MessageDeliveryActions.discard(event);
  } catch (e) {
    Logs().w('Upload could not be cancelled', e.runtimeType);
  }
}

/// The ring of an own upload: it fills with the bytes sent and spins while
/// the file is prepared (compression, encryption) or the final message is
/// sent. Only this widget rebuilds on progress.
class OutgoingUploadIndicator extends StatelessWidget {
  final ValueListenable<double?> progress;
  final double size, strokeWidth;
  final Color? color, track;

  const OutgoingUploadIndicator({
    super.key,
    required this.progress,
    this.size = NotionSize.iconSm,
    this.strokeWidth = 2,
    this.color,
    this.track,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, value, _) => CircularProgressIndicator(
        key: const ValueKey('outgoing-upload-indicator'),
        // Determinate only while bytes go out.
        value: value == null || value >= 1 ? null : value,
        strokeWidth: strokeWidth,
        color: color ?? context.notion.colors.textSecondary,
        backgroundColor: track,
      ),
    ),
  );
}

/// Telegram's upload disc over a photo, video or round while it uploads:
/// a scrim disc with the ring. It appears only after the loader grace, so
/// a fast send never flashes it. While ChatLoom's own job sends the file it
/// shows an "×" and a tap cancels the send ([cancelUpload]); otherwise
/// (rounds) it takes no taps.
class OutgoingUploadOverlay extends StatelessWidget {
  final ValueListenable<double?> progress;

  const OutgoingUploadOverlay({super.key, required this.progress});

  static const double _ring = NotionSize.touchTarget - 2 * NotionSpace.xs;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    final cancellable = canCancelUpload(progress);
    final disc = SizedBox.square(
      key: const ValueKey('outgoing-upload-overlay'),
      dimension: NotionSize.touchTarget,
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          shape: CircleBorder(),
          color: NotionMediaColors.scrim,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(NotionSpace.xs),
              child: OutgoingUploadIndicator(
                progress: progress,
                size: _ring,
                strokeWidth: 2.5,
                color: NotionMediaColors.onScrim,
              ),
            ),
            if (cancellable)
              const Icon(
                Icons.close_rounded,
                size: NotionSize.icon,
                color: NotionMediaColors.onScrim,
              ),
          ],
        ),
      ),
    );
    if (!cancellable || progress is! OutgoingUploadProgress) {
      return IgnorePointer(child: NotionDelayedReveal(child: disc));
    }
    return NotionDelayedReveal(
      child: Semantics(
        button: true,
        label: 'Cancel upload',
        child: Tooltip(
          message: 'Cancel upload',
          child: NotionPressable(
            scale: NotionMotion.pressIcon,
            onTap: () => unawaited(cancelUpload(progress)),
            child: disc,
          ),
        ),
      ),
    );
  }
}
