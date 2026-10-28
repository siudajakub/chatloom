// SPDX-License-Identifier: AGPL-3.0-or-later
// The real emoji catalogue behind every picker: search quality on the
// words people type, the shared recents (and their old preference) and
// remembered skin tones. Offline; no account.
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/emoji/emoji_picker.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as data;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() async {
    await AppSettings.store.remove(EmojiRecents.key);
    await AppSettings.store.remove(EmojiSkinTones.key);
    EmojiRecents.debugReset();
    EmojiSkinTones.debugReset();
  });

  List<String> top(String query, [int n = 3]) => [
    for (final e in EmojiCatalog.search.search(query).take(n)) e.emoji,
  ];

  test('the whole set, eight categories, tones where Unicode has them', () {
    final categories = EmojiCatalog.categories;
    expect(categories.map((c) => c.title), [
      'Smileys & people',
      'Animals & nature',
      'Food & drink',
      'Travel & places',
      'Activities',
      'Objects',
      'Symbols',
      'Flags',
    ]);
    final all = [for (final c in categories) ...c.emoji];
    expect(all.length, greaterThan(1500));
    expect(EmojiCatalog.lookup('👍')!.tones, isTrue);
    expect(EmojiCatalog.lookup('❤')!.tones, isFalse);
    // One search entry per emoji identity (spellings and tones fold).
    expect(EmojiCatalog.search.length, greaterThan(all.length - 30));
  });

  test('search finds what people type, best first', () {
    expect(top('heart').first, '❤️');
    expect(top('lol').first, '😂');
    expect(top('thumbs').first, '👍');
    expect(top('thumbs up').first, '👍');
    expect(top('fire').first, '🔥');
    expect(top('ok').first, '👌');
    expect(top('party').first, '🎉');
    expect(top('party', 2), contains('🥳'));
    expect(top('cry').toSet(), containsAll(['😭', '😢']));
    expect(top('sad', 5), contains('😭'));
    expect(top('<3').first, '❤️');
    expect(top('Thumbs UP').first, '👍');
    expect(top('café').first, '☕');
    expect(top(':joy:').first, '😂');
    expect(top('👍\u{FE0F}').first, '👍');
    expect(top('zzqx'), isEmpty);
    // Prefix: "pizz" → 🍕; substring still found at the end.
    expect(top('pizz').first, '🍕');
  });

  test('search is instant on the whole set', () {
    EmojiCatalog.search.search('warm-up');
    final watch = Stopwatch()..start();
    for (final q in ['h', 'he', 'hea', 'hear', 'heart', 'a b', 'smile']) {
      EmojiCatalog.search.search(q);
    }
    // Seven keystrokes well under one frame each, even in debug mode.
    expect(watch.elapsedMilliseconds, lessThan(7 * 16 * 4));
  });

  test('recents: newest first, counted, in the old preference format', () {
    // A list written by emoji_picker_flutter before wave 11 carries over.
    AppSettings.store.setString(
      EmojiRecents.key,
      jsonEncode([
        {
          'emoji': {'emoji': '🔥', 'name': 'fire', 'hasSkinTone': false},
          'counter': 4,
        },
      ]),
    );
    EmojiRecents.debugReset();
    expect(EmojiRecents.emoji, ['🔥']);
    EmojiRecents.add('😂');
    EmojiRecents.add('🔥');
    expect(EmojiRecents.emoji, ['🔥', '😂']);
    expect(EmojiRecents.usage, {'🔥': 5, '😂': 1});
    final stored = jsonDecode(AppSettings.store.getString(EmojiRecents.key)!);
    expect((stored as List).first['emoji']['emoji'], '🔥');
    for (var i = 0; i < 40; i++) {
      EmojiRecents.add(String.fromCharCode(0x1F400 + i));
    }
    expect(EmojiRecents.emoji, hasLength(EmojiRecents.limit));
    EmojiRecents.add('mxc://example.invalid/x');
    expect(EmojiRecents.emoji, isNot(contains('mxc://example.invalid/x')));
  });

  test('skin tones are remembered per emoji', () {
    EmojiSkinTones.remember('👍', '🏽');
    EmojiSkinTones.debugReset();
    expect(EmojiSkinTones.all, {NotionEmojiSearch.key('👍'): '🏽'});
    EmojiSkinTones.remember('👍🏽', null);
    expect(EmojiSkinTones.all, isEmpty);
  });

  testWidgets('a pick is recent everywhere; tones show in the grid', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 640);
    addTearDown(tester.view.reset);
    EmojiSkinTones.remember('👋', '🏾');
    final picked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(body: ChatLoomEmojiPicker(onSelected: picked.add)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recently used'), findsNothing);
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pump();
    expect(picked, ['😂']);
    expect(EmojiRecents.emoji.first, '😂');
    // Stored in emoji_picker_flutter's own format and key.
    final stored = jsonDecode(AppSettings.store.getString(EmojiRecents.key)!);
    expect(data.RecentEmoji.fromJson((stored as List).first).emoji.emoji, '😂');
    // The reaction picker of a fixed network set opens with it on top.
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: ChatLoomEmojiPicker(
            reactions: const EmojiReactionChoices(
              allowed: ['👍\u{FE0F}', '😂', '🔥'],
              quick: ['👍'],
              own: {'🔥'},
            ),
            onSelected: picked.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Quick reactions'), findsOneWidget);
    expect(find.text('Recently used'), findsOneWidget);
    expect(find.text('Reactions in this chat'), findsOneWidget);
    // No category bar for a short fixed set; no skin tones.
    expect(find.byKey(const ValueKey('emoji-category-allowed')), findsNothing);
    await tester.tap(find.bySemanticsLabel('👍\u{FE0F}').first);
    await tester.pump();
    expect(picked.last, '👍\u{FE0F}');
  });
}
