// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Legacy name for [NotionTypingDots] (one painter, no timers, no layout per
/// tick, static under reduced motion). Keeps the old 36 × 24 footprint at
/// the default [size]. New code uses [NotionTypingDots] directly.
class TypingAnimation extends StatelessWidget {
  final double size;
  const TypingAnimation({this.size = 8.0, super.key});

  @override
  Widget build(BuildContext context) => NotionTypingDots(size: size);
}
