// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_import.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_store.dart';

/// Message-menu entries for a received (or sent) sticker or GIF: add a
/// sticker to favourites, open its pack (Telegram/WhatsApp packs), save a
/// GIF. Empty for every other message. [display] is the shown version.
List<ConversationMessageAction> stickerMessageActions(
  BuildContext context,
  Event display,
) {
  final item = StickerItem.fromEvent(display);
  if (item == null) return const [];
  final client = display.room.client;
  final library = StickerLibrary.of(client);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigatorContext = context;
  void say(String text, VoidCallback undo) => messenger?.showSnackBar(
    SnackBar(
      content: Text(text),
      action: SnackBarAction(label: 'Undo', onPressed: undo),
    ),
  );

  if (item.kind == StickerKind.gif) {
    final saved = library.isSavedGif(item);
    return [
      ConversationMessageAction(
        icon: saved ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
        label: saved ? 'Remove from saved GIFs' : 'Save GIF',
        onSelected: () {
          if (saved) {
            final previous = library.savedGifs
                .where((g) => g.key == item.key)
                .firstOrNull;
            library.removeSavedGif(item);
            say(
              'Removed from saved GIFs',
              () => library.restore(StickerList.savedGifs, previous ?? item),
            );
          } else {
            library.saveGif(item);
            say('GIF saved', () => library.removeSavedGif(item));
          }
        },
      ),
    ];
  }
  final favourite = library.isFavourite(item);
  final link = StickerPackLink.parse(item.bridged?.packUrl);
  return [
    ConversationMessageAction(
      icon: favourite ? Icons.star : Icons.star_outline,
      label: favourite ? 'Remove from favourites' : 'Add to favourites',
      onSelected: () {
        if (favourite) {
          final previous = library.favourites
              .where((f) => f.key == item.key)
              .firstOrNull;
          library.removeFavourite(item);
          say(
            'Removed from favourite stickers',
            () => library.restore(
              StickerList.favouriteStickers,
              previous ?? item,
            ),
          );
        } else {
          library.addFavourite(item);
          say(
            'Added to favourite stickers',
            () => library.removeFavourite(item),
          );
        }
      },
    ),
    if (link != null)
      ConversationMessageAction(
        icon: Icons.collections_outlined,
        label: 'View sticker pack',
        onSelected: () => showStickerPackSheet(
          navigatorContext,
          client: client,
          link: link,
          library: library,
        ),
      ),
  ];
}

/// A tap on a sticker in a chat: its pack sheet when it comes from a
/// Telegram or WhatsApp pack (Telegram opens the set), otherwise [fallback]
/// (the image viewer).
void openStickerFromEvent(
  BuildContext context,
  Event event, {
  required VoidCallback fallback,
}) {
  final item = StickerItem.fromEvent(event);
  final link = StickerPackLink.parse(item?.bridged?.packUrl);
  if (item == null || item.kind != StickerKind.sticker || link == null) {
    fallback();
    return;
  }
  showStickerPackSheet(context, client: event.room.client, link: link);
}
