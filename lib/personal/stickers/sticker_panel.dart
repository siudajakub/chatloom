// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
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
/// on first visit and kept; hidden ones have their tickers off.
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

class _StickerPanelState extends State<StickerPanel> {
  late StickerPanelTab _tab = StickerPanel.lastTab;
  late final Set<StickerPanelTab> _visited = {_tab};

  void _select(StickerPanelTab tab) {
    if (tab == _tab) return;
    widget.searchFocus?.unfocus();
    StickerPanel._remember(tab);
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  Widget _content(StickerPanelTab tab) => switch (tab) {
    StickerPanelTab.emoji => EmojiPicker(
      onEmojiSelected: widget.host.onEmojiSelected,
      onBackspacePressed: widget.host.emojiPickerBackspace,
      config: notionEmojiPickerConfig(context),
    ),
    StickerPanelTab.gifs => GifTab(
      host: widget.host,
      searchFocus: widget.searchFocus,
      library: widget.library,
    ),
    StickerPanelTab.stickers => StickerTab(
      host: widget.host,
      searchFocus: widget.searchFocus,
      library: widget.library,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return Column(
      children: [
        Expanded(
          child: IndexedStack(
            index: _tab.index,
            sizing: StackFit.expand,
            children: [
              for (final tab in StickerPanelTab.values)
                _visited.contains(tab)
                    ? TickerMode(
                        enabled: tab == _tab,
                        child: KeyedSubtree(
                          key: ValueKey('panel-${tab.name}'),
                          child: _content(tab),
                        ),
                      )
                    : const SizedBox.shrink(),
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: SizedBox(
            height: NotionSize.touchTarget,
            child: Row(
              children: [
                const SizedBox(width: NotionSize.touchTarget),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
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
      ],
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
