// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_inbox_dock.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_inbox_view_chips.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Production inbox composition. Account adapters supply rows and real actions.
///
/// Rows are either a prebuilt [rows] list (captures, small fixtures) or a lazy
/// [rowCount]/[rowBuilder] pair; [rowIndexOf] maps a row key to its index so
/// reordering keeps each row's element (avatars do not reload or fade).
/// When the order changes, rows glide to their new places and new rows fade
/// in ([NotionListMotion]); lazy rows name their order in [rowOrder].
class NotionInboxPage extends StatelessWidget {
  final List<Widget> rows;
  final int? rowCount;
  final IndexedWidgetBuilder? rowBuilder;
  final int? Function(Key key)? rowIndexOf;

  /// Identities of the lazy rows in order (for example room IDs); a change
  /// moves the rows. Prebuilt [rows] use their keys.
  final List<Object?>? rowOrder;
  final List<NotionPinnedShortcut> pins;
  final VoidCallback onSettings;

  /// Opens the full-screen search, the one place to find and start chats.
  final VoidCallback onSearch;
  final ValueChanged<String?> onNetworkSelected;
  final List<String> networks;
  final String? selectedNetwork;
  final InboxFilter selectedView;
  final ValueChanged<InboxFilter>? onViewSelected;
  final VoidCallback? onManageNetworks;

  /// "Mark all as read" in the dock's "Show chats" menu (FX-17).
  final VoidCallback? onMarkAllRead;

  /// New order of the pin keys after a drag (FX-17); null: pins stay put.
  final Future<void> Function(List<String> keys)? onReorderPins;
  final ScrollController? scrollController;
  final Widget? status;

  /// A one-line status inside the glass header, under the title (for
  /// example "Connecting…"). Grows in and out; null hides it.
  final Widget? headerStatus;
  final bool loading;
  final String? emptyMessage;

  /// Unread chats of the current network selection, on the "Unread" chip.
  final int unreadCount;

  /// Message requests waiting for an answer; the "Requests" chip shows
  /// while there are some (FX-02).
  final int requestCount;
  const NotionInboxPage({
    super.key,
    this.rows = const [],
    this.rowCount,
    this.rowBuilder,
    this.rowIndexOf,
    this.rowOrder,
    required this.pins,
    required this.onSettings,
    required this.onSearch,
    required this.onNetworkSelected,
    required this.networks,
    this.selectedNetwork,
    this.selectedView = InboxFilter.inbox,
    this.onViewSelected,
    this.onManageNetworks,
    this.onMarkAllRead,
    this.onReorderPins,
    this.scrollController,
    this.status,
    this.headerStatus,
    this.loading = false,
    this.emptyMessage,
    this.unreadCount = 0,
    this.requestCount = 0,
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
    final showPins = pins.isNotEmpty;
    final emptyText =
        emptyMessage ?? 'No chats yet. Use Search to find people.';
    // One backdrop read for the glass header and dock (DESIGN.md "Glass").
    return BackdropGroup(
      child: Scaffold(
        // Register the dock with Scaffold geometry so every snackbar clears it.
        // extendBody keeps the conversation list visible through the glass.
        extendBody: true,
        // The first screenful of pins and rows rises in once per page; rows
        // built later by scrolling or filtering appear as they are.
        body: NotionEntranceScope(
          // A chat that moves (new message) glides to its place while the
          // rows it passes slide aside; another view or network, or the end
          // of the first load, swaps the list without motion.
          child: NotionListMotion(
            order:
                rowOrder ??
                (rowBuilder == null
                    ? [for (final row in rows) row.key]
                    : const []),
            epoch: (selectedView, selectedNetwork, loading),
            background: Theme.of(context).scaffoldBackgroundColor,
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // New chats start from Search (dock), like Telegram
                          // and Messenger; the title keeps the touch-row height.
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: NotionSize.touchTarget,
                            ),
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text('Chats', style: NotionTokens.title),
                            ),
                          ),
                          _RetainedReveal(
                            revealOnMount: false,
                            child: headerStatus,
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
                // Pins grow in and out instead of jumping.
                SliverToBoxAdapter(
                  child: _RetainedReveal(
                    revealOnMount: false,
                    child: showPins
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                            child: NotionEntrance(
                              rise: NotionMotion.riseList,
                              child: NotionPinnedShortcuts(
                                pins: pins,
                                onReorder: onReorderPins,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
                // One-tap views (UX-16) instead of a second large title; the
                // same state as the dock's "Show chats" menu.
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    NotionSpace.inset,
                    showPins ? NotionSpace.md : NotionSpace.sm,
                    NotionSpace.inset,
                    NotionSpace.xs,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: NotionInboxViewChips(
                      selected: selectedView,
                      onViewSelected: onViewSelected,
                      unreadCount: unreadCount,
                      requestCount: requestCount,
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
                        icon: Icons.chat_bubble_outline,
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
                          return NotionListMotionItem(
                            key: key is GlobalKey ? null : key,
                            index: index,
                            // The gap belongs to the item, so reorder offsets
                            // include it and highlights never touch.
                            child: Padding(
                              padding: NotionSpace.listItem,
                              child: NotionEntrance(
                                playKey: row.key,
                                rise: NotionMotion.riseList,
                                child: row,
                              ),
                            ),
                          );
                        },
                        childCount: count,
                        findChildIndexCallback: rowIndexOf ?? _indexOfRow,
                        // The motion item adds the boundary and semantic
                        // index itself; it must sit directly in the list.
                        addRepaintBoundaries: false,
                        addSemanticIndexes: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
            onMarkAllRead: onMarkAllRead,
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while the first inbox load runs (about one screenful).
const _skeletonRows = 8;

/// Keeps showing the last non-null [child] while it collapses, so a section
/// that goes away (pins, the header status) shrinks out instead of vanishing.
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
/// network or the end of the first load), instead of a hard cut, from
/// [NotionMotion.refreshFrom] (never blank). Settles at full opacity;
/// nothing under reduced motion.
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
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: NotionMotion.standard,
  );
  // Never from 0: an empty first frame flashed the bare page through the
  // glass dock and header.
  late final Animation<double> _opacity = _curve.drive(
    Tween(begin: NotionMotion.refreshFrom, end: 1),
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
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _opacity, sliver: widget.sliver);
}
