// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/widgets.dart';

import 'sticker_models.dart';

/// Search over the library's stickers, built once per library change.
///
/// Telegram combines emoji → sticker, keyword → emoji → sticker, local
/// pack titles and a server search; ChatLoom has no server search, the
/// rest works on the device: an emoji finds the stickers tagged with it,
/// a word finds the stickers whose emoji's keywords (the emoji picker's
/// own keyword lists, in the app language and English) contain it, and
/// shortcodes and pack titles match directly.
class StickerSearchIndex {
  StickerSearchIndex(Iterable<StickerItem> items, {this.packs = const []}) {
    for (final item in items) {
      if (!_items.containsKey(item.key)) _items[item.key] = item;
      final emoji = item.emoji;
      if (emoji == null) continue;
      for (final single in _splitEmoji(emoji)) {
        (_byEmoji[single] ??= {}).add(item.key);
      }
    }
  }

  final List<StickerPack> packs;
  final _items = <String, StickerItem>{};
  final _byEmoji = <String, Set<String>>{};

  /// Max results (Telegram shows a few rows; more never helps).
  static const limit = 200;

  /// Emoji keyword lists per language, built on first use.
  static final _keywords = <String, List<(String, List<String>)>>{};

  static List<(String, List<String>)> _keywordsFor(String languageCode) =>
      _keywords.putIfAbsent(languageCode, () {
        final out = <(String, List<String>)>[];
        for (final category in getDefaultEmojiLocale(Locale(languageCode))) {
          for (final emoji in category.emoji) {
            out.add((
              normalizeEmoji(emoji.emoji),
              [for (final k in emoji.keywords) k.trim().toLowerCase()],
            ));
          }
        }
        return out;
      });

  static Iterable<String> _splitEmoji(String text) sync* {
    final normalized = normalizeEmoji(text);
    if (normalized.isEmpty) return;
    yield normalized;
    // "😂👍" also finds each emoji alone.
    final characters = normalized.characters.toList();
    if (characters.length > 1) {
      for (final c in characters) {
        final single = normalizeEmoji(c);
        if (single.isNotEmpty) yield single;
      }
    }
  }

  List<StickerItem> search(String query, {String? languageCode}) {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final found = <String>{};
    final out = <StickerItem>[];
    void add(String key) {
      if (out.length >= limit || !found.add(key)) return;
      final item = _items[key];
      if (item != null) out.add(item);
    }

    if (isEmojiOnly(text)) {
      for (final emoji in _splitEmoji(text)) {
        for (final key in _byEmoji[emoji] ?? const <String>{}) {
          add(key);
        }
      }
      return out;
    }
    final word = text.toLowerCase();
    // 1. Stickers of the emoji whose keywords match the word.
    final languages = {
      if (languageCode != null && languageCode.isNotEmpty) languageCode,
      'en',
    };
    for (final language in languages) {
      for (final (emoji, keywords) in _keywordsFor(language)) {
        if (!_byEmoji.containsKey(emoji)) continue;
        if (keywords.any((k) => k.startsWith(word))) {
          for (final key in _byEmoji[emoji]!) {
            add(key);
          }
        }
      }
    }
    // 2. Shortcodes and bodies ("<pack>_<keyword>" for Telegram packs).
    for (final item in _items.values) {
      final shortcode = item.shortcode?.toLowerCase() ?? '';
      if (shortcode.contains(word) || item.body.toLowerCase().contains(word)) {
        add(item.key);
      }
    }
    // 3. Whole packs whose title matches.
    for (final pack in packs) {
      if (!pack.title.toLowerCase().contains(word)) continue;
      for (final sticker in pack.stickers) {
        add(sticker.key);
      }
    }
    return out;
  }
}
