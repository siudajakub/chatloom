// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_wallpapers.dart';

/// Opaque fills used in private chats. The timeline computes the text colour
/// from the fill. Names keep existing soft colours recognizable.
enum NotionMessageColor {
  cobalt('Cobalt', Color(0xFF2455A6)),
  pine('Pine', Color(0xFF20594D)),
  mulberry('Mulberry', Color(0xFF703A73)),
  copper('Copper', Color(0xFF8A492E)),
  mist('Mist', Color(0xFFDBE6F5)),
  sage('Sage', Color(0xFFDFEBDB)),
  blush('Blush', Color(0xFFF0DFE9)),
  oat('Oat', Color(0xFFF1E6D2)),
  seafoam('Seafoam', Color(0xFFD8EEEC)),
  lilac('Lilac', Color(0xFFE5DEF2)),
  rose('Rose', Color(0xFFF2DDDD)),
  fog('Fog', Color(0xFFE5E7EB));

  final String label;
  final Color fill;
  const NotionMessageColor(this.label, this.fill);

  int get argb => fill.toARGB32();

  static NotionMessageColor? fromArgb(int? argb) =>
      values.where((value) => value.argb == argb).firstOrNull;
}

/// A background and a sent-message colour picked together. Incoming
/// messages keep the neutral app style.
enum NotionChatPalette {
  blueHour('Blue hour', NotionWallpaperPreset.ocean, NotionMessageColor.cobalt),
  evergreen('Evergreen', NotionWallpaperPreset.forest, NotionMessageColor.pine),
  afterDusk(
    'After dusk',
    NotionWallpaperPreset.plum,
    NotionMessageColor.mulberry,
  ),
  sandstone('Sandstone', NotionWallpaperPreset.sand, NotionMessageColor.copper);

  final String label;
  final NotionWallpaperPreset background;
  final NotionMessageColor outgoing;
  const NotionChatPalette(this.label, this.background, this.outgoing);
}
