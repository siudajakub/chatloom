// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/emoji/emoji_picker.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show Emoji;
import 'package:material_ui/material_ui.dart';

export 'package:chatloom/personal/emoji/emoji_picker.dart';

/// The composer panel's Emoji tab (Telegram's emoji page): search, the
/// category bar, Recently used and the categories, typed into the composer
/// at the cursor; a tap closes the panel. The search field has its own focus node; the panel slot
/// sees it through the panel's focus scope ([ChatEmojiPicker]) and stays
/// above the keyboard while it is focused. A hidden tab lets go of focus.
class ComposerEmojiTab extends StatefulWidget {
  const ComposerEmojiTab({super.key, required this.host});

  final ConversationComposerHost host;

  @override
  State<ComposerEmojiTab> createState() => _ComposerEmojiTabState();
}

class _ComposerEmojiTabState extends State<ComposerEmojiTab> {
  final _search = FocusNode(debugLabel: 'composer emoji search');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The panel turns tickers off for hidden tabs.
    final hidden = !TickerMode.valuesOf(context).enabled;
    if (hidden && _search.hasFocus) _search.unfocus();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatLoomEmojiPicker(
    focusNode: _search,
    // The composer strip is a glass bar: its resting tone behind headers.
    background: notionGlassOpaque(context, context.notion.glass.tint),
    onSelected: _selected,
  );

  /// One emoji per tap (Telegram, WhatsApp): it goes in at the cursor, then
  /// the panel closes as its toggle closes it, the field taking focus so the
  /// keyboard comes back. Search results land here too.
  void _selected(String emoji) {
    final host = widget.host;
    host.onEmojiSelected(null, Emoji(emoji, ''));
    if (host.showEmojiPicker) host.emojiPickerAction();
  }
}
