// SPDX-License-Identifier: AGPL-3.0-or-later
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

/// Upload progress of [event] (see [UploadProgress]).
ValueListenable<double?> uploadProgressOf(Event event) =>
    UploadProgress.of(event.transactionId ?? event.eventId);

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
/// a fast send never flashes it, and it never takes taps.
class OutgoingUploadOverlay extends StatelessWidget {
  final ValueListenable<double?> progress;

  const OutgoingUploadOverlay({super.key, required this.progress});

  static const double _ring = NotionSize.touchTarget - 2 * NotionSpace.xs;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: NotionDelayedReveal(
      child: SizedBox.square(
        key: const ValueKey('outgoing-upload-overlay'),
        dimension: NotionSize.touchTarget,
        child: DecoratedBox(
          decoration: const ShapeDecoration(
            shape: CircleBorder(),
            color: NotionMediaColors.scrim,
          ),
          child: Padding(
            padding: const EdgeInsets.all(NotionSpace.xs),
            child: OutgoingUploadIndicator(
              progress: progress,
              size: _ring,
              strokeWidth: 2.5,
              color: NotionMediaColors.onScrim,
            ),
          ),
        ),
      ),
    ),
  );
}
