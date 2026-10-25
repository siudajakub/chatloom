// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_models.dart';

/// Memory cache bucket of panel thumbnails (`MxcImage`'s bounded cache).
const stickerCacheName = 'stickers';

/// The media of a sticker or GIF.
///
/// Grid cells ([preview] false) load the server's small static thumbnail
/// (`isThumbnail`, about the cell size × device pixel ratio) and never
/// animate: animated WebP/GIF thumbnails are paused by the [TickerMode]
/// the grids set, TGS/Lottie shows its first frame. Only the long-press
/// preview loads the original and animates it (unless reduced motion).
/// Video GIFs show their poster in both; the timeline plays them.
class StickerImage extends StatelessWidget {
  const StickerImage({
    super.key,
    required this.item,
    required this.client,
    required this.size,
    this.preview = false,
    this.fit = BoxFit.contain,
    this.borderRadius = NotionRadius.smAll,
  });

  final StickerItem item;
  final Client client;
  final double size;
  final bool preview;
  final BoxFit fit;
  final BorderRadius borderRadius;

  static final _rooms = Expando<Room>('sticker media room');

  /// A detached room for decrypting encrypted media (never listed).
  static Room _mediaRoom(Client client) =>
      _rooms[client] ??= Room(id: '!stickers:chatloom.invalid', client: client);

  /// An event carrying the item's media, for the encrypted download path.
  static Event _event(StickerItem item, Client client) => Event(
    content: {
      ...item.content,
      if (item.msgtype == null && item.kind == StickerKind.gif)
        'msgtype': MessageTypes.Image,
    },
    type: item.msgtype == null && item.kind == StickerKind.sticker
        ? EventTypes.Sticker
        : EventTypes.Message,
    eventId: 'sticker-${item.key.hashCode}',
    senderId: client.userID ?? '',
    originServerTs: DateTime.fromMillisecondsSinceEpoch(0),
    room: _mediaRoom(client),
  );

  @override
  Widget build(BuildContext context) {
    final placeholder = _StickerPlaceholder(item: item, size: size);
    // Grids pause tickers (static cells): a cell shows its image at once
    // instead of fading it in (a muted fade would never finish).
    final fade = preview ? NotionMotion.short : Duration.zero;
    Widget image;
    if (item.isVideo) {
      final poster = item.thumbnailUri;
      if (poster != null) {
        image = MxcImage(
          uri: poster,
          client: client,
          width: size,
          height: size,
          fit: fit,
          isThumbnail: !preview,
          cacheKey: poster.toString(),
          cacheName: stickerCacheName,
          borderRadius: borderRadius,
          placeholder: (_) => placeholder,
          usePlaceholderOnError: true,
          animationDuration: fade,
        );
      } else if (item.info['thumbnail_file'] is Map) {
        image = MxcImage(
          event: _event(item, client),
          client: client,
          width: size,
          height: size,
          fit: fit,
          isThumbnail: true,
          cacheKey: item.key,
          cacheName: stickerCacheName,
          borderRadius: borderRadius,
          placeholder: (_) => placeholder,
          usePlaceholderOnError: true,
          animationDuration: fade,
        );
      } else {
        image = placeholder;
      }
      // A video GIF is marked as one (it plays in the timeline).
      image = Stack(
        alignment: Alignment.bottomLeft,
        children: [
          image,
          const Padding(
            padding: EdgeInsets.all(NotionSpace.xxs),
            child: _GifMark(),
          ),
        ],
      );
    } else if (item.uri != null) {
      image = MxcImage(
        uri: item.uri,
        client: client,
        width: size,
        height: size,
        fit: fit,
        isThumbnail: !preview,
        animated: preview,
        cacheKey: item.key,
        cacheName: stickerCacheName,
        borderRadius: borderRadius,
        placeholder: (_) => placeholder,
        usePlaceholderOnError: true,
        animationDuration: fade,
      );
    } else {
      image = MxcImage(
        event: _event(item, client),
        client: client,
        width: size,
        height: size,
        fit: fit,
        isThumbnail: !preview,
        animated: preview,
        cacheKey: item.key,
        cacheName: stickerCacheName,
        borderRadius: borderRadius,
        placeholder: (_) => placeholder,
        usePlaceholderOnError: true,
        animationDuration: fade,
      );
    }
    return SizedBox.square(
      dimension: size,
      child: Center(child: image),
    );
  }
}

class _StickerPlaceholder extends StatelessWidget {
  const _StickerPlaceholder({required this.item, required this.size});
  final StickerItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final emoji = item.emoji;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: emoji != null
            ? Text(
                emoji,
                style: NotionType.heading.copyWith(
                  color: context.notion.colors.textTertiary,
                ),
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: context.notion.colors.surface,
                  borderRadius: NotionRadius.smAll,
                ),
                child: SizedBox.square(dimension: size * .6),
              ),
      ),
    );
  }
}

class _GifMark extends StatelessWidget {
  const _GifMark();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: NotionMediaColors.scrim,
      borderRadius: NotionRadius.pillAll,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
      child: Text(
        'GIF',
        style: NotionType.micro.copyWith(color: NotionMediaColors.onScrim),
      ),
    ),
  );
}

/// One cell of a sticker or GIF grid: tap sends, long-press previews.
class StickerTile extends StatelessWidget {
  const StickerTile({
    super.key,
    required this.item,
    required this.client,
    required this.size,
    required this.onTap,
    this.onLongPress,
    this.fit = BoxFit.contain,
  });

  final StickerItem item;
  final Client client;
  final double size;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final inset = fit == BoxFit.cover ? NotionSpace.xxs / 2 : NotionSpace.xxs;
    final label = item.kind == StickerKind.gif
        ? 'GIF'
        : item.emoji == null
        ? 'Sticker'
        : 'Sticker ${item.emoji}';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressIcon,
        onTap: onTap,
        // NotionPressable plays the long-press haptic itself.
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.all(inset),
          // Static cells (battery); the long-press preview animates. Only
          // the image: a TickerMode around the grid would also stop the
          // grid's fling and the press motion.
          child: TickerMode(
            enabled: false,
            child: StickerImage(
              item: item,
              client: client,
              size: size - 2 * inset,
              fit: fit,
              borderRadius: fit == BoxFit.cover
                  ? NotionRadius.smAll
                  : NotionRadius.xsAll,
            ),
          ),
        ),
      ),
    );
  }
}

/// One action of the long-press preview.
@immutable
class StickerPreviewAction {
  const StickerPreviewAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onSelected;
  final bool destructive;
}

/// Telegram's sticker preview: the sticker large and animated over a dim
/// page, its actions in a glass card below. [note] explains why sending is
/// not possible here.
Future<void> showStickerPreview(
  BuildContext context, {
  required StickerItem item,
  required Client client,
  required List<StickerPreviewAction> actions,
  String? note,
}) => showNotionCustomDialog<void>(
  context: context,
  builder: (context) =>
      _StickerPreview(item: item, client: client, actions: actions, note: note),
);

class _StickerPreview extends StatelessWidget {
  const _StickerPreview({
    required this.item,
    required this.client,
    required this.actions,
    this.note,
  });

  final StickerItem item;
  final Client client;
  final List<StickerPreviewAction> actions;
  final String? note;

  static const _cardWidth = 252.0;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final size = (shortest * .6).clamp(160.0, 280.0);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NotionSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: RepaintBoundary(
                child: TickerMode(
                  enabled: !NotionMotion.reduced(context),
                  child: StickerImage(
                    item: item,
                    client: client,
                    size: size,
                    preview: true,
                    fit: item.kind == StickerKind.gif
                        ? BoxFit.cover
                        : BoxFit.contain,
                    borderRadius: NotionRadius.mdAll,
                  ),
                ),
              ),
            ),
            if (item.emoji != null && item.kind == StickerKind.sticker) ...[
              const SizedBox(height: NotionSpace.xs),
              Text(item.emoji!, style: NotionType.heading),
            ],
            const SizedBox(height: NotionSpace.md),
            SizedBox(
              width: _cardWidth,
              child: NotionGlassPanel(
                padding: const EdgeInsets.symmetric(vertical: NotionSpace.xxs),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (note != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          NotionSpace.md,
                          NotionSpace.xs,
                          NotionSpace.md,
                          NotionSpace.xxs,
                        ),
                        child: Text(
                          note!,
                          style: notion.typography.captionMuted,
                        ),
                      ),
                    for (final action in actions)
                      NotionGlassMenuRow(
                        leading: Icon(
                          action.icon,
                          color: action.onSelected == null
                              ? notion.colors.textTertiary
                              : action.destructive
                              ? notion.colors.danger
                              : null,
                        ),
                        title: action.label,
                        style: action.onSelected == null
                            ? NotionType.callout.copyWith(
                                color: notion.colors.textTertiary,
                              )
                            : action.destructive
                            ? NotionType.callout.copyWith(
                                color: notion.colors.danger,
                              )
                            : null,
                        onTap: action.onSelected == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                action.onSelected!();
                              },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
