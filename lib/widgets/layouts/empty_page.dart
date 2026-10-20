// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

class EmptyPage extends StatelessWidget {
  static const double _width = 400;
  const EmptyPage({super.key});
  @override
  Widget build(BuildContext context) {
    final width = min(MediaQuery.sizeOf(context).width, EmptyPage._width) / 2;
    final theme = Theme.of(context);
    return Scaffold(
      // Add invisible appbar to make status bar on Android tablets bright.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        alignment: Alignment.center,
        // The resting logo settles in softly when the pane opens.
        child: NotionEntrance(
          rise: 0,
          scale: NotionMotion.dialogFrom,
          child: Image.asset(
            'assets/logo/mini/logo_mono_mini.png',
            color: theme.colorScheme.surfaceContainerHigh,
            width: width,
            height: width,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}
