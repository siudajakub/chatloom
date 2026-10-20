// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

Future<T?> showScaffoldDialog<T>({
  required BuildContext context,
  Color? barrierColor,
  Color? containerColor,
  double maxWidth = 480,
  double maxHeight = 720,
  required Widget Function(BuildContext context) builder,
}) => showNotionCustomDialog<T>(
  context: context,
  barrierColor: barrierColor,
  useSafeArea: false,
  builder: ChatLoomThemes.isColumnMode(context)
      ? (context) => Center(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: NotionGlass.dialogRadius,
              border: Border.all(color: context.notion.glass.border),
              color:
                  containerColor ?? Theme.of(context).scaffoldBackgroundColor,
            ),
            clipBehavior: Clip.hardEdge,
            margin: const EdgeInsets.all(16),
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: builder(context),
          ),
        )
      : builder,
);
