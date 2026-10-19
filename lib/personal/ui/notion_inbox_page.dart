// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_inbox_dock.dart';
import 'package:fluffychat/personal/ui/notion_inbox_pins.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Production inbox composition. Account adapters supply rows and real actions.
///
/// Rows are either a prebuilt [rows] list (captures, small fixtures) or a lazy
/// [rowCount]/[rowBuilder] pair; [rowIndexOf] maps a row key to its index so
/// reordering keeps each row's element (avatars do not reload or fade).
class NotionInboxPage extends StatelessWidget {
  final List<Widget> rows;
  final int? rowCount;
  final IndexedWidgetBuilder? rowBuilder;
  final int? Function(Key key)? rowIndexOf;
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
    this.rows = const [],
    this.rowCount,
    this.rowBuilder,
    this.rowIndexOf,
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
  int? _indexOfRow(Key key) {
    final index = rows.indexWhere((row) => row.key == key);
    return index < 0 ? null : index;
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final builder = rowBuilder ?? ((context, index) => rows[index]);
    final count = rowBuilder == null ? rows.length : rowCount ?? 0;
    final dockClearance =
        safe.bottom +
        notionInboxDockHeight(MediaQuery.textScalerOf(context)) +
        36;
    final showPins = pins.isNotEmpty && searchTools == null;
    final emptyText = emptyMessage ?? 'No chats yet. Start a new chat.';
    // One backdrop read for the glass header and dock (DESIGN.md "Glass").
    return BackdropGroup(
      child: Scaffold(
        // Register the dock with Scaffold geometry so every snackbar clears it.
        // extendBody keeps the conversation list visible through the glass.
        extendBody: true,
        // The first screenful of pins and rows rises in once per page; rows
        // built later by scrolling or filtering appear as they are.
        body: NotionEntranceScope(
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              PinnedHeaderSliver(
                child: NotionGlassBar(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      NotionSpace.inset,
                      safe.top + NotionSpace.xs,
                      NotionSpace.inset,
                      NotionSpace.xxs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('Chats', style: NotionTokens.title),
                        ),
                        NotionIconButton(
                          icon: Icons.edit_square,
                          label: 'New chat',
                          onPressed: onCompose,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (status != null)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverToBoxAdapter(child: status),
                ),
              // Search tools and pins grow in and out instead of jumping.
              SliverToBoxAdapter(
                child: _RetainedReveal(
                  child: searchTools == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: searchTools,
                        ),
                ),
              ),
              SliverToBoxAdapter(
                child: _RetainedReveal(
                  revealOnMount: false,
                  child: showPins
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: NotionEntrance(
                            rise: NotionMotion.riseList,
                            child: NotionPinnedShortcuts(pins: pins),
                          ),
                        )
                      : null,
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(20, showPins ? 24 : 20, 20, 10),
                sliver: SliverToBoxAdapter(
                  child: NotionFadeThrough(
                    child: Text(
                      inboxViewLabel(selectedView),
                      key: ValueKey(selectedView),
                      style: NotionTokens.title.copyWith(fontSize: 28),
                    ),
                  ),
                ),
              ),
              if (loading)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverToBoxAdapter(
                    child: Semantics(
                      label: 'Loading chats',
                      child: ExcludeSemantics(
                        child: NotionSkeleton(
                          child: Column(
                            children: List.filled(
                              _skeletonRows,
                              const NotionSkeletonRow(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (!loading && count == 0)
                SliverToBoxAdapter(
                  child: NotionFadeThrough(
                    alignment: AlignmentDirectional.topCenter,
                    child: NotionEmptyState(
                      key: ValueKey(emptyText),
                      icon: searchTools != null
                          ? Icons.search_off
                          : Icons.chat_bubble_outline,
                      title: emptyText,
                    ),
                  ),
                ),
              _SliverFadeOnChange(
                signal: (selectedView, selectedNetwork, loading),
                sliver: SliverPadding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, dockClearance),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final row = builder(context, index);
                        // Same key as the row, so reordering keeps elements
                        // (a GlobalKey keeps its element on its own).
                        final key = row.key;
                        return NotionEntrance(
                          key: key is GlobalKey ? null : key,
                          playKey: row.key,
                          rise: NotionMotion.riseList,
                          child: row,
                        );
                      },
                      childCount: count,
                      findChildIndexCallback: rowIndexOf ?? _indexOfRow,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: Padding(
          padding: EdgeInsets.fromLTRB(
            NotionSpace.md,
            0,
            NotionSpace.md,
            safe.bottom + NotionSpace.sm,
          ),
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
      ),
    );
  }
}

/// Placeholder rows while the first inbox load runs (about one screenful).
const _skeletonRows = 8;

/// Keeps showing the last non-null [child] while it collapses, so a section
/// that goes away (search tools, pins) shrinks out instead of vanishing.
class _RetainedReveal extends StatefulWidget {
  const _RetainedReveal({required this.child, this.revealOnMount = true});

  final Widget? child;
  final bool revealOnMount;

  @override
  State<_RetainedReveal> createState() => _RetainedRevealState();
}

class _RetainedRevealState extends State<_RetainedReveal> {
  Widget? _last;

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (child != null) _last = child;
    final shown = _last;
    if (shown == null) return const SizedBox.shrink();
    return NotionSizeReveal(
      visible: child != null,
      revealOnMount: widget.revealOnMount,
      // The reveal loosens width; keep sections full width.
      child: SizedBox(width: double.infinity, child: shown),
    );
  }
}

/// Fades the row list in again whenever [signal] changes (another view,
/// network or the end of the first load), instead of a hard cut. Settles at
/// full opacity; nothing under reduced motion.
class _SliverFadeOnChange extends StatefulWidget {
  const _SliverFadeOnChange({required this.signal, required this.sliver});

  final Object signal;
  final Widget sliver;

  @override
  State<_SliverFadeOnChange> createState() => _SliverFadeOnChangeState();
}

class _SliverFadeOnChangeState extends State<_SliverFadeOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
    value: 1,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _controller,
    curve: NotionMotion.standard,
  );

  @override
  void didUpdateWidget(_SliverFadeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.signal != widget.signal && !NotionMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _opacity, sliver: widget.sliver);
}
