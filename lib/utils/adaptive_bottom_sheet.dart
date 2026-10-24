// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// A full-page body ([Scaffold] with its own header) as a sheet on phones and
/// a centred panel in column mode. Only for bodies that are whole pages (QR
/// scanner, message info); a picker or form uses `showNotionSheet` instead.
///
/// Both forms stay opaque in the page colour (an opaque scaffold would hide
/// any blur behind it), with the Notion radius, the glass hairline and no
/// elevation (DESIGN.md "Don't: shadows"). The phone sheet carries the
/// NotionSheet drag handle above the page.
Future<T?> showAdaptiveBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  bool isDismissible = true,
  bool isScrollControlled = true,
  bool useRootNavigator = true,
}) {
  if (ChatLoomThemes.isColumnMode(context)) {
    return showNotionCustomDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: isDismissible,
      useSafeArea: true,
      builder: (context) => Center(
        child: Container(
          margin: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: Material(
            elevation: 0,
            // Rounded like every dialog; the body is a full page, so the
            // fill stays opaque (no blur behind an opaque scaffold).
            shape: RoundedRectangleBorder(
              borderRadius: NotionGlass.dialogRadius,
              side: BorderSide(color: context.notion.glass.border),
            ),
            color: Theme.of(context).scaffoldBackgroundColor,
            clipBehavior: Clip.antiAlias,
            child: builder(context),
          ),
        ),
      ),
    );
  }

  final page = Theme.of(context).scaffoldBackgroundColor;
  return showModalBottomSheet<T>(
    context: context,
    // The handle strip takes the page colour, so it reads as the top of the
    // page below it rather than a second surface.
    backgroundColor: page,
    showDragHandle: true,
    shape: NotionShapes.sheet.copyWith(
      side: BorderSide(color: context.notion.glass.border),
    ),
    elevation: 0,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.viewInsetsOf(context).bottom +
            min(MediaQuery.sizeOf(context).height - 32, 600),
      ),
      child: builder(context),
    ),
    sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
    useSafeArea: true,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    isScrollControlled: isScrollControlled,
    clipBehavior: Clip.antiAlias,
  );
}
