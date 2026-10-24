// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion_appearance.dart';
import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:material_ui/material_ui.dart';

abstract class ChatLoomThemes {
  static const double columnWidth = 380.0;

  static const double maxTimelineWidth = columnWidth * 2;

  static bool isColumnModeByWidth(double width) => width > columnWidth * 2;

  static bool isColumnMode(BuildContext context) =>
      isColumnModeByWidth(MediaQuery.sizeOf(context).width);

  static bool isThreeColumnMode(BuildContext context) =>
      MediaQuery.sizeOf(context).width > ChatLoomThemes.columnWidth * 3.5;


  /// Legacy timing used by FluffyChat widgets; now the Notion motion tokens
  /// (`NotionMotion.short`, `NotionMotion.standard`). New code uses
  /// `NotionMotion` directly.
  static const Duration animationDuration = NotionMotion.short;
  static const Curve animationCurve = NotionMotion.standard;

  /// The app theme for [appearance] (accent preset and colour intensity,
  /// chosen in Settings → Appearance).
  static ThemeData buildTheme(
    BuildContext context,
    Brightness brightness, [
    NotionAppearance appearance = NotionAppearance.standard,
  ]) {
    return NotionTheme.build(brightness, appearance);
  }
}
