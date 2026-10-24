// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';
import 'sticker_sender.dart';
import 'sticker_tile.dart';

/// Most suggestions in the strip (Telegram shows one scrollable row).
const stickerSuggestionLimit = 20;

/// The stickers Telegram suggests for [text]: when the whole message is one
/// emoji, the installed stickers tagged with it — favourites first, then
/// recent, then the packs in order (the library's search index order) —
/// limited to [limit]; nothing for any other text. GIFs are never
/// suggested. [allowed] drops the ones the room cannot receive.
List<StickerItem> stickerSuggestionsFor(
  String text,
  List<StickerItem> Function(String emoji) search, {
  bool Function(StickerItem item)? allowed,
  int limit = stickerSuggestionLimit,
}) {
  final emoji = text.trim();
  if (emoji.isEmpty || emoji.characters.length != 1 || !isEmojiOnly(emoji)) {
    return const [];
  }
  return search(emoji)
      .where(
        (item) =>
            item.kind == StickerKind.sticker &&
            (allowed == null || allowed(item)),
      )
      .take(limit)
      .toList();
}

/// Emoji → sticker suggestions above the composer (Telegram's
/// `SuggestEmojiView` sticker row): appears while the message is a single
/// emoji that matches installed stickers. A tap sends the sticker (as a
/// reply when one is being composed) and clears the emoji; a long press
/// previews it. Static thumbnails (tickers off), as in the panel.
///
/// Hidden while editing, while the composer cannot send, and when
/// Settings › Stickers › "Suggest stickers by emoji" is off.
class StickerSuggestionStrip extends StatefulWidget {
  const StickerSuggestionStrip({super.key, required this.host});

  final ConversationComposerHost host;

  /// Side of one suggestion cell.
  static const double cellSize = 64;

  @override
  State<StickerSuggestionStrip> createState() => _StickerSuggestionStripState();
}

class _StickerSuggestionStripState extends State<StickerSuggestionStrip> {
  StickerLibrary? _library;
  String? _text;
  List<StickerItem> _items = const [];

  /// The last non-empty row, kept while the strip closes.
  List<StickerItem> _shown = const [];

  /// The library changed since [_items] was computed.
  bool _stale = true;

  ConversationComposerHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _host.sendController.addListener(_textChanged);
    _attachLibrary();
  }

  @override
  void didUpdateWidget(StickerSuggestionStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.host.sendController, _host.sendController)) {
      oldWidget.host.sendController.removeListener(_textChanged);
      _host.sendController.addListener(_textChanged);
    }
    _attachLibrary();
  }

  void _attachLibrary() {
    final library = StickerLibrary.of(_host.room.client);
    if (identical(library, _library)) return;
    _library?.removeListener(_libraryChanged);
    _library = library..addListener(_libraryChanged);
    _stale = true;
  }

  void _libraryChanged() {
    _stale = true;
    if (mounted) setState(() {});
  }

  /// Rebuilds only when the text changed (not on selection moves).
  void _textChanged() {
    if (_host.sendController.text != _text && mounted) setState(() {});
  }

  @override
  void dispose() {
    _host.sendController.removeListener(_textChanged);
    _library?.removeListener(_libraryChanged);
    super.dispose();
  }

  List<StickerItem> _suggestions() {
    final text = _host.sendController.text;
    if (text == _text && !_stale) return _items;
    _text = text;
    _stale = false;
    final library = _library!;
    final room = _host.room;
    return _items = stickerSuggestionsFor(
      text,
      library.search,
      allowed: (item) => StickerSendPlan.forRoom(room, item).possible,
    );
  }

  bool get _enabled =>
      AppSettings.stickerSuggestions.value &&
      _host.composerEnabled &&
      _host.editEvent == null;

  Future<void> _send(StickerItem item) async {
    final controller = _host.sendController;
    final typed = controller.text;
    final sent = await StickerSender.send(context, _host, item);
    // The emoji became the sticker (Telegram); a draft typed meanwhile
    // stays.
    if (!sent || !mounted || controller.text != typed) return;
    controller.clear();
    _host.onInputBarChanged('');
  }

  void _preview(StickerItem item) {
    final room = _host.room;
    final plan = StickerSendPlan.forRoom(room, item);
    final library = _library!;
    final favourite = library.isFavourite(item);
    unawaited(
      showStickerPreview(
        context,
        item: item,
        client: room.client,
        note: plan.possible ? null : plan.reason,
        actions: [
          StickerPreviewAction(
            icon: Icons.send_outlined,
            label: 'Send',
            onSelected: plan.possible ? () => unawaited(_send(item)) : null,
          ),
          StickerPreviewAction(
            icon: favourite ? Icons.star : Icons.star_outline,
            label: favourite ? 'Remove from favourites' : 'Add to favourites',
            onSelected: () => library.toggleFavourite(item),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _enabled ? _suggestions() : const <StickerItem>[];
    if (items.isNotEmpty) _shown = items;
    final shown = _shown;
    final colors = context.notion.colors;
    return NotionSizeReveal(
      visible: items.isNotEmpty,
      alignment: AlignmentDirectional.bottomStart,
      child: shown.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(
                NotionSpace.xs,
                NotionSpace.xxs,
                NotionSpace.xs,
                NotionSpace.xxs,
              ),
              child: Semantics(
                container: true,
                label: 'Sticker suggestions',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: NotionRadius.lgAll,
                    border: Border.all(color: colors.border),
                  ),
                  child: SizedBox(
                    height: StickerSuggestionStrip.cellSize + NotionSpace.xs,
                    // Static cells, as in the panel (battery): the preview
                    // animates.
                    child: TickerMode(
                      enabled: false,
                      child: ListView.builder(
                        key: const ValueKey('sticker-suggestions'),
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(NotionSpace.xxs),
                        itemCount: shown.length,
                        itemBuilder: (context, index) {
                          final item = shown[index];
                          return StickerTile(
                            key: ValueKey(item.key),
                            item: item,
                            client: _host.room.client,
                            size: StickerSuggestionStrip.cellSize,
                            onTap: () => unawaited(_send(item)),
                            onLongPress: () => _preview(item),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
