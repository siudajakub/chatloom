// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Reserve enough room for two scaled network-label lines as well as its icon.
double notionInboxDockHeight(TextScaler scaler) =>
    scaler.scale(16) > 22 ? 47 + 2 * scaler.scale(13) * 1.2 : 62;

/// At large text scale the network label gets at most two lines, split
/// between words ("Unread" / "Telegram", "All" / "networks") so a word is
/// never broken in the middle; each line ellipsizes on its own.
List<String> notionInboxDockLabelLines(String label) {
  final parts = label.split(' · ');
  if (parts.length > 1) return [parts.first, parts.skip(1).join(' · ')];
  final space = label.indexOf(' ');
  if (space <= 0) return [label];
  return [label.substring(0, space), label.substring(space + 1)];
}

class NotionInboxDock extends StatefulWidget {
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final ValueChanged<String?> onNetworkSelected;
  final List<String> networks;
  final String? selectedNetwork;
  final InboxFilter selectedView;
  final ValueChanged<InboxFilter>? onViewSelected;
  final VoidCallback? onManageNetworks;
  final VoidCallback? onMarkAllRead;
  const NotionInboxDock({
    super.key,
    required this.onSettings,
    required this.onSearch,
    required this.onNetworkSelected,
    required this.networks,
    this.selectedNetwork,
    this.selectedView = InboxFilter.inbox,
    this.onViewSelected,
    this.onManageNetworks,
    this.onMarkAllRead,
  });
  @override
  State<NotionInboxDock> createState() => _NotionInboxDockState();
}

class _NotionInboxDockState extends State<NotionInboxDock> {
  final _networkAnchor = GlobalKey();
  final _networkFocus = FocusNode(debugLabel: 'Inbox network filter');
  bool _expanded = false;
  @override
  void dispose() {
    _networkFocus.dispose();
    super.dispose();
  }

  Future<void> _showNetworks() async {
    final box = _networkAnchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    setState(() => _expanded = true);
    await showNotionNetworkSelector(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      networks: widget.networks,
      selected: widget.selectedNetwork,
      onSelected: widget.onNetworkSelected,
      selectedView: widget.selectedView,
      onViewSelected: widget.onViewSelected,
      onManageNetworks: widget.onManageNetworks,
      onMarkAllRead: widget.onMarkAllRead,
    );
    if (!mounted) return;
    setState(() => _expanded = false);
    _networkFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final networkLabel = widget.selectedNetwork == null
        ? 'All networks'
        : notionNetworkLabel(widget.selectedNetwork!);
    final label = widget.selectedView == InboxFilter.inbox
        ? networkLabel
        : '${inboxViewLabel(widget.selectedView)} · $networkLabel';
    // Floating glass pill over the inbox list (DESIGN.md "Glass").
    return NotionGlassSurface(
      dock: true,
      borderRadius: NotionGlass.dockRadius,
      border: Border.all(color: context.notion.glass.border),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: notionInboxDockHeight(MediaQuery.textScalerOf(context)),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                if (large)
                  Expanded(child: _settings(context, large: true))
                else
                  _settings(context, large: false),
                const NotionGlassDivider(),
                Expanded(
                  flex: large ? 1 : 4,
                  child: _action(
                    context,
                    icon: Icons.search,
                    label: 'Search',
                    onTap: widget.onSearch,
                    large: large,
                  ),
                ),
                const NotionGlassDivider(),
                Expanded(
                  flex: large ? 1 : 5,
                  child: Semantics(
                    key: const ValueKey('notion_dock_network'),
                    button: true,
                    label: 'Show chats, $label',
                    expanded: _expanded,
                    child: InkWell(
                      key: _networkAnchor,
                      focusNode: _networkFocus,
                      onTap: _showNetworks,
                      customBorder: NotionShapes.pill,
                      // The content presses inside the ink, so the anchor
                      // rect of the popover never reads a scaled box.
                      child: NotionPressable(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: large ? 4 : 12,
                            vertical: 10,
                          ),
                          child: large
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    NotionFadeThrough(
                                      alignment: Alignment.center,
                                      child: NotionNetworkGlyph(
                                        key: ValueKey(widget.selectedNetwork),
                                        network: widget.selectedNetwork,
                                        size: 23,
                                      ),
                                    ),
                                    const SizedBox(height: NotionSpace.xxs),
                                    // Break only between words: each line is
                                    // a single unwrapped line, never "net/works".
                                    NotionFadeThrough(
                                      alignment: Alignment.topCenter,
                                      child: Column(
                                        key: ValueKey(label),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final line
                                              in notionInboxDockLabelLines(
                                                label,
                                              ))
                                            Text(
                                              line,
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              softWrap: false,
                                              overflow: TextOverflow.ellipsis,
                                              style: NotionType.footnote
                                                  .copyWith(height: 1.2),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    NotionFadeThrough(
                                      alignment: Alignment.center,
                                      child: NotionNetworkGlyph(
                                        key: ValueKey(widget.selectedNetwork),
                                        network: widget.selectedNetwork,
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: NotionFadeThrough(
                                        alignment:
                                            AlignmentDirectional.centerStart,
                                        child: Text(
                                          label,
                                          key: ValueKey(label),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 15),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    NotionMorphSwitcher(
                                      child: Icon(
                                        _expanded
                                            ? Icons.keyboard_arrow_up
                                            : Icons.keyboard_arrow_down,
                                        key: ValueKey(_expanded),
                                        size: 21,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settings(BuildContext context, {required bool large}) => Semantics(
    key: const ValueKey('notion_dock_settings'),
    button: true,
    label: 'Settings',
    child: Tooltip(
      message: 'Settings',
      child: InkWell(
        onTap: widget.onSettings,
        customBorder: NotionShapes.pill,
        child: SizedBox(
          width: large ? double.infinity : 64,
          child: const NotionPressable(
            scale: NotionMotion.pressIcon,
            child: Center(child: Icon(Icons.settings_outlined, size: 27)),
          ),
        ),
      ),
    ),
  );

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool large,
  }) => Semantics(
    key: ValueKey('notion_dock_${label.toLowerCase()}'),
    button: true,
    label: label,
    child: InkWell(
      onTap: onTap,
      customBorder: NotionShapes.pill,
      child: NotionPressable(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: large ? 4 : 6,
            vertical: 10,
          ),
          child: large
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 25),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.2),
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 26),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );
}
