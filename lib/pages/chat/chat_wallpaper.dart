// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';

/// The account wallpaper behind a conversation (single and merged chats).
///
/// It sits under the scrolling timeline and both glass bars, so it is kept
/// cheap per frame: its own [RepaintBoundary] (timeline scrolls never
/// re-record it), decoded only as large as the screen it covers instead of
/// at the original photo resolution, and its opacity painted by the image
/// itself rather than through an `Opacity` compositing layer.
class ChatWallpaper extends StatelessWidget {
  final Uri uri;
  final double opacity;

  /// Static blur sigma chosen in the style settings; 0 adds no filter.
  final double blur;

  const ChatWallpaper({
    super.key,
    required this.uri,
    required this.opacity,
    this.blur = 0,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final image = MxcImage(
      cacheKey: uri.toString(),
      uri: uri,
      fit: BoxFit.cover,
      height: size.height,
      width: size.width,
      isThumbnail: false,
      decodeToCover: true,
      opacity: opacity.clamp(0.0, 1.0),
      placeholder: (_) => const SizedBox.shrink(),
    );
    if (blur <= 0) return RepaintBoundary(child: image);
    // Static blur from the style settings (design lint: allowed, never
    // animated, outside scrolling content).
    final f = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
    return RepaintBoundary(
      child: ImageFiltered(imageFilter: f, child: image), // design-lint: allow
    );
  }
}
