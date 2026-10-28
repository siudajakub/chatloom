// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/widgets.dart';

import 'sticker_models.dart';

/// What a sticker search found: the stickers that match the query, best
/// first, and the packs whose title matches (shown whole, Telegram).
@immutable
class StickerSearchResults {
  const StickerSearchResults({this.stickers = const [], this.packs = const []});

  static const empty = StickerSearchResults();

  final List<StickerItem> stickers;
  final List<StickerPack> packs;

  bool get isEmpty => stickers.isEmpty && packs.isEmpty;
}

/// Search over the library's stickers, built once per library change.
///
/// Telegram combines emoji → sticker, keyword → emoji → sticker, local
/// pack titles and a server search; ChatLoom has no server search, the
/// rest works on the device and is instant (no debounce needed):
///
/// - an emoji (typed or pasted, several at once too) finds the stickers
///   tagged with it; stickers matching more of the emoji rank first;
/// - a word finds stickers whose shortcode or alt text (body) has it as a
///   word, then the stickers of the emoji whose keywords (the emoji
///   picker's own lists, in the app language and English) are that word,
///   then prefix matches of both, then substrings of shortcode and alt
///   text; every word of a longer query must match;
/// - packs whose title matches come back separately
///   ([StickerSearchResults.packs]): title starts before word starts
///   before substrings.
///
/// Ties keep the index order: favourites, recents, then the packs in the
/// library's order.
class StickerSearchIndex {
  StickerSearchIndex(Iterable<StickerItem> items, {this.packs = const []}) {
    for (final item in items) {
      if (_items.containsKey(item.key)) continue;
      _items[item.key] = item;
      _order[item.key] = _order.length;
      _words[item.key] = _wordsOf(item);
      final emoji = item.emoji;
      if (emoji == null) continue;
      for (final single in _splitEmoji(emoji)) {
        (_byEmoji[single] ??= <String>{}).add(item.key);
      }
    }
  }

  final List<StickerPack> packs;
  final _items = <String, StickerItem>{};
  final _order = <String, int>{};
  final _byEmoji = <String, Set<String>>{};

  /// Lower-case words of each item's shortcode and alt text, and the two
  /// texts whole (for substrings).
  final _words = <String, (Set<String>, String)>{};

  /// Keywords of the emoji this index has stickers for, per language.
  final _keywordCache = <String, Map<String, List<String>>>{};

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

  static final _separators = RegExp(r'[\s_\-.:,/]+');

  /// The words a sticker can be found by. A Telegram shortcode is
  /// `<pack>_<keyword>`: the pack's own name is left out (every sticker of
  /// the pack would match it; the pack title search covers it).
  static (Set<String>, String) _wordsOf(StickerItem item) {
    final shortcode = item.shortcode?.toLowerCase() ?? '';
    final body = item.body.toLowerCase();
    final packName = item.bridged?.packUrl
        ?.split('/')
        .where((s) => s.isNotEmpty)
        .lastOrNull
        ?.toLowerCase();
    final words = <String>{
      for (final w in shortcode.split(_separators))
        if (w.isNotEmpty && w != packName) w,
      for (final w in body.split(_separators))
        if (w.isNotEmpty) w,
    };
    final text = packName != null && shortcode.startsWith('${packName}_')
        ? '${shortcode.substring(packName.length + 1)} $body'
        : '$shortcode $body';
    return (words, text);
  }

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

  /// The query as the search sees it: lower case, single spaces, without
  /// the colons of a ":shortcode:".
  static String normalizeQuery(String query) => query
      .trim()
      .toLowerCase()
      .replaceAll(':', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Map<String, List<String>> _emojiKeywords(String languageCode) =>
      _keywordCache.putIfAbsent(languageCode, () {
        final out = <String, List<String>>{};
        for (final (emoji, keywords) in _keywordsFor(languageCode)) {
          if (!_byEmoji.containsKey(emoji)) continue;
          (out[emoji] ??= []).addAll(keywords);
        }
        return out;
      });

  /// Ranks of the match tiers (lower is better).
  static const _exactWord = 0;
  static const _exactKeyword = 1;
  static const _wordPrefix = 2;
  static const _keywordPrefix = 3;
  static const _substring = 4;

  /// The flat list: ranked stickers, then the stickers of matching packs.
  List<StickerItem> search(String query, {String? languageCode}) {
    final results = searchRanked(query, languageCode: languageCode);
    final seen = <String>{};
    final out = <StickerItem>[];
    for (final item in results.stickers) {
      if (seen.add(item.key)) out.add(item);
    }
    for (final pack in results.packs) {
      for (final sticker in pack.stickers) {
        if (out.length >= limit) return out;
        if (seen.add(sticker.key)) out.add(_items[sticker.key] ?? sticker);
      }
    }
    return out;
  }

  StickerSearchResults searchRanked(String query, {String? languageCode}) {
    final raw = query.trim();
    if (raw.isEmpty) return StickerSearchResults.empty;
    if (isEmojiOnly(raw)) return StickerSearchResults(stickers: _byEmojis(raw));
    final text = normalizeQuery(raw);
    if (text.isEmpty) return StickerSearchResults.empty;
    final tokens = text.split(' ');
    final languages = {
      if (languageCode != null && languageCode.isNotEmpty) languageCode,
      'en',
    };

    // Best tier per item, summed over the query's words; an item must
    // match every word.
    Map<String, int>? scores;
    for (final token in tokens) {
      final tier = <String, int>{};
      void hit(String key, int rank) {
        final previous = tier[key];
        if (previous == null || rank < previous) tier[key] = rank;
      }

      if (isEmojiOnly(token)) {
        for (final emoji in _splitEmoji(token)) {
          for (final key in _byEmoji[emoji] ?? const <String>{}) {
            hit(key, _exactWord);
          }
        }
      } else {
        for (final language in languages) {
          for (final MapEntry(key: emoji, value: keywords) in _emojiKeywords(
            language,
          ).entries) {
            int? rank;
            for (final k in keywords) {
              if (k == token) {
                rank = _exactKeyword;
                break;
              }
              if (k.startsWith(token) || k.contains(' $token')) {
                rank = _keywordPrefix;
              }
            }
            if (rank == null) continue;
            for (final key in _byEmoji[emoji]!) {
              hit(key, rank);
            }
          }
        }
        for (final MapEntry(:key, value: (words, whole)) in _words.entries) {
          if (words.contains(token)) {
            hit(key, _exactWord);
          } else if (words.any((w) => w.startsWith(token))) {
            hit(key, _wordPrefix);
          } else if (token.length >= 2 && whole.contains(token)) {
            hit(key, _substring);
          }
        }
      }
      final previous = scores;
      scores = previous == null
          ? tier
          : {
              for (final MapEntry(:key, :value) in previous.entries)
                if (tier[key] case final rank?) key: value + rank,
            };
      if (scores.isEmpty) break;
    }
    final scored = scores!;
    final ranked = scored.keys.toList()
      ..sort((a, b) {
        final byScore = scored[a]!.compareTo(scored[b]!);
        return byScore != 0 ? byScore : _order[a]!.compareTo(_order[b]!);
      });
    return StickerSearchResults(
      stickers: [for (final key in ranked.take(limit)) _items[key]!],
      packs: _packsFor(text, tokens),
    );
  }

  /// Stickers tagged with the emoji of [text], those with more of them
  /// first.
  List<StickerItem> _byEmojis(String text) {
    final singles = _splitEmoji(text).toSet();
    final whole = normalizeEmoji(text);
    final hits = <String, int>{};
    for (final emoji in singles) {
      for (final key in _byEmoji[emoji] ?? const <String>{}) {
        // The whole sequence counts most (a sticker tagged "😂👍").
        hits[key] = (hits[key] ?? 0) + (emoji == whole ? singles.length : 1);
      }
    }
    final ranked = hits.keys.toList()
      ..sort((a, b) {
        final byHits = hits[b]!.compareTo(hits[a]!);
        return byHits != 0 ? byHits : _order[a]!.compareTo(_order[b]!);
      });
    return [for (final key in ranked.take(limit)) _items[key]!];
  }

  List<StickerPack> _packsFor(String text, List<String> tokens) {
    final ranked = <(int, int, StickerPack)>[];
    for (var i = 0; i < packs.length; i++) {
      final pack = packs[i];
      final title = pack.title.toLowerCase();
      if (!tokens.every(title.contains)) continue;
      final words = title.split(_separators);
      final rank = title.startsWith(text)
          ? 0
          : tokens.every((t) => words.any((w) => w.startsWith(t)))
          ? 1
          : 2;
      ranked.add((rank, i, pack));
    }
    ranked.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    return [for (final (_, _, pack) in ranked) pack];
  }
}
