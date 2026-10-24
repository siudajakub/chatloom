// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_glass.dart';
import 'notion_tokens.dart';

/// The glass page header of a list page (DESIGN.md "Glass": fixed chrome),
/// the same as Settings root and [NotionScaffold]. Use it with
/// `Scaffold(extendBodyBehindAppBar: true)`; the page's scroll view adds
/// `MediaQuery.paddingOf(context).top` (header + status bar) to its top
/// padding so the rows scroll under the glass, or a page with a fixed top
/// block wraps its body in [NotionBelowGlassHeader].
AppBar notionGlassAppBar({
  Widget? leading,
  Widget? title,
  List<Widget>? actions,
  bool automaticallyImplyLeading = true,
  double? titleSpacing,
}) => AppBar(
  toolbarHeight: NotionSize.headerHeight,
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  centerTitle: false,
  flexibleSpace: const NotionGlassBar(),
  automaticallyImplyLeading: automaticallyImplyLeading,
  leading: leading,
  titleSpacing: titleSpacing,
  title: title,
  actions: actions == null || actions.isEmpty
      ? null
      : [...actions, const SizedBox(width: NotionSpace.xxs)],
);

/// Lays out a page body whose top part does not scroll (a search field or
/// filters above the results) below a glass header: pads it by the header
/// and status bar, and removes that inset from the descendants so a list
/// inside does not add it a second time.
class NotionBelowGlassHeader extends StatelessWidget {
  final Widget child;
  const NotionBelowGlassHeader({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: child,
    ),
  );
}
