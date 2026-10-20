// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:material_ui/material_ui.dart';

abstract class ChatLoomThemes {
  static const double columnWidth = 380.0;

  static const double maxTimelineWidth = columnWidth * 2;

  static const double navRailWidth = 80.0;

  static bool isColumnModeByWidth(double width) =>
      width > columnWidth * 2 + navRailWidth;

  static bool isColumnMode(BuildContext context) =>
      isColumnModeByWidth(MediaQuery.sizeOf(context).width);

  static bool isThreeColumnMode(BuildContext context) =>
      MediaQuery.sizeOf(context).width > ChatLoomThemes.columnWidth * 3.5;

  static LinearGradient backgroundGradient(BuildContext context, int alpha) {
    final colorScheme = Theme.of(context).colorScheme;
    return LinearGradient(
      begin: Alignment.topCenter,
      colors: [
        colorScheme.surface.withAlpha(alpha),
        colorScheme.surface.withAlpha(alpha),
        colorScheme.surface.withAlpha(alpha),
        colorScheme.surface.withAlpha(alpha),
      ],
    );
  }

  /// Legacy timing used by FluffyChat widgets; now the Notion motion tokens
  /// (`NotionMotion.short`, `NotionMotion.standard`). New code uses
  /// `NotionMotion` directly.
  static const Duration animationDuration = NotionMotion.short;
  static const Curve animationCurve = NotionMotion.standard;

  static ThemeData buildTheme(
    BuildContext context,
    Brightness brightness, [
    Color? seed,
  ]) {
    return NotionTheme.build(brightness, seed);
  }
}

extension BubbleColorTheme on ThemeData {
  Color get bubbleColor => brightness == Brightness.light
      ? colorScheme.primary
      : colorScheme.primaryContainer;

  Color get onBubbleColor => brightness == Brightness.light
      ? colorScheme.onPrimary
      : colorScheme.onPrimaryContainer;

  Color get secondaryBubbleColor => HSLColor.fromColor(
    brightness == Brightness.light
        ? colorScheme.tertiary
        : colorScheme.tertiaryContainer,
  ).withSaturation(0.5).toColor();
}
