// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/ui/notion/notion_motion.dart';
import 'package:material_ui/material_ui.dart';

/// Inbox (or settings index) beside the selected page. The side pane fades
/// in when the location changes (another chat, another setting) instead of
/// cutting hard. One [FadeTransition] around the single live pane: never a
/// switcher, so the pane's GlobalKeys are never duplicated.
class TwoColumnLayout extends StatefulWidget {
  final Widget mainView;
  final Widget sideView;
  final bool hasNavigationRail;

  const TwoColumnLayout({
    super.key,
    required this.mainView,
    required this.sideView,
    this.hasNavigationRail = true,
  });

  @override
  State<TwoColumnLayout> createState() => _TwoColumnLayoutState();
}

class _TwoColumnLayoutState extends State<TwoColumnLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: NotionMotion.short,
    value: 1,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _fade,
    curve: NotionMotion.standard,
  );
  Object? _location;
  bool _seeded = false;

  /// The router's current configuration (go_router's match list, compared
  /// by value), when there is a router above. Unlike the reported route
  /// information it is already current when a pop rebuilds the shell.
  Object? _currentLocation() =>
      Router.maybeOf(context)?.routerDelegate.currentConfiguration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_seeded) {
      _seeded = true;
      _location = _currentLocation();
    }
  }

  @override
  void didUpdateWidget(TwoColumnLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Navigation rebuilds the shell with the new pane in the same frame, so
    // the pane starts transparent before its first paint (no flash).
    final location = _currentLocation();
    if (location == _location) return;
    _location = location;
    if (NotionMotion.reduced(context)) return;
    _fade.forward(from: 0);
  }

  @override
  void dispose() {
    _opacity.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ScaffoldMessenger(
      child: Scaffold(
        body: Row(
          children: [
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(),
              width:
                  FluffyThemes.columnWidth +
                  (widget.hasNavigationRail ? FluffyThemes.navRailWidth : 0),
              // Each column owns its transient messages. In particular the
              // inbox Scaffold must place them above its floating dock.
              child: ScaffoldMessenger(child: widget.mainView),
            ),
            Container(width: 1.0, color: theme.dividerColor),
            Expanded(
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                child: ClipRRect(
                  child: FadeTransition(
                    opacity: _opacity,
                    // The pane stays reachable while it fades in.
                    alwaysIncludeSemantics: true,
                    child: widget.sideView,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
