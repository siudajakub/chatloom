// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as data;
import 'package:material_ui/material_ui.dart';

/// The emoji of every ChatLoom picker (composer, reactions, settings).
///
/// Data: emoji_picker_flutter's English set (Unicode 15, CLDR keywords,
/// skin-tone flags, categories), already a dependency for the composer's
/// `:emoji` suggestions; no second copy of 1,600 emoji ships. Its keywords
/// are complete but name-less, so [aliases] adds the CLDR short names of
/// the common emoji and the words people type ("lol", "thumbs", "ok",
/// "party", "<3"), and [popular] (Unicode's emoji frequency ranking) breaks
/// ties: "heart" finds ❤️ first, "cry" 😭 and 😢 before 😿.
abstract final class EmojiCatalog {
  static List<NotionEmojiSection>? _categories;
  static NotionEmojiSearch? _search;
  static bool _filtering = false;

  /// Category titles and icons, in the picker's order.
  static const _categoryInfo = {
    data.Category.SMILEYS: ('Smileys & people', Icons.emoji_emotions_outlined),
    data.Category.ANIMALS: ('Animals & nature', Icons.pets_outlined),
    data.Category.FOODS: ('Food & drink', Icons.fastfood_outlined),
    data.Category.TRAVEL: ('Travel & places', Icons.directions_car_outlined),
    data.Category.ACTIVITIES: ('Activities', Icons.sports_soccer_outlined),
    data.Category.OBJECTS: ('Objects', Icons.lightbulb_outline),
    data.Category.SYMBOLS: ('Symbols', Icons.emoji_symbols_outlined),
    data.Category.FLAGS: ('Flags', Icons.flag_outlined),
  };

  /// The categories (Smileys & people … Flags).
  static List<NotionEmojiSection> get categories {
    final cached = _categories;
    if (cached != null) return cached;
    _filterUnsupported();
    return _categories = _build(data.emojiSetEnglish);
  }

  /// Search over every emoji of [categories].
  static NotionEmojiSearch get search => _search ??= NotionEmojiSearch(
    [for (final section in categories) ...section.emoji],
    aliases: aliases,
    popular: popular,
  );

  /// The catalogue's entry for [glyph] (any spelling or tone), or null.
  static NotionEmoji? lookup(String glyph) => search.lookup(glyph);

  static List<NotionEmojiSection> _build(List<data.CategoryEmoji> set) => [
    for (final category in set)
      if (_categoryInfo[category.category] case final info?)
        NotionEmojiSection(
          id: category.category.name.toLowerCase(),
          title: info.$1,
          icon: info.$2,
          emoji: List.unmodifiable([
            for (final emoji in category.emoji)
              NotionEmoji(
                emoji.emoji,
                keywords: emoji.keywords,
                tones: emoji.hasSkinTone,
              ),
          ]),
        ),
  ];

  /// Android: drop glyphs the system font cannot draw (an older Android
  /// shows newer emoji as boxes). Once, in the background; the next picker
  /// that opens uses the filtered set. Elsewhere every glyph renders.
  static void _filterUnsupported() {
    if (_filtering) return;
    _filtering = true;
    unawaited(
      data.EmojiPickerUtils()
          .filterUnsupported(data.emojiSetEnglish)
          .then((supported) {
            final before = [
              for (final s in _categories ?? const []) s.emoji.length,
            ];
            final after = [for (final c in supported) c.emoji.length];
            if (before.toString() == after.toString()) return;
            _categories = _build(supported);
            _search = null;
          })
          .catchError((Object _) {}),
    );
  }

  @visibleForTesting
  static void debugReset() {
    _categories = null;
    _search = null;
    _filtering = false;
  }

  /// CLDR short names of common emoji and the words people type for them.
  static const Map<String, List<String>> aliases = {
    '😀': ['grinning face'],
    '😃': ['grinning face with big eyes'],
    '😄': ['grinning face with smiling eyes'],
    '😁': ['beaming face', 'grin'],
    '😆': ['xd', 'squinting face'],
    '😅': ['sweat smile', 'phew'],
    '🤣': ['rolling on the floor laughing', 'rofl', 'lol'],
    '😂': ['face with tears of joy', 'lol', 'joy'],
    '🙂': ['slightly smiling face', 'smile'],
    '🙃': ['upside down face', 'sarcasm'],
    '😉': ['winking face', 'wink'],
    '😊': ['smiling face with smiling eyes', 'smile', 'happy'],
    '😇': ['smiling face with halo', 'angel'],
    '🥰': ['smiling face with hearts', 'love', 'adore'],
    '😍': ['heart eyes', 'love'],
    '🤩': ['star struck', 'wow', 'amazing'],
    '😘': ['face blowing a kiss', 'kiss'],
    '😋': ['yum', 'delicious'],
    '😛': ['tongue', 'face with tongue'],
    '😜': ['winking face with tongue', 'crazy'],
    '🤪': ['zany face', 'crazy', 'silly'],
    '🤗': ['hugging face', 'hug', 'hugs'],
    '🤭': ['oops', 'giggle'],
    '🤫': ['shush', 'quiet', 'secret'],
    '🤔': ['thinking face', 'think', 'hmm'],
    '🤐': ['zipper mouth', 'secret'],
    '🤨': ['raised eyebrow', 'skeptical', 'sus'],
    '😐': ['neutral face', 'meh'],
    '😑': ['expressionless', 'meh'],
    '😶': ['speechless', 'no words'],
    '😏': ['smirk', 'smirking face'],
    '😒': ['unamused', 'meh'],
    '🙄': ['face with rolling eyes', 'eyeroll', 'eye roll'],
    '😬': ['grimacing face', 'cringe', 'awkward', 'yikes'],
    '😌': ['relieved', 'calm'],
    '😔': ['pensive', 'sad'],
    '😪': ['sleepy', 'tired'],
    '😴': ['sleeping face', 'sleep', 'zzz', 'tired'],
    '😷': ['mask', 'sick', 'ill'],
    '🤒': ['thermometer', 'sick', 'ill', 'fever'],
    '🤢': ['nauseated', 'sick', 'gross'],
    '🤮': ['vomit', 'puke', 'sick', 'gross'],
    '🥵': ['hot face', 'hot', 'sweating'],
    '🥶': ['cold face', 'cold', 'freezing'],
    '🤯': ['mind blown', 'exploding head', 'wow', 'omg'],
    '🥳': ['partying face', 'party', 'celebrate', 'congrats', 'birthday'],
    '😎': ['cool', 'sunglasses'],
    '🤓': ['nerd', 'geek'],
    '😕': ['confused'],
    '😟': ['worried'],
    '🙁': ['frown', 'sad'],
    '☹️': ['frowning face', 'sad'],
    '😮': ['open mouth', 'wow', 'surprised', 'omg'],
    '😲': ['astonished', 'wow', 'shocked', 'omg'],
    '😳': ['flushed', 'embarrassed', 'blush'],
    '🥺': ['pleading face', 'puppy eyes', 'please'],
    '🥹': ['holding back tears', 'touched', 'grateful'],
    '😨': ['fearful', 'scared'],
    '😰': ['anxious', 'nervous'],
    '😥': ['sad but relieved', 'disappointed'],
    '😢': ['crying face', 'cry', 'sad', 'tear'],
    '😭': ['loudly crying face', 'cry', 'sob', 'sad'],
    '😱': ['screaming', 'scream', 'shock', 'omg', 'scared'],
    '😖': ['confounded'],
    '😣': ['persevering'],
    '😞': ['disappointed', 'sad'],
    '😓': ['downcast', 'sweat'],
    '😩': ['weary', 'tired', 'ugh'],
    '😫': ['tired face', 'tired', 'ugh'],
    '🥱': ['yawning', 'yawn', 'bored', 'tired'],
    '😤': ['huffing', 'triumph', 'angry', 'mad'],
    '😡': ['pouting face', 'angry', 'mad', 'rage'],
    '😠': ['angry face', 'angry', 'mad'],
    '🤬': ['cursing', 'swearing', 'angry', 'mad', 'rage'],
    '😈': ['devil', 'smiling face with horns', 'evil'],
    '💀': ['skull', 'dead', 'lmao', 'dying'],
    '💩': ['poop', 'shit', 'pile of poo'],
    '🤡': ['clown'],
    '👻': ['ghost', 'boo'],
    '👽': ['alien'],
    '🤖': ['robot', 'bot'],
    '🙈': ['see no evil', 'monkey', 'oops'],
    '🙉': ['hear no evil', 'monkey'],
    '🙊': ['speak no evil', 'monkey', 'oops'],
    '💋': ['kiss', 'lips'],
    '💯': ['hundred', '100', 'perfect', 'keep it 100'],
    '💥': ['boom', 'collision', 'explosion'],
    '💫': ['dizzy'],
    '💦': ['sweat droplets', 'water', 'splash'],
    '💤': ['zzz', 'sleep'],
    '👋': ['waving hand', 'wave', 'hi', 'hello', 'bye'],
    '🤚': ['raised back of hand'],
    '✋': ['raised hand', 'stop', 'high five'],
    '👌': ['ok hand', 'ok', 'okay', 'perfect'],
    '🤌': ['pinched fingers', 'italian'],
    '✌️': ['victory', 'peace'],
    '🤞': ['crossed fingers', 'luck', 'hope'],
    '🤟': ['love you gesture', 'ily'],
    '🤘': ['rock on', 'horns', 'metal'],
    '🤙': ['call me', 'shaka'],
    '👈': ['point left'],
    '👉': ['point right'],
    '👆': ['point up'],
    '👇': ['point down'],
    '☝️': ['index pointing up', 'one'],
    '👍': ['thumbs up', 'thumbsup', 'like', 'yes', 'good', 'agree'],
    '👎': ['thumbs down', 'thumbsdown', 'dislike', 'no', 'bad', '-1'],
    '✊': ['raised fist', 'fist'],
    '👊': ['oncoming fist', 'fist bump', 'punch'],
    '👏': ['clapping hands', 'clap', 'applause', 'bravo'],
    '🙌': ['raising hands', 'hooray', 'yay', 'praise'],
    '🫶': ['heart hands', 'love'],
    '👐': ['open hands'],
    '🤲': ['palms up together'],
    '🤝': ['handshake', 'deal', 'agree'],
    '🙏': ['folded hands', 'pray', 'please', 'thanks', 'thank you'],
    '✍️': ['writing hand', 'write'],
    '💅': ['nail polish', 'sassy'],
    '💪': ['flexed biceps', 'muscle', 'strong', 'gym'],
    '👀': ['eyes', 'look', 'see', 'watching'],
    '👁️': ['eye'],
    '🧠': ['brain', 'smart'],
    '🫡': ['saluting face', 'salute', 'yes sir'],
    '🤷': ['shrug', 'idk', 'dunno'],
    '🤦': ['facepalm', 'face palm'],
    '🙋': ['raising hand', 'me', 'question'],
    '🙅': ['no', 'nope'],
    '🙆': ['yes'],
    '💃': ['dancing', 'dance'],
    '🕺': ['dancing', 'dance'],
    '👑': ['crown', 'king', 'queen'],
    '❤️': ['red heart', 'heart', 'love', '<3'],
    '🧡': ['orange heart'],
    '💛': ['yellow heart'],
    '💚': ['green heart'],
    '💙': ['blue heart'],
    '💜': ['purple heart'],
    '🖤': ['black heart'],
    '🤍': ['white heart'],
    '🤎': ['brown heart'],
    '💔': ['broken heart', 'heartbreak', '</3'],
    '❤️‍🔥': ['heart on fire', 'burning heart'],
    '❤️‍🩹': ['mending heart', 'healing'],
    '💕': ['two hearts', 'love'],
    '💞': ['revolving hearts'],
    '💓': ['beating heart'],
    '💗': ['growing heart'],
    '💖': ['sparkling heart'],
    '💘': ['heart with arrow', 'cupid'],
    '💝': ['heart with ribbon'],
    '♥️': ['heart suit', 'heart'],
    '🔥': ['fire', 'lit', 'hot', 'flame'],
    '✨': ['sparkles', 'magic', 'shiny'],
    '⭐': ['star'],
    '🌟': ['glowing star', 'star'],
    '⚡': ['high voltage', 'lightning', 'zap', 'fast'],
    '☀️': ['sun', 'sunny'],
    '🌈': ['rainbow', 'pride'],
    '🎉': ['party popper', 'party', 'tada', 'congrats', 'celebrate'],
    '🎊': ['confetti ball', 'party', 'congrats'],
    '🎂': ['birthday cake', 'birthday', 'cake'],
    '🎁': ['wrapped gift', 'gift', 'present'],
    '🎈': ['balloon', 'party'],
    '🏆': ['trophy', 'win', 'winner'],
    '🥇': ['gold medal', 'first', 'winner'],
    '✅': ['check mark button', 'check', 'done', 'yes'],
    '✔️': ['check mark', 'check', 'done'],
    '❌': ['cross mark', 'x', 'no', 'wrong'],
    '❗': ['exclamation', 'important'],
    '❓': ['question', 'what'],
    '⚠️': ['warning', 'careful'],
    '🚀': ['rocket', 'launch', 'ship it'],
    '🍻': ['clinking beer mugs', 'cheers', 'beer'],
    '🥂': ['clinking glasses', 'cheers', 'toast'],
    '🍺': ['beer'],
    '☕': ['coffee', 'hot beverage', 'tea'],
    '🍕': ['pizza'],
    '🌹': ['rose', 'flower'],
    '🌸': ['cherry blossom', 'flower'],
    '💐': ['bouquet', 'flowers'],
    '🐶': ['dog', 'puppy'],
    '🐱': ['cat', 'kitty'],
    '🦄': ['unicorn'],
    '🐳': ['whale'],
    '🕊️': ['dove', 'peace'],
    '🍌': ['banana'],
    '🍓': ['strawberry'],
    '🌭': ['hot dog'],
    '🍾': ['champagne', 'celebrate'],
    '🗿': ['moai', 'stone face'],
    '🆒': ['cool'],
    '🆗': ['ok', 'okay'],
    '💊': ['pill'],
    '👾': ['alien monster', 'game'],
    '🎃': ['jack o lantern', 'halloween', 'pumpkin'],
    '🎄': ['christmas tree', 'christmas'],
    '🎅': ['santa', 'christmas'],
    '☃️': ['snowman'],
    '🌚': ['new moon face'],
    '🖕': ['middle finger'],
    '👨‍💻': ['man technologist', 'coder', 'developer'],
    '🤷‍♂️': ['man shrugging', 'shrug'],
    '🤷‍♀️': ['woman shrugging', 'shrug'],
    '💸': ['money with wings', 'money'],
    '💰': ['money bag', 'money', 'rich'],
    '🤑': ['money mouth', 'money', 'rich'],
    '📌': ['pin', 'pushpin'],
    '📍': ['location', 'pin'],
    '🔔': ['bell', 'notification'],
    '🎶': ['music', 'notes'],
    '📷': ['camera', 'photo'],
    '💬': ['speech balloon', 'chat', 'comment'],
  };

  /// Unicode's emoji frequency ranking (most used first), for ties.
  static const List<String> popular = [
    '😂', '❤️', '🤣', '👍', '😭', '🙏', '😘', '🥰', '😍', '😊', //
    '🎉', '😁', '💕', '🥺', '😅', '🔥', '☺️', '🤦', '♥️', '🤷', //
    '🙄', '😆', '🤗', '😉', '🎂', '🤔', '👏', '🙂', '😳', '🥳', //
    '😎', '👌', '💜', '😔', '💪', '✨', '💖', '👀', '😋', '😏', //
    '😢', '👉', '💗', '😩', '💯', '🌹', '💞', '🎈', '💙', '😃', //
    '😡', '💐', '😜', '🙈', '🤞', '😄', '🤤', '🙌', '🤪', '❣️', //
    '😀', '💋', '💀', '👇', '💔', '😌', '💓', '🤩', '🙃', '😬', //
    '😱', '😴', '🤭', '😐', '🌞', '😒', '😇', '🌸', '😈', '🎶', //
    '✌️', '🎊', '🥵', '😞', '💚', '☀️', '🖤', '💰', '😚', '👑', //
    '🎁', '💥', '🙋', '☹️', '😑', '🥴', '👈', '💩', '✅', '👋', //
    '🤮', '😤', '🤢', '🌟', '❗', '😥', '🌈', '💛', '😝', '😫', //
    '😲', '🖕', '‼️', '🔴', '🌻', '🤯', '💃', '👊', '🤬', '🏃', //
    '😕', '👁️', '⚡', '☕', '🍀', '💦', '⭐', '🦋', '🤨', '🌺', //
    '😹', '🤘', '🌷', '💝', '💤', '🤝', '🐰', '😓', '💘', '🍻', //
    '😟', '😣', '🧐', '😠', '🤠', '😻', '🌙', '😛', '🤙', '🙊', //
  ];
}

/// Recently used emoji, shared by every picker (Telegram's "Recently
/// used"): newest first, with a use count that ranks search results. Kept
/// in emoji_picker_flutter's preference (`recent`, same JSON), so the
/// recents of earlier versions carry over.
abstract final class EmojiRecents {
  static const key = 'recent';
  static const limit = 32;
  static List<({String emoji, int count})>? _cache;

  static List<({String emoji, int count})> _load() {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <({String emoji, int count})>[];
    try {
      final raw = AppSettings.store.getString(key);
      final list = raw == null ? null : jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          final emoji = item is Map ? item['emoji'] : null;
          final glyph = emoji is Map ? emoji['emoji'] : null;
          final count = item is Map ? item['counter'] : null;
          if (glyph is String && glyph.isNotEmpty) {
            out.add((emoji: glyph, count: count is int ? count : 1));
          }
        }
      }
    } catch (_) {
      // Preferences not ready (tests, early start) or unreadable.
    }
    return _cache = out;
  }

  /// Newest first.
  static List<String> get emoji => [for (final e in _load()) e.emoji];

  /// Use counts by emoji.
  static Map<String, int> get usage => {
    for (final e in _load()) e.emoji: e.count,
  };

  /// Whether at least one emoji was used.
  static bool get any => _load().isNotEmpty;

  /// Moves [glyph] to the front and counts the use.
  static void add(String glyph) {
    if (glyph.isEmpty || glyph.startsWith('mxc://')) return;
    final list = [..._load()];
    final at = list.indexWhere((e) => e.emoji == glyph);
    final count = at < 0 ? 1 : list[at].count + 1;
    if (at >= 0) list.removeAt(at);
    list.insert(0, (emoji: glyph, count: count));
    _cache = list.take(limit).toList();
    try {
      unawaited(
        AppSettings.store.setString(
          key,
          jsonEncode([
            for (final e in _cache!)
              {
                'emoji': {
                  'emoji': e.emoji,
                  'name': '',
                  'hasSkinTone': NotionEmojiTones.of(e.emoji) != null,
                },
                'counter': e.count,
              },
          ]),
        ),
      );
    } catch (_) {
      // Memory only.
    }
  }

  @visibleForTesting
  static void debugReset() => _cache = null;
}

/// The skin tone the user chose for each emoji (Telegram remembers it per
/// emoji), keyed by [NotionEmojiSearch.key].
abstract final class EmojiSkinTones {
  static const key = 'pl.personal.emoji.skin_tones';
  static Map<String, String>? _cache;

  static Map<String, String> get all {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, String>{};
    try {
      final raw = AppSettings.store.getString(key);
      final map = raw == null ? null : jsonDecode(raw);
      if (map is Map) {
        for (final entry in map.entries) {
          if (entry.key is String &&
              NotionEmojiTones.all.contains(entry.value)) {
            out[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {
      // Preferences not ready or unreadable.
    }
    return _cache = out;
  }

  /// Remembers [tone] for [emoji] (null: back to the untoned one).
  static void remember(String emoji, String? tone) {
    final next = {...all};
    final k = NotionEmojiSearch.key(emoji);
    if (tone == null) {
      next.remove(k);
    } else {
      next[k] = tone;
    }
    _cache = Map.unmodifiable(next);
    try {
      unawaited(AppSettings.store.setString(key, jsonEncode(next)));
    } catch (_) {
      // Memory only.
    }
  }

  @visibleForTesting
  static void debugReset() => _cache = null;
}
