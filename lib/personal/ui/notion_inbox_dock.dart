// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/personal/ui/notion_network_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Reserve enough room for two scaled network-label lines as well as its icon.
double notionInboxDockHeight(TextScaler scaler) =>
    scaler.scale(16) > 22 ? 47 + 2 * scaler.scale(13) * 1.2 : 62;

class NotionInboxDock extends StatefulWidget {
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final ValueChanged<String?> onNetworkSelected;
  final List<String> networks;
  final String? selectedNetwork;
  final InboxFilter selectedView;
  final ValueChanged<InboxFilter>? onViewSelected;
  final VoidCallback? onManageNetworks;
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
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: .16),
      clipBehavior: Clip.antiAlias,
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
              _divider(context),
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
              _divider(context),
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
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: large ? 4 : 12,
                        vertical: 10,
                      ),
                      child: large
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                NotionNetworkGlyph(
                                  network: widget.selectedNetwork,
                                  size: 23,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.2,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                NotionNetworkGlyph(
                                  network: widget.selectedNetwork,
                                  size: 24,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  _expanded
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                  size: 21,
                                ),
                              ],
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

  Widget _settings(BuildContext context, {required bool large}) => Semantics(
    key: const ValueKey('notion_dock_settings'),
    button: true,
    label: 'Settings',
    child: Tooltip(
      message: 'Settings',
      child: InkWell(
        onTap: widget.onSettings,
        child: SizedBox(
          width: large ? double.infinity : 64,
          child: const Center(child: Icon(Icons.settings_outlined, size: 27)),
        ),
      ),
    ),
  );

  Widget _divider(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: SizedBox(
      width: 1,
      height: 36,
      child: ColoredBox(color: Theme.of(context).dividerColor),
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
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: large ? 4 : 6, vertical: 10),
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
  );
}
