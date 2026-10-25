// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_tokens.dart';

/// Built-in chat backgrounds, chosen in Settings → Appearance and kept on
/// this device. A picture from the account wallpaper replaces them.
///
/// Each is a static diagonal gradient painted at the chosen strength over
/// the page colour, so bubbles, captions and metadata chips keep their
/// contrast in both themes. [accent] follows the user's accent colour.
enum NotionWallpaperPreset {
  none('None', []),
  accent('Accent', []),
  aurora('Aurora', [Color(0xFF0FB5A6), Color(0xFF6366F1), Color(0xFFA033FF)]),
  ocean('Ocean', [Color(0xFF0A7CFF), Color(0xFF06B6D4)]),
  forest('Forest', [Color(0xFF22C55E), Color(0xFF0F766E)]),
  sunset('Sunset', [Color(0xFFF97316), Color(0xFFEC4899), Color(0xFF8B5CF6)]),
  plum('Plum', [Color(0xFF8B5CF6), Color(0xFFE0409F)]),
  sand('Sand', [Color(0xFFD9A400), Color(0xFFF76B15)]),
  slate('Slate', [Color(0xFF64748B), Color(0xFF1E293B)]);

  final String label;
  final List<Color> _colors;
  const NotionWallpaperPreset(this.label, this._colors);

  /// The gradient stops in [context]'s theme; empty for [none].
  List<Color> colorsOf(BuildContext context) {
    if (this != accent) return _colors;
    final palette = context.notion.palette;
    return palette.bubbleGradient ?? [palette.accentFill, palette.accent];
  }
}

/// Paints [preset] behind a conversation (and in the Appearance preview).
/// Static and isolated in its own [RepaintBoundary]: timeline scrolling
/// never repaints it.
class NotionPresetWallpaper extends StatelessWidget {
  const NotionPresetWallpaper({
    super.key,
    required this.preset,
    required this.strength,
  });

  final NotionWallpaperPreset preset;

  /// Opacity of the gradient over the page, 0–1.
  final double strength;

  @override
  Widget build(BuildContext context) {
    final colors = preset.colorsOf(context);
    if (colors.isEmpty) return const SizedBox.shrink();
    final alpha = strength.clamp(0.0, 1.0);
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  for (final color in colors) color.withValues(alpha: alpha),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
