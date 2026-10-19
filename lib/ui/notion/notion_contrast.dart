// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

/// WCAG contrast helpers for colours the user (or a chat palette) picks, so
/// text on custom fills stays readable without hard-coding black or white.
abstract final class NotionContrast {
  /// WCAG AA for normal text.
  static const double minimum = 4.5;

  static const Color _dark = Color(0xFF1F1F1F);
  static const Color _light = Color(0xFFFFFFFF);

  /// WCAG 2 contrast ratio of two opaque colours (1 to 21).
  static double ratio(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    final hi = x > y ? x : y;
    final lo = x > y ? y : x;
    return (hi + .05) / (lo + .05);
  }

  /// Near-black or white, whichever reads better on [background].
  static Color on(Color background) =>
      ratio(_dark, background) >= ratio(_light, background) ? _dark : _light;

  /// [preferred] when it reaches [minimum] on [background]; otherwise the
  /// closest blend from [preferred] towards [on] that does, so muted text
  /// stays as muted as the background allows.
  static Color readable(
    Color background,
    Color preferred, {
    double minimum = minimum,
  }) {
    final opaque = preferred.withValues(alpha: 1);
    if (ratio(opaque, background) >= minimum) return opaque;
    final strong = on(background);
    for (var t = .2; t < 1; t += .2) {
      final candidate = Color.lerp(opaque, strong, t)!;
      if (ratio(candidate, background) >= minimum) return candidate;
    }
    return strong;
  }
}
