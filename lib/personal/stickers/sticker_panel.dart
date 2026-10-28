// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'gif_tab.dart';
import 'notion_emoji_picker.dart';
import 'sticker_library.dart';
import 'sticker_tab.dart';

/// Telegram's emoji panel tabs, in its order.
enum StickerPanelTab {
  emoji('Emoji', Icons.emoji_emotions_outlined),
  gifs('GIFs', Icons.gif_box_outlined),
  stickers('Stickers', Icons.sticky_note_2_outlined);

  const StickerPanelTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The composer's panel (Telegram's `EmojiView`): Emoji · GIFs · Stickers
/// as pills at the bottom, the last used tab remembered, backspace on the
/// emoji tab and the sticker settings on the sticker tab. Tabs are built
/// on first visit and kept (their scroll place too); hidden ones have
/// their tickers off. A tab switch fades through: the old tab fades out
/// quickly, the kept new one fades and settles in, nothing remounts.
///
/// The GIF and sticker tabs have their own search fields, both inside
/// [searchFocus] (it has focus while either has), so the panel's slot
/// knows when the keyboard is open for a search. While a search field has
/// focus the tab pills give their room to the results.
class StickerPanel extends StatefulWidget {
  const StickerPanel({
    super.key,
    required this.host,
    this.searchFocus,
    this.library,
  });

  final ConversationComposerHost host;

  /// Focus node for the search fields of the GIF and sticker tabs.
  final FocusNode? searchFocus;
  final StickerLibrary? library;

  static const _tabKey = 'pl.personal.composer.panel_tab';
  static StickerPanelTab? _lastTab;

  static StickerPanelTab get lastTab {
    final remembered = _lastTab;
    if (remembered != null) return remembered;
    try {
      final stored = AppSettings.store.getString(_tabKey);
      return _lastTab =
          StickerPanelTab.values.where((t) => t.name == stored).firstOrNull ??
          StickerPanelTab.emoji;
    } catch (_) {
      return _lastTab = StickerPanelTab.emoji;
    }
  }

  static void _remember(StickerPanelTab tab) {
    _lastTab = tab;
    try {
      AppSettings.store.setString(_tabKey, tab.name);
    } catch (_) {
      // Memory only.
    }
  }

  @visibleForTesting
  static void debugResetTab([StickerPanelTab? tab]) => _lastTab = tab;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel>
    with SingleTickerProviderStateMixin {
  late StickerPanelTab _tab = StickerPanel.lastTab;

  /// The tab on screen: during the first part of a switch still the old.
  late StickerPanelTab _shown = _tab;
  late final Set<StickerPanelTab> _visited = {_tab};

  /// Focus of each tab's own search field (children of the panel's node).
  final _gifSearch = FocusNode(debugLabel: 'GIF search');
  final _stickerSearch = FocusNode(debugLabel: 'sticker search');
  bool _searchFocused = false;

  /// Fade-through: out over [_outShare] of the run, then in.
  late final AnimationController _switch = AnimationController(
    vsync: this,
    duration: NotionMotion.instant + NotionMotion.short,
    value: 1,
  )..addListener(_switchTick);
  static final _outShare =
      NotionMotion.instant.inMicroseconds /
      (NotionMotion.instant + NotionMotion.short).inMicroseconds;

  @override
  void initState() {
    super.initState();
    widget.searchFocus?.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(StickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.searchFocus, widget.searchFocus)) {
      oldWidget.searchFocus?.removeListener(_focusChanged);
      widget.searchFocus?.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.searchFocus?.removeListener(_focusChanged);
    _switch.dispose();
    _gifSearch.dispose();
    _stickerSearch.dispose();
    super.dispose();
  }

  void _focusChanged() {
    final focused = widget.searchFocus?.hasFocus ?? false;
    if (focused != _searchFocused && mounted) {
      setState(() => _searchFocused = focused);
    }
  }

  void _switchTick() {
    if (_shown != _tab && _switch.value >= _outShare) {
      setState(() => _shown = _tab);
    }
  }

  void _select(StickerPanelTab tab) {
    if (tab == _tab) return;
    widget.searchFocus?.unfocus();
    _gifSearch.unfocus();
    _stickerSearch.unfocus();
    StickerPanel._remember(tab);
    setState(() {
      _tab = tab;
      // Built now, under the fading old tab, so it is ready to fade in.
      _visited.add(tab);
    });
    if (NotionMotion.reduced(context)) {
      _switch.value = 1;
      setState(() => _shown = tab);
    } else {
      _switch.forward(from: 0);
    }
  }

  Widget _content(StickerPanelTab tab) => switch (tab) {
    StickerPanelTab.emoji => ComposerEmojiTab(host: widget.host),
    StickerPanelTab.gifs => GifTab(
      host: widget.host,
      searchFocus: _gifSearch,
      library: widget.library,
    ),
    StickerPanelTab.stickers => StickerTab(
      host: widget.host,
      searchFocus: _stickerSearch,
      library: widget.library,
    ),
  };

  static final _inScale = Tween<double>(
    begin: .98,
    end: 1,
  ).chain(CurveTween(curve: NotionMotion.emphasized));

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    Widget tabs = IndexedStack(
      index: _shown.index,
      sizing: StackFit.expand,
      children: [
        for (final tab in StickerPanelTab.values)
          _visited.contains(tab)
              ? TickerMode(
                  enabled: tab == _shown,
                  child: KeyedSubtree(
                    key: ValueKey('panel-${tab.name}'),
                    child: _content(tab),
                  ),
                )
              : const SizedBox.shrink(),
      ],
    );
    final searchFocus = widget.searchFocus;
    if (searchFocus != null) {
      // Not focusable itself: it only reports its tabs' search fields.
      tabs = Focus(
        focusNode: searchFocus,
        canRequestFocus: false,
        skipTraversal: true,
        child: tabs,
      );
    }
    return ColoredBox(
      // Opaque like Telegram's panel: sticky titles and the search field
      // share this tone, whatever the chat's background.
      color: notionGlassOpaque(context, context.notion.glass.tint),
      child: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: _switch,
              // One shape at rest and in motion: the tabs never remount
              // (an opaque Opacity and a unit scale paint the child as is).
              builder: (context, child) {
                final t = _switch.value;
                final out = t < _outShare;
                final phase = out
                    ? t / _outShare
                    : (t - _outShare) / (1 - _outShare);
                return Opacity(
                  opacity: out
                      ? 1 - NotionMotion.exitFast.transform(phase)
                      : NotionMotion.standard.transform(phase),
                  child: Transform.scale(
                    scale: out ? 1 : _inScale.transform(phase),
                    child: child,
                  ),
                );
              },
              child: tabs,
            ),
          ),
          NotionSizeReveal(
            visible: !_searchFocused,
            duration: NotionMotion.short,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.border)),
              ),
              child: SizedBox(
                height: NotionSize.touchTarget,
                child: Row(
                  children: [
                    const SizedBox(width: NotionSize.touchTarget),
                    Expanded(
                      // Large text on a narrow phone: the pills shrink
                      // together instead of overflowing.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final tab in StickerPanelTab.values)
                              _PanelTabPill(
                                tab: tab,
                                selected: tab == _tab,
                                onTap: () => _select(tab),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: NotionSize.touchTarget,
                      child: switch (_tab) {
                        StickerPanelTab.emoji => NotionIconButton(
                          icon: Icons.backspace_outlined,
                          label: 'Delete',
                          onPressed: widget.host.emojiPickerBackspace,
                        ),
                        StickerPanelTab.stickers => NotionIconButton(
                          icon: Icons.settings_outlined,
                          label: 'Sticker settings',
                          onPressed: () =>
                              context.push('/rooms/settings/chat/stickers'),
                        ),
                        StickerPanelTab.gifs => const SizedBox.shrink(),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelTabPill extends StatelessWidget {
  const _PanelTabPill({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final StickerPanelTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    return Semantics(
      button: true,
      selected: selected,
      child: NotionPressable(
        scale: NotionMotion.pressButton,
        child: InkWell(
          key: ValueKey('panel-tab-${tab.name}'),
          onTap: onTap,
          borderRadius: NotionRadius.pillAll,
          child: AnimatedContainer(
            duration: NotionMotion.of(context, NotionMotion.quick),
            curve: NotionMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.sm,
              vertical: NotionSpace.xxs,
            ),
            margin: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
            decoration: BoxDecoration(
              color: selected ? notion.palette.accentTint : Colors.transparent,
              borderRadius: NotionRadius.pillAll,
            ),
            child: Text(
              tab.label,
              style: NotionType.callout.copyWith(
                color: selected
                    ? notion.colors.text
                    : notion.colors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
