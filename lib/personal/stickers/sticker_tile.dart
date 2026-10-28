// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_models.dart';

/// Memory cache bucket of panel thumbnails (`MxcImage`'s bounded cache).
const stickerCacheName = 'stickers';

/// The media of a sticker or GIF.
///
/// Grid cells ([preview] false) load the server's small static thumbnail
/// (`isThumbnail`, about the cell size × device pixel ratio); TGS/Lottie
/// stickers play only while the grid lets them ([StickerTile.animate]),
/// otherwise they show their first frame. A cell built during a fast
/// fling waits with its placeholder until the fling slows down
/// ([Scrollable.recommendDeferredLoadingForContext]), so cells that only
/// fly past never download, decrypt or parse. Only the long-press preview
/// loads the original and animates it (unless reduced motion). Video GIFs
/// show their poster in both; the timeline plays them.
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
    if (!preview) {
      image = _ScrollAwareLoad(placeholder: placeholder, child: image);
    }
    return SizedBox.square(
      dimension: size,
      child: Center(child: image),
    );
  }
}

/// Shows [placeholder] instead of [child] while the enclosing scrollable
/// moves too fast to load media (the same rule as Flutter's
/// `ScrollAwareImageProvider`, which only covers decoding): re-checked
/// once per frame, no timers.
class _ScrollAwareLoad extends StatefulWidget {
  const _ScrollAwareLoad({required this.placeholder, required this.child});

  final Widget placeholder;
  final Widget child;

  @override
  State<_ScrollAwareLoad> createState() => _ScrollAwareLoadState();
}

class _ScrollAwareLoadState extends State<_ScrollAwareLoad> {
  bool? _ready;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready != null) return;
    _ready = !Scrollable.recommendDeferredLoadingForContext(context);
    if (!_ready!) _recheck();
  }

  void _recheck() {
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (!mounted) return;
      if (Scrollable.recommendDeferredLoadingForContext(context)) {
        _recheck();
      } else {
        setState(() => _ready = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      _ready! ? widget.child : widget.placeholder;
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
///
/// The image runs under its own [TickerMode]: off by default (static
/// cells, battery), or following [animate] (the sticker grid turns it on
/// while it rests, so visible animated stickers play and nothing decodes
/// frames during a scroll). Only the image: a [TickerMode] around the grid
/// would also stop the grid's fling and the press motion. [sent] carries
/// the id of the last sent cell ([sentId]): that cell dips once.
class StickerTile extends StatelessWidget {
  const StickerTile({
    super.key,
    required this.item,
    required this.client,
    required this.size,
    required this.onTap,
    this.onLongPress,
    this.fit = BoxFit.contain,
    this.animate,
    this.sent,
    this.sentId,
  });

  final StickerItem item;
  final Client client;
  final double size;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final BoxFit fit;
  final ValueListenable<bool>? animate;
  final ValueListenable<StickerSentPulse?>? sent;
  final String? sentId;

  @override
  Widget build(BuildContext context) {
    final inset = fit == BoxFit.cover ? NotionSpace.xxs / 2 : NotionSpace.xxs;
    final label = item.kind == StickerKind.gif
        ? 'GIF'
        : item.emoji == null
        ? 'Sticker'
        : 'Sticker ${item.emoji}';
    final image = StickerImage(
      item: item,
      client: client,
      size: size - 2 * inset,
      fit: fit,
      borderRadius: fit == BoxFit.cover
          ? NotionRadius.smAll
          : NotionRadius.xsAll,
    );
    final animate = this.animate;
    Widget child = Padding(
      padding: EdgeInsets.all(inset),
      child: animate == null
          ? TickerMode(enabled: false, child: image)
          : ValueListenableBuilder<bool>(
              valueListenable: animate,
              builder: (context, on, image) =>
                  TickerMode(enabled: on, child: image!),
              child: image,
            ),
    );
    final sent = this.sent;
    if (sent != null && sentId != null) {
      child = _SentPulse(pulse: sent, id: sentId!, child: child);
    }
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressIcon,
        onTap: onTap,
        // NotionPressable plays the long-press haptic itself.
        onLongPress: onLongPress,
        child: child,
      ),
    );
  }
}

/// The last sticker sent from a grid: [id] of its cell and a counter, so
/// sending the same sticker twice pulses twice.
typedef StickerSentPulse = (String id, int count);

/// A sent sticker's cell dips and springs back once (critically damped,
/// no bounce: grid cells are not reward elements). The controller is
/// created on the first pulse only, so cells built by scrolling cost
/// nothing; reduced motion shows no pulse.
class _SentPulse extends StatefulWidget {
  const _SentPulse({
    required this.pulse,
    required this.id,
    required this.child,
  });

  final ValueListenable<StickerSentPulse?> pulse;
  final String id;
  final Widget child;

  @override
  State<_SentPulse> createState() => _SentPulseState();
}

class _SentPulseState extends State<_SentPulse>
    with SingleTickerProviderStateMixin {
  AnimationController? _scale;
  StickerSentPulse? _seen;

  @override
  void initState() {
    super.initState();
    _seen = widget.pulse.value;
    widget.pulse.addListener(_pulsed);
  }

  @override
  void didUpdateWidget(_SentPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pulse, widget.pulse)) {
      oldWidget.pulse.removeListener(_pulsed);
      widget.pulse.addListener(_pulsed);
    }
  }

  void _pulsed() {
    final value = widget.pulse.value;
    if (value == _seen) return;
    _seen = value;
    if (value?.$1 != widget.id || !mounted || NotionMotion.reduced(context)) {
      return;
    }
    final created = _scale == null;
    final scale = _scale ??= AnimationController.unbounded(
      vsync: this,
      value: 1,
    );
    // Kick the spring inwards: a dip to about 90 % and back to 1.
    scale.animateWith(
      NotionMotion.springTo(NotionMotion.snappy, scale.value, 1, velocity: -6),
    );
    if (created) setState(() {});
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_pulsed);
    _scale?.dispose();
    super.dispose();
  }

  static const _rest = AlwaysStoppedAnimation<double>(1);

  // One shape before and after the first pulse: the image never remounts.
  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale ?? _rest, child: widget.child);
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
/// page (it pops out of the grid), its emoji and [packTitle] under it and
/// its actions in a glass card below. [note] explains why sending is not
/// possible here. A tap on the sticker closes it.
Future<void> showStickerPreview(
  BuildContext context, {
  required StickerItem item,
  required Client client,
  required List<StickerPreviewAction> actions,
  String? note,
  String? packTitle,
}) => showNotionCustomDialog<void>(
  context: context,
  builder: (context) => _StickerPreview(
    item: item,
    client: client,
    actions: actions,
    note: note,
    packTitle: packTitle,
  ),
);

class _StickerPreview extends StatelessWidget {
  const _StickerPreview({
    required this.item,
    required this.client,
    required this.actions,
    this.note,
    this.packTitle,
  });

  final StickerItem item;
  final Client client;
  final List<StickerPreviewAction> actions;
  final String? note;
  final String? packTitle;

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
            Semantics(
              image: true,
              label: item.kind == StickerKind.gif
                  ? 'GIF preview'
                  : 'Sticker preview',
              child: NotionTapTarget(
                onTap: () => Navigator.of(context).pop(),
                child: NotionPop(
                  bounce: false,
                  child: RepaintBoundary(
                    child: TickerMode(
                      enabled: !NotionMotion.reduced(context),
                      child: StickerImage(
                        key: const ValueKey('sticker-preview-image'),
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
              ),
            ),
            if ((item.emoji != null && item.kind == StickerKind.sticker) ||
                packTitle != null) ...[
              const SizedBox(height: NotionSpace.xs),
              Text.rich(
                TextSpan(
                  children: [
                    if (item.emoji != null && item.kind == StickerKind.sticker)
                      TextSpan(text: item.emoji, style: NotionType.heading),
                    if (item.emoji != null &&
                        item.kind == StickerKind.sticker &&
                        packTitle != null)
                      const TextSpan(text: '  '),
                    if (packTitle != null)
                      TextSpan(
                        text: packTitle,
                        style: notion.typography.footnoteMuted,
                      ),
                  ],
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
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
