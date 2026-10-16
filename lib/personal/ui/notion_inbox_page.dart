// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_inbox_dock.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/personal/ui/notion_inbox_pins.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Production inbox composition. Account adapters supply rows and real actions.
class NotionInboxPage extends StatelessWidget {
  final List<Widget> rows;
  final List<NotionPinnedShortcut> pins;
  final VoidCallback onCompose;
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final ValueChanged<String?> onNetworkSelected;
  final List<String> networks;
  final String? selectedNetwork;
  final InboxFilter selectedView;
  final ValueChanged<InboxFilter>? onViewSelected;
  final VoidCallback? onManageNetworks;
  final ScrollController? scrollController;
  final Widget? searchTools;
  final Widget? status;
  final bool loading;
  final String? emptyMessage;
  const NotionInboxPage({
    super.key,
    required this.rows,
    required this.pins,
    required this.onCompose,
    required this.onSettings,
    required this.onSearch,
    required this.onNetworkSelected,
    required this.networks,
    this.selectedNetwork,
    this.selectedView = InboxFilter.inbox,
    this.onViewSelected,
    this.onManageNetworks,
    this.scrollController,
    this.searchTools,
    this.status,
    this.loading = false,
    this.emptyMessage,
  });
  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final dockClearance =
        safe.bottom +
        notionInboxDockHeight(MediaQuery.textScalerOf(context)) +
        36;
    return Stack(
      children: [
        CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, safe.top + 8, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(child: Text('Chats', style: NotionTokens.title)),
                    NotionIconButton(
                      icon: Icons.edit_square,
                      label: 'New chat',
                      onPressed: onCompose,
                    ),
                  ],
                ),
              ),
            ),
            if (status != null)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(child: status),
              ),
            if (searchTools != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                sliver: SliverToBoxAdapter(child: searchTools),
              ),
            if (pins.isNotEmpty && searchTools == null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: NotionPinnedShortcuts(pins: pins),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                20,
                pins.isNotEmpty && searchTools == null ? 24 : 20,
                20,
                10,
              ),
              sliver: SliverToBoxAdapter(
                child: Text(
                  inboxViewLabel(selectedView),
                  style: NotionTokens.title.copyWith(fontSize: 28),
                ),
              ),
            ),
            if (loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: 'Loading chats',
                      ),
                    ),
                  ),
                ),
              ),
            if (!loading && rows.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    emptyMessage ?? 'No chats yet. Start a new chat.',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, dockClearance),
              sliver: SliverList(delegate: SliverChildListDelegate(rows)),
            ),
          ],
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: safe.bottom + 12,
          child: NotionInboxDock(
            onSettings: onSettings,
            onSearch: onSearch,
            onNetworkSelected: onNetworkSelected,
            networks: networks,
            selectedNetwork: selectedNetwork,
            selectedView: selectedView,
            onViewSelected: onViewSelected,
            onManageNetworks: onManageNetworks,
          ),
        ),
      ],
    );
  }
}
