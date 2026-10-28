// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/stickers/composer_panel.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'conversation_source.dart';

/// The composer's Emoji · GIFs · Stickers panel at the keyboard's height
/// (Telegram): it takes the keyboard's place without moving the composer.
/// Shared by ordinary and merged chats.
class ChatEmojiPicker extends StatefulWidget {
  final ConversationComposerHost controller;
  const ChatEmojiPicker(this.controller, {super.key});

  @override
  State<ChatEmojiPicker> createState() => _ChatEmojiPickerState();
}

class _ChatEmojiPickerState extends State<ChatEmojiPicker> {
  /// The panel's own search fields (stickers, GIFs).
  final _searchFocus = FocusNode(debugLabel: 'composer panel search');

  /// Holds every field of the panel (the emoji search has its own node):
  /// while any of them is focused the slot stays above the keyboard.
  final _panelScope = FocusScopeNode(debugLabel: 'composer panel');

  @override
  void dispose() {
    _searchFocus.dispose();
    _panelScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ComposerPanelSlot(
    visible: widget.controller.showEmojiPicker,
    inputFocus: widget.controller.inputFocus,
    searchFocus: _panelScope,
    builder: (context, height) => FocusScope(
      node: _panelScope,
      child: StickerPanel(host: widget.controller, searchFocus: _searchFocus),
    ),
  );
}
