// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

/// One emoji of a picker: the glyph, its search words and whether it takes
/// a skin tone. Data only; the catalogue (names, categories) is the app's.
@immutable
class NotionEmoji {
  const NotionEmoji(this.emoji, {this.keywords = const [], this.tones = false});

  /// The glyph as it is inserted or sent.
  final String emoji;

  /// Words a search matches (CLDR keywords plus aliases), any case.
  final List<String> keywords;

  /// Takes a skin tone ([NotionEmojiTones]); long-press offers them.
  final bool tones;

  @override
  bool operator ==(Object other) =>
      other is NotionEmoji && other.emoji == emoji && other.tones == tones;

  @override
  int get hashCode => Object.hash(emoji, tones);

  @override
  String toString() => 'NotionEmoji($emoji)';
}

/// Fitzpatrick skin tones (Unicode Emoji_Modifier) and how a tone is put on
/// or taken off an emoji.
abstract final class NotionEmojiTones {
  /// Light, medium-light, medium, medium-dark, dark.
  static const List<String> all = [
    '\u{1F3FB}',
    '\u{1F3FC}',
    '\u{1F3FD}',
    '\u{1F3FE}',
    '\u{1F3FF}',
  ];

  static const int _vs16 = 0xFE0F;
  static const int _zwj = 0x200D;

  /// Bases whose untoned form needs U+FE0F to show as an emoji (✌️, ☝️).
  static const Set<int> _textBases = {
    0x261D,
    0x26F9,
    0x270C,
    0x270D,
    0x1F3CB,
    0x1F3CC,
    0x1F574,
    0x1F575,
    0x1F590,
  };

  static bool _isTone(int rune) => rune >= 0x1F3FB && rune <= 0x1F3FF;

  /// The tone in [emoji], or null.
  static String? of(String emoji) {
    for (final rune in emoji.runes) {
      if (_isTone(rune)) return String.fromCharCode(rune);
    }
    return null;
  }

  /// [emoji] without a skin tone (the selector of a text base restored).
  static String strip(String emoji) {
    final runes = [
      for (final rune in emoji.runes)
        if (!_isTone(rune)) rune,
    ];
    if (runes.isEmpty) return emoji;
    if (_textBases.contains(runes.first) &&
        (runes.length == 1 || runes[1] != _vs16)) {
      runes.insert(1, _vs16);
    }
    return String.fromCharCodes(runes);
  }

  /// [emoji] in [tone] (null: no tone). The modifier follows the base code
  /// point and replaces its presentation selector (✌️ + 🏽 = ✌🏽); a ZWJ
  /// sequence keeps its rest (🤷🏽‍♂️).
  static String apply(String emoji, String? tone) {
    final base = strip(emoji);
    if (tone == null) return base;
    final runes = base.runes.toList();
    if (runes.isEmpty) return emoji;
    final rest = runes.length > 1 && runes[1] == _vs16 ? 2 : 1;
    return String.fromCharCodes([
      runes.first,
      ...tone.runes,
      ...runes.skip(rest),
    ]);
  }

  /// Whether [emoji] is a ZWJ sequence (several people or a profession).
  static bool isSequence(String emoji) => emoji.runes.contains(_zwj);
}

/// Instant, on-device emoji search (Telegram, Slack): every query word
/// must match one of an emoji's words, an exact word ranks over a prefix,
/// a prefix over a substring; ties go to what the user uses most, then to
/// what people use most ([popular]), then to the catalogue order. Case and
/// diacritics are ignored, `:shortcodes:` lose their colons, and a pasted
/// emoji finds itself (any spelling, any skin tone).
class NotionEmojiSearch {
  NotionEmojiSearch(
    Iterable<NotionEmoji> emoji, {
    Map<String, List<String>> aliases = const {},
    List<String> popular = const [],
  }) {
    final aliasByKey = <String, List<String>>{
      for (final entry in aliases.entries) key(entry.key): entry.value,
    };
    final rank = <String, int>{};
    for (final (index, glyph) in popular.indexed) {
      rank.putIfAbsent(key(glyph), () => index);
    }
    for (final item in emoji) {
      final k = key(item.emoji);
      if (_byKey.containsKey(k)) continue;
      final terms = <String>{
        for (final word in item.keywords)
          if (fold(word).isNotEmpty) fold(word),
        for (final word in aliasByKey[k] ?? const <String>[])
          if (fold(word).isNotEmpty) fold(word),
      }.toList(growable: false);
      final entry = _Entry(item, terms, rank[k], _entries.length);
      _entries.add(entry);
      _byKey[k] = entry;
    }
  }

  final _entries = <_Entry>[];
  final _byKey = <String, _Entry>{};

  /// Number of distinct emoji indexed.
  int get length => _entries.length;

  /// The indexed emoji for [glyph] in any spelling or tone, or null.
  NotionEmoji? lookup(String glyph) => _byKey[key(glyph)]?.emoji;

  /// An emoji's identity: no variation selectors, no skin tone.
  static String key(String emoji) => NotionEmojiTones.strip(
    emoji,
  ).replaceAll('\u{FE0F}', '').replaceAll('\u{FE0E}', '');

  /// [text] for matching: lower case, Latin diacritics folded (é → e,
  /// ł → l, ß → ss), curly quotes straightened, one space between words.
  static String fold(String text) {
    final out = StringBuffer();
    var space = false;
    for (final rune in text.toLowerCase().runes) {
      final folded = _fold[rune];
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A) {
        space = out.isNotEmpty;
        continue;
      }
      if (space) {
        out.write(' ');
        space = false;
      }
      if (folded != null) {
        out.write(folded);
      } else if (rune >= 0x300 && rune <= 0x36F) {
        // A combining accent (decomposed input): dropped.
        continue;
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Results for [query], best first, at most [limit]. [usage] counts how
  /// often the user picked each emoji (any spelling); more ranks higher
  /// among equally good matches.
  List<NotionEmoji> search(
    String query, {
    Map<String, int> usage = const {},
    int limit = 240,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final usageByKey = <String, int>{};
    for (final entry in usage.entries) {
      final k = key(entry.key);
      usageByKey[k] = (usageByKey[k] ?? 0) + entry.value;
    }

    // A pasted emoji (or several) finds itself first.
    final pasted = <_Entry>[];
    final words = StringBuffer();
    for (final cluster in trimmed.characters) {
      final entry = _byKey[key(cluster)];
      if (entry != null && !pasted.contains(entry)) {
        pasted.add(entry);
      } else {
        words.write(cluster);
      }
    }
    var text = fold(words.toString());
    // `:joy:` and `:thumbs_up:` style shortcodes.
    text = text.replaceAll(':', ' ').replaceAll('_', ' ').trim();
    final parts = text
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    final scored = <(_Entry, int)>[];
    if (parts.isNotEmpty) {
      for (final entry in _entries) {
        final score = entry.score(parts, text);
        if (score > 0) scored.add((entry, score));
      }
      scored.sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        if (byScore != 0) return byScore;
        final byUse = (usageByKey[b.$1.key] ?? 0).compareTo(
          usageByKey[a.$1.key] ?? 0,
        );
        if (byUse != 0) return byUse;
        final ra = a.$1.popularity, rb = b.$1.popularity;
        if (ra != rb) {
          if (ra == null) return 1;
          if (rb == null) return -1;
          return ra.compareTo(rb);
        }
        return a.$1.order.compareTo(b.$1.order);
      });
    }
    return [
      for (final entry in pasted) entry.emoji,
      for (final (entry, _) in scored)
        if (!pasted.contains(entry)) entry.emoji,
    ].take(limit).toList(growable: false);
  }

  static const Map<int, String> _fold = {
    0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a', //
    0x101: 'a', 0x103: 'a', 0x105: 'a', 0xE6: 'ae', //
    0xE7: 'c', 0x107: 'c', 0x109: 'c', 0x10B: 'c', 0x10D: 'c', //
    0x10F: 'd', 0x111: 'd', 0xF0: 'd', //
    0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e', 0x113: 'e', 0x115: 'e', //
    0x117: 'e', 0x119: 'e', 0x11B: 'e', //
    0x11D: 'g', 0x11F: 'g', 0x121: 'g', 0x123: 'g', 0x125: 'h', 0x127: 'h',
    0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i', 0x129: 'i', 0x12B: 'i', //
    0x12D: 'i', 0x12F: 'i', 0x131: 'i', 0x135: 'j', 0x137: 'k', //
    0x13A: 'l', 0x13C: 'l', 0x13E: 'l', 0x140: 'l', 0x142: 'l', //
    0xF1: 'n', 0x144: 'n', 0x146: 'n', 0x148: 'n', //
    0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o', //
    0x14D: 'o', 0x14F: 'o', 0x151: 'o', 0x153: 'oe', //
    0x155: 'r', 0x157: 'r', 0x159: 'r', //
    0x15B: 's', 0x15D: 's', 0x15F: 's', 0x161: 's', 0x219: 's', 0xDF: 'ss',
    0x163: 't', 0x165: 't', 0x167: 't', 0x21B: 't', 0xFE: 'th', //
    0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u', 0x169: 'u', 0x16B: 'u', //
    0x16D: 'u', 0x16F: 'u', 0x171: 'u', 0x173: 'u', 0x175: 'w', //
    0xFD: 'y', 0xFF: 'y', 0x177: 'y', 0x17A: 'z', 0x17C: 'z', 0x17E: 'z',
    0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"', //
  };
}

class _Entry {
  _Entry(this.emoji, this.terms, this.popularity, this.order)
    : key = NotionEmojiSearch.key(emoji.emoji);

  final NotionEmoji emoji;
  final String key;

  /// Folded words and phrases ("thumbs up").
  final List<String> terms;
  final int? popularity;
  final int order;

  /// 0 when a word does not match; otherwise exact 3, prefix 2, substring
  /// 1 per word, plus 2 when a whole phrase is one of the terms.
  int score(List<String> words, String phrase) {
    var total = 0;
    for (final word in words) {
      var best = 0;
      for (final term in terms) {
        final match = _match(term, word);
        if (match > best) best = match;
        if (best == 3) break;
      }
      if (best == 0) return 0;
      total += best;
    }
    if (words.length > 1 && terms.contains(phrase)) total += 2;
    return total;
  }

  static int _match(String term, String word) {
    if (term == word) return 3;
    // A word of a phrase ("thumbs" in "thumbs up") counts as a word.
    final parts = term.contains(' ') ? term.split(' ') : const <String>[];
    if (parts.contains(word)) return 3;
    if (term.startsWith(word) || parts.any((p) => p.startsWith(word))) {
      return 2;
    }
    // Substrings only from two letters; they rank last ("ok" in "smoking").
    if (word.length >= 2 && term.contains(word)) return 1;
    return 0;
  }
}
