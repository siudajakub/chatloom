// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/bridge_capabilities.dart'
    show normalizeReactionKey;

import 'emoji_catalog.dart';

export 'emoji_catalog.dart';

/// What a reaction picker offers in one chat.
@immutable
class EmojiReactionChoices {
  const EmojiReactionChoices({
    this.allowed,
    this.quick = const [],
    this.own = const {},
  });

  /// The network's `allowed_reactions` in its order and spelling; null
  /// means any emoji. When set, the picker shows exactly these.
  final List<String>? allowed;

  /// The chat's quick reactions (the long-press bar), shown first.
  final List<String> quick;

  /// Reactions the user already gave on the message (marked).
  final Set<String> own;
}

/// ChatLoom's emoji picker with the catalogue, the shared recents and the
/// remembered skin tones (see [NotionEmojiPicker] for the look).
///
/// Composer and settings: Recently used, then the categories. Reactions
/// ([reactions] set): the chat's quick reactions on top, then Recently
/// used and the categories; when the network has a fixed set
/// (`allowed_reactions`, every Telegram chat) exactly that set in its order
/// and spelling, searchable, with no skin tones (the network has none).
class ChatLoomEmojiPicker extends StatefulWidget {
  const ChatLoomEmojiPicker({
    super.key,
    required this.onSelected,
    this.reactions,
    this.focusNode,
    this.autofocus = false,
    this.background,
    this.controller,
  });

  final ValueChanged<String> onSelected;
  final EmojiReactionChoices? reactions;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? background;
  final TextEditingController? controller;

  @override
  State<ChatLoomEmojiPicker> createState() => _ChatLoomEmojiPickerState();
}

class _ChatLoomEmojiPickerState extends State<ChatLoomEmojiPicker> {
  // Read once per open: the grid never reshuffles under the finger.
  late List<NotionEmojiSection> _sections;
  late NotionEmojiSearch _search;
  late bool _restricted;
  late Map<String, int> _usage;
  Map<String, String> _tones = EmojiSkinTones.all;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(ChatLoomEmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reactions != widget.reactions) _build();
  }

  static NotionEmoji _entry(String glyph, {bool tones = true}) {
    final known = EmojiCatalog.lookup(glyph);
    return NotionEmoji(
      glyph,
      keywords: known?.keywords ?? const [],
      tones:
          tones &&
          (known?.tones ?? false) &&
          NotionEmojiTones.of(glyph) == null,
    );
  }

  void _build() {
    final reactions = widget.reactions;
    final allowed = reactions?.allowed;
    _restricted = allowed != null;
    _usage = EmojiRecents.usage;
    final recents = EmojiRecents.emoji;
    if (allowed != null) {
      // The network's spelling for every offered emoji.
      final spelling = {
        for (final key in allowed) normalizeReactionKey(key): key,
      };
      final quick = [
        for (final e in reactions!.quick) ?spelling[normalizeReactionKey(e)],
      ];
      final quickKeys = {for (final e in quick) normalizeReactionKey(e)};
      final recent = <String>[];
      for (final e in recents) {
        final s = spelling[normalizeReactionKey(e)];
        if (s != null &&
            !quickKeys.contains(normalizeReactionKey(s)) &&
            !recent.contains(s)) {
          recent.add(s);
        }
      }
      final all = [
        for (final key in spelling.values) _entry(key, tones: false),
      ];
      _sections = [
        NotionEmojiSection(
          id: 'quick',
          title: 'Quick reactions',
          icon: Icons.favorite_border_rounded,
          emoji: [for (final e in quick) _entry(e, tones: false)],
        ),
        NotionEmojiSection(
          id: 'recent',
          title: 'Recently used',
          icon: Icons.history_rounded,
          emoji: [for (final e in recent.take(16)) _entry(e, tones: false)],
        ),
        NotionEmojiSection(
          id: 'allowed',
          title: 'Reactions in this chat',
          icon: Icons.add_reaction_outlined,
          emoji: all,
        ),
      ];
      _search = NotionEmojiSearch(
        all,
        aliases: EmojiCatalog.aliases,
        popular: EmojiCatalog.popular,
      );
      return;
    }
    final quick = reactions?.quick ?? const <String>[];
    final quickKeys = {for (final e in quick) normalizeReactionKey(e)};
    _sections = [
      if (quick.isNotEmpty)
        NotionEmojiSection(
          id: 'quick',
          title: 'Quick reactions',
          icon: Icons.favorite_border_rounded,
          emoji: [for (final e in quick) _entry(e)],
        ),
      NotionEmojiSection(
        id: 'recent',
        title: 'Recently used',
        icon: Icons.history_rounded,
        emoji: [
          for (final e in recents)
            if (!quickKeys.contains(normalizeReactionKey(e))) _entry(e),
        ],
      ),
      ...EmojiCatalog.categories,
    ];
    _search = EmojiCatalog.search;
  }

  void _selected(String glyph) {
    EmojiRecents.add(glyph);
    widget.onSelected(glyph);
  }

  void _tone(String emoji, String? tone) {
    EmojiSkinTones.remember(emoji, tone);
    setState(() => _tones = EmojiSkinTones.all);
  }

  @override
  Widget build(BuildContext context) => NotionEmojiPicker(
    sections: _sections,
    onSelected: _selected,
    search: _search,
    usage: _usage,
    selected: widget.reactions?.own ?? const {},
    tones: _restricted ? const {} : _tones,
    onTone: _restricted ? null : _tone,
    categoryBar: !_restricted,
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    hint: _restricted ? 'Search reactions' : 'Search emoji',
    emptyLabel: _restricted
        ? 'No matching reaction in this chat'
        : 'No emoji found',
    background: widget.background,
    controller: widget.controller,
  );
}

/// The picker in a Notion sheet; resolves to the chosen emoji, or null.
/// The sheet rises above the keyboard while searching and its grid shrinks
/// to what is left, so the results stay in view. [footer] sits under the
/// grid (the double-tap picker's "Automatic").
Future<String?> showEmojiPickerSheet(
  BuildContext context, {
  required String title,
  EmojiReactionChoices? reactions,
  Widget Function(BuildContext context)? footer,
}) => showNotionSheet<String>(
  context: context,
  title: title,
  builder: (context) => _EmojiSheetBody(reactions: reactions, footer: footer),
);

class _EmojiSheetBody extends StatelessWidget {
  const _EmojiSheetBody({required this.reactions, required this.footer});

  final EmojiReactionChoices? reactions;
  final Widget Function(BuildContext context)? footer;

  /// Height of the grid, search and bar together (Telegram's half sheet).
  static const double _preferred = 460;
  static const double _least = 220;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // Room above the keyboard, less the sheet's title, handle and margins.
    final room = media.size.height - keyboard - media.padding.top - 140;
    final height = math.min(
      math.min(_preferred, media.size.height * .62),
      math.max(_least, room),
    );
    final footer = this.footer;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: ChatLoomEmojiPicker(
              reactions: reactions,
              onSelected: (emoji) => Navigator.of(context).pop(emoji),
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: NotionSpace.sm),
            footer(context),
          ],
        ],
      ),
    );
  }
}
