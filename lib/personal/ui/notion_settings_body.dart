// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

/// Flat secondary settings surface. It retains each inherited controller and
/// route while avoiding the older desktop card wrapper.
class NotionSettingsBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final bool withScrolling;
  final EdgeInsets? innerPadding;
  const NotionSettingsBody({
    super.key,
    required this.child,
    this.maxWidth = 640,
    this.withScrolling = true,
    this.innerPadding,
  });
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: withScrolling
            ? SingleChildScrollView(
                padding:
                    innerPadding ??
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: child,
              )
            : Padding(
                padding:
                    innerPadding ??
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: child,
              ),
      ),
    ),
  );
}
