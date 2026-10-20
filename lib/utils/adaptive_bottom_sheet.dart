// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

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
            elevation: Theme.of(context).dialogTheme.elevation ?? 4,
            shadowColor: Theme.of(context).dialogTheme.shadowColor,
            // Rounded like every dialog; the body is a full page, so the
            // fill stays opaque (no blur behind an opaque scaffold).
            shape: RoundedRectangleBorder(
              borderRadius: NotionGlass.dialogRadius,
              side: BorderSide(color: context.notion.glass.border),
            ),
            color: Theme.of(context).scaffoldBackgroundColor,
            clipBehavior: Clip.hardEdge,
            child: builder(context),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<T>(
    context: context,
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
    clipBehavior: Clip.hardEdge,
  );
}
