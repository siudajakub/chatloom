// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Legacy name for [NotionPulse]: an expanding, fading ring behind [child]
/// (transform and opacity only, stopped under reduced motion and
/// `TickerMode` off). New code uses [NotionPulse] directly.
class PulsatingWidget extends StatelessWidget {
  final Color? color;
  final Widget child;

  /// Extra ring reach in logical pixels, mapped to a ring scale.
  final double spreadRadius;

  const PulsatingWidget({
    required this.child,
    this.color,
    this.spreadRadius = 1.0,
    super.key,
  });

  @override
  Widget build(BuildContext context) => NotionPulse(
    color: color,
    spread: 1.15 + (spreadRadius / 40).clamp(0.0, 0.35),
    child: child,
  );
}
