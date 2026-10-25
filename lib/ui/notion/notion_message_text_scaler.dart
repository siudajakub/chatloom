// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

/// Adds the conversation preference to the platform's accessibility scaler,
/// retaining Android's nonlinear scaling for each individual text size.
@immutable
class NotionMessageTextScaler extends TextScaler {
  const NotionMessageTextScaler(this.platform, this.factor);

  final TextScaler platform;
  final double factor;

  @override
  double scale(double fontSize) => platform.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is NotionMessageTextScaler &&
      other.platform == platform &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(platform, factor);
}
