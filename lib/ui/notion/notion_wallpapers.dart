// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// Built-in chat backgrounds. Names are stored by the display preferences.
///
/// Separate light and dark stops keep the wallpaper near the page's
/// brightness at any strength. [accent] follows the user's accent colour.
enum NotionWallpaperPreset {
  none('Plain', [], []),
  accent('Accent', [], []),
  slate('Slate', [Color(0xFF292E35)], [Color(0xFFE9EBEE)]),
  ocean(
    'Ocean',
    [Color(0xFF203A52), Color(0xFF182A31)],
    [Color(0xFFE7F1FA), Color(0xFFE6F3F1)],
    begin: Alignment.topCenter,
  ),
  forest(
    'Forest',
    [Color(0xFF203A32), Color(0xFF192C28)],
    [Color(0xFFE2F0E8), Color(0xFFEEF3E6)],
  ),
  sand(
    'Sand',
    [Color(0xFF3B3225), Color(0xFF3E2A28)],
    [Color(0xFFF4ECDD), Color(0xFFF7E9E0)],
    begin: Alignment.topCenter,
  ),
  sunset(
    'Sunset',
    [Color(0xFF493039), Color(0xFF373049), Color(0xFF25273B)],
    [Color(0xFFF8E6DF), Color(0xFFF3E7F2), Color(0xFFEDEAF9)],
  ),
  plum(
    'Plum',
    [Color(0xFF3C2C49), Color(0xFF442B3B)],
    [Color(0xFFEEE6F6), Color(0xFFF6E7EE)],
    begin: Alignment.topRight,
  ),
  aurora(
    'Aurora',
    [Color(0xFF20413E), Color(0xFF303853), Color(0xFF3B3052)],
    [Color(0xFFE3F2EC), Color(0xFFE8EBFA), Color(0xFFF1E8FA)],
  );

  final String label;
  final List<Color> _dark;
  final List<Color> _light;
  final Alignment _begin;
  const NotionWallpaperPreset(
    this.label,
    this._dark,
    this._light, {
    Alignment begin = Alignment.topLeft,
  }) : _begin = begin;

  /// The solid fill or gradient stops in the current theme.
  List<Color> colorsOf(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (this != accent) return dark ? _dark : _light;
    final tokens = context.notion;
    final source = tokens.palette.appearance;
    final tint = (source.seed ?? tokens.palette.accent).withValues(
      alpha: dark ? .14 : .08,
    );
    return [Color.alphaBlend(tint, tokens.colors.background)];
  }

  BoxDecoration _decorationOf(BuildContext context, double strength) {
    final alpha = strength.clamp(0.0, 1.0);
    final colors = [
      for (final color in colorsOf(context)) color.withValues(alpha: alpha),
    ];
    if (colors.length == 1) return BoxDecoration(color: colors.single);
    return BoxDecoration(
      gradient: this == aurora
          ? RadialGradient(
              center: const Alignment(-.65, -.60),
              radius: 1.25,
              stops: const [0, .60, 1],
              colors: colors,
            )
          : LinearGradient(begin: _begin, end: -_begin, colors: colors),
    );
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

  /// Opacity of the wallpaper over the page, 0–1.
  final double strength;

  @override
  Widget build(BuildContext context) {
    if (preset == NotionWallpaperPreset.none) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: preset._decorationOf(context, strength),
          ),
        ),
      ),
    );
  }
}

/// Named wallpaper previews drawn by the same renderer as the chat.
/// A null selection lets a photo or an inherited setting remain active.
class NotionWallpaperGallery extends StatelessWidget {
  const NotionWallpaperGallery({
    super.key,
    required this.selected,
    required this.onSelected,
    this.strength = .5,
  });

  final NotionWallpaperPreset? selected;
  final ValueChanged<NotionWallpaperPreset> onSelected;
  final double strength;

  @override
  Widget build(BuildContext context) {
    final scaledLabel = MediaQuery.textScalerOf(
      context,
    ).scale(NotionType.caption.fontSize!);
    final minimumTileWidth = NotionSize.touchTarget + scaledLabel * 3;
    const gap = NotionSpace.xs;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : NotionSize.dialogMaxWidth;
        final fittingColumns = ((width + gap) / (minimumTileWidth + gap))
            .floor();
        // Four columns would leave a single choice alone on the last row.
        final columns = fittingColumns == 4 ? 3 : fittingColumns.clamp(1, 5);
        final tileWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final preset in NotionWallpaperPreset.values)
              SizedBox(
                width: tileWidth,
                child: _WallpaperTile(
                  preset: preset,
                  selected: preset == selected,
                  strength: strength,
                  onTap: () => onSelected(preset),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _WallpaperTile extends StatelessWidget {
  const _WallpaperTile({
    required this.preset,
    required this.selected,
    required this.strength,
    required this.onTap,
  });

  final NotionWallpaperPreset preset;
  final bool selected;
  final double strength;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final palette = tokens.palette;
    return Semantics(
      button: true,
      selected: selected,
      label: '${preset.label} background',
      onTap: onTap,
      excludeSemantics: true,
      child: NotionPressable(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: NotionRadius.smAll,
                    border: Border.all(
                      color: selected ? palette.accent : tokens.colors.border,
                      width: selected ? 2 : NotionSize.border,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: NotionRadius.smAll,
                    child: ColoredBox(
                      color: tokens.colors.background,
                      child: SizedBox(
                        height: NotionSize.headerHeight,
                        child: Stack(
                          children: [
                            NotionPresetWallpaper(
                              preset: preset,
                              strength: strength,
                            ),
                            if (selected)
                              PositionedDirectional(
                                top: NotionSpace.xxs,
                                end: NotionSpace.xxs,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: palette.accentFill,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      NotionSpace.xxs,
                                    ),
                                    child: Icon(
                                      Icons.check,
                                      color: palette.onAccentFill,
                                      size: NotionSize.iconSm,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: NotionSpace.xxs),
                Text(
                  preset.label,
                  textAlign: TextAlign.center,
                  style: NotionType.caption.copyWith(
                    color: selected
                        ? tokens.colors.text
                        : tokens.colors.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: NotionRadius.smAll,
                  mouseCursor: SystemMouseCursors.click,
                  focusColor: palette.accent.withValues(alpha: .2),
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
