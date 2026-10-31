// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A deleted message whose content "Keep deleted messages" kept: its text
/// (for media, the label and a thumbnail that is still in the local cache)
/// dimmed, with a "Deleted" chip. A tap says when it was deleted. Nothing
/// here downloads, decodes HTML or loads link previews.
class KeptMessageContent extends StatelessWidget {
  final KeptMessage kept;

  /// The redacted event in the timeline (room, client).
  final Event event;
  final Color textColor;
  final double fontSize;

  const KeptMessageContent({
    super.key,
    required this.kept,
    required this.event,
    required this.textColor,
    required this.fontSize,
  });

  /// Opacity of kept content: readable, visibly not a live message.
  static const dimmed = .62;

  static const _textTypes = {
    MessageTypes.Text,
    MessageTypes.Notice,
    MessageTypes.Emote,
    MessageTypes.None,
  };

  static const _thumbnailTypes = {MessageTypes.Image, MessageTypes.Sticker};

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final copy = kept.toEvent(event.room);
    final text =
        copy.type == EventTypes.Message &&
        _textTypes.contains(copy.messageType);
    final body = text
        ? copy.calcUnlocalizedBody(
            hideReply: true,
            plaintextBody: true,
            removeMarkdown: true,
          )
        : personalPreviewLabel(copy, i18n: MatrixLocals(l10n));
    final color = textColor.withValues(alpha: dimmed);
    return Semantics(
      button: true,
      hint: l10n.deletedAtTime(kept.deletedAt.localizedDetailedTime(context)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showKeptMessageInfo(context, kept),
        child: Padding(
          padding: NotionBubble.textLine,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!text && _thumbnailTypes.contains(copy.messageType))
                Padding(
                  padding: const EdgeInsets.only(bottom: NotionSpace.xxs),
                  child: _CachedThumbnail(event: copy, color: color),
                ),
              Text(
                body,
                style: NotionType.body.copyWith(
                  fontSize: fontSize,
                  color: color,
                ),
              ),
              const SizedBox(height: NotionSpace.xxs),
              KeptDeletedChip(label: l10n.keptDeletedLabel, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Deleted" mark of a kept message: a hairline pill in the content's
/// own (dimmed) colour, never a status colour.
class KeptDeletedChip extends StatelessWidget {
  final String label;
  final Color color;

  const KeptDeletedChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: NotionRadius.pillAll,
      border: Border.all(color: color),
    ),
    child: Padding(
      padding: NotionBubble.tagPadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.delete_outline,
            size: MediaQuery.textScalerOf(
              context,
            ).scale(NotionType.caption.fontSize!),
            color: color,
          ),
          const SizedBox(width: NotionSpace.xxs),
          Text(label, style: NotionType.caption.copyWith(color: color)),
        ],
      ),
    ),
  );
}

/// "Deleted at {date time}", for a tap on a kept message.
Future<void> showKeptMessageInfo(BuildContext context, KeptMessage kept) {
  final l10n = L10n.of(context);
  return showNotionDialog<void>(
    context: context,
    title: l10n.deletedAtTime(kept.deletedAt.localizedDetailedTime(context)),
    message: l10n.keptOnThisDevice,
    actions: (context) => [
      NotionButton(
        label: l10n.close,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );
}

/// A kept photo's thumbnail when it is still in the local media store;
/// otherwise a static glyph. Never downloads (`fromLocalStoreOnly`).
class _CachedThumbnail extends StatefulWidget {
  final Event event;
  final Color color;
  const _CachedThumbnail({required this.event, required this.color});

  @override
  State<_CachedThumbnail> createState() => _CachedThumbnailState();
}

class _CachedThumbnailState extends State<_CachedThumbnail> {
  late final Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() async {
    final event = widget.event;
    for (final thumbnail in [true, false]) {
      try {
        final file = await event.downloadAndDecryptAttachment(
          getThumbnail: thumbnail,
          fromLocalStoreOnly: true,
        );
        return file.bytes;
      } catch (_) {
        // Not in the local store: never fetched after deletion.
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      return ClipRRect(
        borderRadius: NotionRadius.smAll,
        child: SizedBox.square(
          dimension: NotionBubble.quoteThumbnail * 2,
          child: bytes == null
              ? Icon(Icons.image_outlined, color: widget.color)
              : Opacity(
                  opacity: KeptMessageContent.dimmed,
                  child: Image.memory(bytes, fit: BoxFit.cover),
                ),
        ),
      );
    },
  );
}
