// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A photo in the full-screen viewer that never opens on an empty frame
/// (Telegram, Messenger): the thumbnail the user just tapped is drawn at
/// once at the photo's final [size], the full image loads behind it and
/// fades in over it. Both layers share one box, so zoom and pan already
/// work on the thumbnail and nothing moves on the swap.
///
/// A small loader sits at the bottom while the download takes longer than
/// [NotionMotion.loaderGrace]; a failed download keeps the thumbnail and
/// offers a retry there.
///
/// Memory: the original is decoded at twice its on-screen size (sharp at a
/// double-tap zoom), at most [maxDecodeSide] px; zooming past
/// [sharpenScale] swaps in the [maxDecodeSide] decode without a flash, and
/// back at fit the small one returns. Neither decode stays in the shared
/// image cache once replaced or the page is gone (BP-11).
class ProgressivePhoto extends StatefulWidget {
  const ProgressivePhoto({
    super.key,
    required this.event,
    required this.size,
    required this.frame,
    this.zoom,
  });

  /// Long-side cap of any decode in the viewer: 4096 px keeps a 50 MP photo
  /// at about 50 MB instead of 200 MB and is still sharp at 2–3× on a phone.
  static const int maxDecodeSide = 4096;

  /// Zoom factor from which the photo is decoded at [maxDecodeSide].
  static const double sharpenScale = 1.8;

  /// The decode side for a photo shown at [size] logical px.
  static int decodeSideFor(
    Size size,
    double devicePixelRatio, {
    bool sharp = false,
  }) {
    if (sharp) return maxDecodeSide;
    final longest = max(size.width, size.height) * devicePixelRatio * 2;
    if (!longest.isFinite || longest <= 0) return maxDecodeSide;
    return min(maxDecodeSide, max(1, longest.ceil()));
  }

  /// Zoom of the page ([InteractiveViewer] transformation).
  final ValueListenable<Matrix4>? zoom;

  final Event event;

  /// The photo fitted into the viewport (see `notionFitMedia`).
  final Size size;

  /// Wraps the photo (zoom, gestures, hero); the status sits above it,
  /// outside the zoom.
  final Widget Function(BuildContext context, Widget photo) frame;

  @override
  State<ProgressivePhoto> createState() => _ProgressivePhotoState();
}

class _ProgressivePhotoState extends State<ProgressivePhoto> {
  MxcImageLoad _load = MxcImageLoad.loading;

  /// Bumped by the retry button: remounts the full image.
  int _attempt = 0;

  /// Bytes of the bubble or grid tile the viewer was opened from.
  Uint8List? _preview;

  /// Zoomed past [ProgressivePhoto.sharpenScale]: decode at the cap.
  bool _sharp = false;

  @override
  void initState() {
    super.initState();
    _preview = MxcImage.cachedPreviewOf(widget.event);
    widget.zoom?.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(ProgressivePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId) {
      _load = MxcImageLoad.loading;
      _preview = MxcImage.cachedPreviewOf(widget.event);
    }
    if (oldWidget.zoom != widget.zoom) {
      oldWidget.zoom?.removeListener(_onZoom);
      widget.zoom?.addListener(_onZoom);
    }
  }

  @override
  void dispose() {
    widget.zoom?.removeListener(_onZoom);
    super.dispose();
  }

  /// Sharpens past [ProgressivePhoto.sharpenScale]; drops the big decode only
  /// back at fit, so a pinch around the threshold never decodes twice.
  void _onZoom() {
    final scale = widget.zoom?.value.getMaxScaleOnAxis() ?? 1;
    final sharp = _sharp ? scale > 1.01 : scale > ProgressivePhoto.sharpenScale;
    if (sharp != _sharp && mounted) setState(() => _sharp = sharp);
  }

  void _onLoad(MxcImageLoad load) {
    if (mounted) setState(() => _load = load);
  }

  void _retry() => setState(() {
    _attempt++;
    _load = MxcImageLoad.loading;
  });

  Widget? _thumbnail(BuildContext context) {
    final event = widget.event;
    final size = widget.size;
    final preview = _preview;
    if (preview != null) {
      // Decoded at most at screen resolution; a small thumbnail is not
      // upscaled in memory, only drawn larger.
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return Image(
        image: ResizeImage(
          MemoryImage(preview),
          width: max(1, (size.width * dpr).ceil()),
          height: max(1, (size.height * dpr).ceil()),
          policy: ResizeImagePolicy.fit,
        ),
        width: size.width,
        height: size.height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    final blurHash = event.infoMap.tryGet<String>('xyz.amorgan.blurhash');
    final hash = blurHash == null
        ? null
        : BlurHash(blurhash: blurHash, width: size.width, height: size.height);
    // Not in memory (evicted, opened from elsewhere): the small thumbnail
    // still beats the original by far. Without one the original is the only
    // download, so it is not fetched twice.
    if (!event.hasThumbnail) return hash;
    return MxcImage(
      event: event,
      fit: BoxFit.contain,
      isThumbnail: true,
      width: size.width,
      height: size.height,
      placeholder: (_) => hash ?? const SizedBox.shrink(),
      usePlaceholderOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final size = widget.size;
    final thumbnail = _thumbnail(context);
    final photo = SizedBox.fromSize(
      size: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumbnail != null)
            // Stays fully opaque under the full image while that fades in,
            // then drops out (transparent photos must not show it).
            AnimatedOpacity(
              opacity: _load == MxcImageLoad.ready ? 0 : 1,
              duration: NotionMotion.of(context, NotionMotion.short),
              curve: const Threshold(1),
              child: thumbnail,
            ),
          MxcImage(
            key: ValueKey((event.eventId, _attempt)),
            event: event,
            fit: BoxFit.contain,
            isThumbnail: false,
            animated: true,
            width: size.width,
            height: size.height,
            maxDecodeSide: ProgressivePhoto.decodeSideFor(
              size,
              MediaQuery.devicePixelRatioOf(context),
              sharp: _sharp,
            ),
            // The thumbnail below is the placeholder; no spinner, no broken
            // image icon over it.
            placeholder: (_) => const SizedBox.shrink(),
            usePlaceholderOnError: true,
            onLoadStateChanged: _onLoad,
          ),
        ],
      ),
    );
    final bottom = MediaQuery.paddingOf(context).bottom + NotionSpace.xl;
    return Stack(
      children: [
        Positioned.fill(child: widget.frame(context, photo)),
        Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: Center(
            child: NotionFadeThrough(
              alignment: Alignment.center,
              duration: NotionMotion.short,
              child: switch (_load) {
                MxcImageLoad.ready => const SizedBox.shrink(
                  key: ValueKey('ready'),
                ),
                MxcImageLoad.loading => const _PhotoLoader(
                  key: ValueKey('loading'),
                ),
                MxcImageLoad.failed => NotionGlassPill(
                  key: const ValueKey('failed'),
                  icon: Icons.refresh,
                  label: L10n.of(context).tryAgain,
                  onPressed: _retry,
                ),
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// A small spinner on a scrim disc: visible over any photo, appears only
/// after the loader grace so a fast load shows nothing.
class _PhotoLoader extends StatelessWidget {
  const _PhotoLoader({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: NotionDelayedReveal(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: NotionMediaColors.stageScrim,
          borderRadius: NotionRadius.pillAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(NotionSpace.xs),
          // The disc already waited for the grace: the ring shows with it
          // and rests after the loop cap (a stalled download stops drawing).
          child: NotionDelayedSpinner(
            size: NotionSize.iconSm,
            delay: Duration.zero,
            color: NotionMediaColors.onScrim,
            semanticsLabel: L10n.of(context).loadingPleaseWait,
          ),
        ),
      ),
    ),
  );
}
