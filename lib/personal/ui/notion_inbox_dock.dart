// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// The centre label can grow with the device text size.
double notionInboxDockHeight(TextScaler scaler) =>
    62 + (scaler.scale(16) - 20).clamp(0, double.infinity);

/// Settings and network controls: half again a touch target (J, 2026-11-24).
const double _sideWidth = NotionSize.touchTarget * 1.5;

class NotionInboxDock extends StatefulWidget {
  final VoidCallback onSettings;
  final VoidCallback? onSearch;
  final ValueChanged<String?> onNetworkSelected;
  final List<String> networks;
  final String? selectedNetwork;
  final InboxFilter selectedView;
  const NotionInboxDock({
    super.key,
    required this.onSettings,
    required this.onSearch,
    required this.onNetworkSelected,
    required this.networks,
    this.selectedNetwork,
    this.selectedView = InboxFilter.inbox,
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
      // Network switching only (J, 2026-11-24): views live in the chips
      // above the list.
    );
    if (!mounted) return;
    setState(() => _expanded = false);
    _networkFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final glass = context.notion.glass;
    final networkLabel = widget.selectedNetwork == null
        ? 'All networks'
        : notionNetworkLabel(widget.selectedNetwork!);
    final label = widget.selectedView == InboxFilter.inbox
        ? networkLabel
        : '${inboxViewLabel(widget.selectedView)} · $networkLabel';
    // Floating glass pill over the inbox list (DESIGN.md "Glass").
    return NotionGlassSurface(
      dock: true,
      tint: notionGlassOpaque(context, glass.dockTint),
      borderRadius: NotionGlass.dockRadius,
      border: Border.all(color: glass.border),
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          height: notionInboxDockHeight(MediaQuery.textScalerOf(context)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _sideWidth,
                child: IconButton(
                  key: const ValueKey('notion_dock_settings'),
                  onPressed: widget.onSettings,
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
              const NotionGlassDivider(),
              Expanded(
                child: Semantics(
                  key: const ValueKey('notion_dock_search'),
                  button: true,
                  enabled: widget.onSearch != null,
                  child: Opacity(
                    opacity: widget.onSearch == null ? .45 : 1,
                    child: InkWell(
                      onTap: widget.onSearch,
                      customBorder: NotionShapes.pill,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.search),
                          const SizedBox(width: NotionSpace.xs),
                          Flexible(
                            child: Text(
                              'Search',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: context.notion.typography.callout,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const NotionGlassDivider(),
              SizedBox(
                width: _sideWidth,
                child: Semantics(
                  key: const ValueKey('notion_dock_network'),
                  expanded: _expanded,
                  child: IconButton(
                    key: _networkAnchor,
                    focusNode: _networkFocus,
                    tooltip: 'Show chats, $label',
                    onPressed: _showNetworks,
                    icon: NotionFadeThrough(
                      alignment: Alignment.center,
                      child: NotionNetworkGlyph(
                        key: ValueKey(widget.selectedNetwork),
                        network: widget.selectedNetwork,
                        size: NotionSize.iconLg,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
