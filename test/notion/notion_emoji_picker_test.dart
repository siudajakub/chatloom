// SPDX-License-Identifier: AGPL-3.0-or-later
// The emoji picker primitive (DESIGN.md "Emoji picker"): ranked search,
// skin tones, the category bar, sticky headers, selection, small screens,
// reduced motion and goldens. Fictional data; emoji glyphs render as the
// test font's boxes.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _people = [
  NotionEmoji('😀', keywords: ['face', 'grin', 'grinning', 'smile']),
  NotionEmoji('😂', keywords: ['face', 'joy', 'laugh', 'lol', 'tear']),
  NotionEmoji('😢', keywords: ['cry', 'face', 'sad', 'tear']),
  NotionEmoji('😭', keywords: ['cry', 'face', 'sad', 'sob']),
  NotionEmoji('👍', keywords: ['+1', 'thumb', 'up', 'yes'], tones: true),
  NotionEmoji('👋', keywords: ['hand', 'wave', 'hello'], tones: true),
  NotionEmoji('✌️', keywords: ['peace', 'victory'], tones: true),
];

const _symbols = [
  NotionEmoji('❤️', keywords: ['heart', 'love', 'red']),
  NotionEmoji('💔', keywords: ['break', 'broken', 'heart']),
  NotionEmoji('🔥', keywords: ['fire', 'flame', 'lit']),
  NotionEmoji('☕', keywords: ['café', 'coffee', 'drink']),
  NotionEmoji('🚬', keywords: ['smoking']),
];

/// Distinct glyphs (animals block) so sections are long enough to scroll.
List<NotionEmoji> _filler(int start, int count, String word) => [
  for (var i = 0; i < count; i++)
    NotionEmoji(String.fromCharCode(start + i), keywords: ['$word$i']),
];

List<NotionEmojiSection> _sections() => [
  const NotionEmojiSection(
    id: 'people',
    title: 'Smileys & people',
    icon: Icons.emoji_emotions_outlined,
    emoji: _people,
  ),
  NotionEmojiSection(
    id: 'animals',
    title: 'Animals & nature',
    icon: Icons.pets_outlined,
    emoji: _filler(0x1F400, 60, 'animal'),
  ),
  NotionEmojiSection(
    id: 'food',
    title: 'Food & drink',
    icon: Icons.fastfood_outlined,
    emoji: _filler(0x1F345, 50, 'food'),
  ),
  const NotionEmojiSection(
    id: 'symbols',
    title: 'Symbols',
    icon: Icons.emoji_symbols_outlined,
    emoji: _symbols,
  ),
  NotionEmojiSection(
    id: 'flags',
    title: 'Flags',
    icon: Icons.flag_outlined,
    emoji: _filler(0x1F600, 80, 'flag'),
  ),
];

/// A phone: 390 × 600 logical pixels.
void _phone(WidgetTester tester, [Size size = const Size(390, 600)]) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

NotionEmojiSearch _search() => NotionEmojiSearch(
  [for (final s in _sections()) ...s.emoji],
  aliases: const {
    '❤️': ['red heart', '<3'],
    '👍': ['thumbs up', 'like'],
  },
  popular: const ['😂', '❤️', '😭', '👍', '🔥', '😢'],
);

Widget _app(
  Widget child, {
  Size size = const Size(390, 600),
  bool reduced = false,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(brightness),
  home: MediaQuery(
    data: MediaQueryData(
      size: size,
      disableAnimations: reduced,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(body: child),
  ),
);

class _Host {
  final picked = <String>[];
  final tones = <(String, String?)>[];
  final remembered = <String, String>{};

  Widget picker({
    Set<String> selected = const {},
    bool search = true,
    TextEditingController? controller,
    Key? key,
  }) => StatefulBuilder(
    builder: (context, setState) => NotionEmojiPicker(
      key: key,
      sections: _sections(),
      search: search ? _search() : null,
      selected: selected,
      tones: remembered,
      controller: controller,
      onSelected: picked.add,
      onTone: (emoji, tone) => setState(() {
        tones.add((emoji, tone));
        if (tone == null) {
          remembered.remove(NotionEmojiSearch.key(emoji));
        } else {
          remembered[NotionEmojiSearch.key(emoji)] = tone;
        }
      }),
    ),
  );
}

Finder _cell(String glyph) => find.bySemanticsLabel(glyph);

bool _selected(WidgetTester tester, Finder finder) =>
    tester
        .getSemantics(finder)
        .getSemanticsData()
        .flagsCollection
        .isSelected
        .toBoolOrNull() ??
    false;

void main() {
  setUpAll(() async {
    // The goldens use the bundled fonts (design_system_golden_test.dart).
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  group('search', () {
    final search = _search();
    List<String> q(String query, {Map<String, int> usage = const {}}) => [
      for (final e in search.search(query, usage: usage)) e.emoji,
    ];

    test('exact word beats prefix beats substring; ties by popularity', () {
      // "heart": exact on ❤️ and 💔; ❤️ is more popular.
      expect(q('heart').take(2), ['❤️', '💔']);
      // "cry": exact on 😢 and 😭; 😭 ranks higher in popularity.
      expect(q('cry'), ['😭', '😢']);
      // "bro": prefix of "broken" only.
      expect(q('bro'), ['💔']);
      // "ok": a substring of "smoking" and "broken", found last.
      expect(q('ok').toSet(), {'🚬', '💔'});
      expect(q('smok'), ['🚬']);
      // An alias phrase word is a word: "thumbs" → 👍.
      expect(q('thumbs').first, '👍');
      // A whole phrase ranks its emoji first.
      expect(q('red heart').first, '❤️');
      expect(q('<3'), ['❤️']);
    });

    test('every word must match; case, diacritics and shortcodes fold', () {
      expect(q('sad sob'), ['😭']);
      expect(q('SAD'), q('sad'));
      expect(q('cafe'), ['☕']);
      expect(q('CAFÉ'), ['☕']);
      expect(q(':fire:'), ['🔥']);
      expect(q('thumbs_up').first, '👍');
      expect(q('zzzz'), isEmpty);
      expect(q('   '), isEmpty);
      expect(NotionEmojiSearch.fold('  Łódź  Café '), 'lodz cafe');
    });

    test('the user\'s own use ranks first among equals', () {
      expect(q('cry', usage: {'😢': 3}), ['😢', '😭']);
      // A better match still wins over use.
      expect(q('sob', usage: {'😢': 9}), ['😭']);
    });

    test('a pasted emoji finds itself in any spelling or tone', () {
      expect(q('❤'), ['❤️']);
      expect(q('👍\u{FE0F}'), ['👍']);
      expect(q('👍🏽'), ['👍']);
      expect(q('🔥 heart').take(3), ['🔥', '❤️', '💔']);
      expect(search.lookup('✌'), isNotNull);
    });
  });

  test('skin tones go on and off as valid sequences', () {
    expect(NotionEmojiTones.apply('👍', '🏽'), '👍🏽');
    // The presentation selector gives way to the modifier.
    expect(NotionEmojiTones.apply('✌️', '🏿'), '✌🏿');
    expect(NotionEmojiTones.strip('✌🏿'), '✌️');
    expect(NotionEmojiTones.apply('🤷‍♂️', '🏻'), '🤷🏻‍♂️');
    expect(NotionEmojiTones.apply('👍🏽', '🏻'), '👍🏻');
    expect(NotionEmojiTones.apply('👍🏽', null), '👍');
    expect(NotionEmojiTones.of('👋🏾'), '🏾');
    expect(NotionEmojiTones.of('👋'), isNull);
    expect(NotionEmojiSearch.key('👍🏽'), NotionEmojiSearch.key('👍️'));
  });

  testWidgets('sections with sticky headers; a tap picks the glyph', (
    tester,
  ) async {
    _phone(tester);
    final host = _Host();
    await tester.pumpWidget(_app(host.picker()));
    await tester.pumpAndSettle();
    expect(find.text('Smileys & people'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-search')), findsOneWidget);
    await tester.tap(_cell('😂'));
    await tester.pump();
    expect(host.picked, ['😂']);
    // Scrolled into the animals: their header stays pinned at the top.
    await tester.drag(find.text('Smileys & people'), const Offset(0, -260));
    await tester.pumpAndSettle();
    final header = find.text('Animals & nature');
    expect(header, findsOneWidget);
    final grid = tester.getRect(find.byType(CustomScrollView).first);
    expect(tester.getRect(header).top, lessThan(grid.top + 30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing searches at once; empty state; Enter picks the first', (
    tester,
  ) async {
    _phone(tester);
    final host = _Host();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(host.picker(controller: controller)));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('emoji-search'));
    final before = tester.getRect(field);
    await tester.enterText(field, 'cry');
    await tester.pump();
    final state = tester.state<NotionEmojiPickerState>(
      find.byType(NotionEmojiPicker),
    );
    expect([for (final e in state.results) e.emoji], ['😭', '😢']);
    await tester.pumpAndSettle();
    // The field never moves; the categories fade out under the results.
    expect(tester.getRect(field), before);
    expect(find.text('Smileys & people').hitTestable(), findsNothing);
    await tester.enterText(field, 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No emoji found'), findsOneWidget);
    await tester.enterText(field, 'heart');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(host.picked, ['❤️']);
    // Escape clears the query and brings the categories back.
    await tester.tap(field);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(find.text('Smileys & people').hitTestable(), findsOneWidget);
  });

  testWidgets('the category bar jumps, follows the scroll and has 48pt cells', (
    tester,
  ) async {
    _phone(tester);
    final host = _Host();
    await tester.pumpWidget(_app(host.picker()));
    await tester.pumpAndSettle();
    final symbols = find.byKey(const ValueKey('emoji-category-symbols'));
    expect(tester.getSize(symbols).height, NotionSize.touchTarget);
    expect(
      tester.getSize(symbols).width,
      greaterThanOrEqualTo(NotionSize.touchTarget),
    );
    await tester.tap(find.byKey(const ValueKey('emoji-category-food')));
    await tester.pumpAndSettle();
    expect(find.text('Food & drink'), findsOneWidget);
    final grid = tester.getRect(find.byType(CustomScrollView).first);
    expect(
      tester.getRect(find.text('Food & drink')).top,
      lessThan(grid.top + 30),
    );
    bool selected(String id) =>
        _selected(tester, find.byKey(ValueKey('emoji-category-$id')));
    expect(selected('food'), isTrue);
    expect(selected('people'), isFalse);
    // Scrolling back by hand moves the bar with it.
    await tester.fling(find.text('Food & drink'), const Offset(0, 4000), 4000);
    await tester.pumpAndSettle();
    expect(selected('people'), isTrue);
    expect(selected('food'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press offers skin tones; a tap or a slide picks one', (
    tester,
  ) async {
    _phone(tester);
    final host = _Host();
    await tester.pumpWidget(_app(host.picker()));
    await tester.pumpAndSettle();
    await tester.longPress(_cell('👍'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-tone-3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('emoji-tone-3')));
    await tester.pumpAndSettle();
    expect(host.picked, ['👍🏽']);
    expect(host.tones, [('👍', '🏽')]);
    // Remembered: the grid now shows the toned glyph.
    expect(_cell('👍🏽'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-tone-3')), findsNothing);

    // Slide onto a tone while still holding (Telegram).
    final finger = await tester.startGesture(tester.getCenter(_cell('👋')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await finger.moveTo(
      tester.getCenter(find.byKey(const ValueKey('emoji-tone-5'))),
    );
    await tester.pump();
    await finger.up();
    await tester.pumpAndSettle();
    expect(host.picked.last, '👋🏿');
    // An emoji without tones only picks.
    await tester.longPress(_cell('😂'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-tone-0')), findsNothing);
  });

  testWidgets('own reactions are marked selected', (tester) async {
    _phone(tester);
    final host = _Host();
    await tester.pumpWidget(_app(host.picker(selected: {'❤'})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji-category-symbols')));
    await tester.pumpAndSettle();
    expect(_selected(tester, _cell('❤️')), isTrue);
    expect(_selected(tester, _cell('🔥')), isFalse);
  });

  testWidgets('320 pt at 2× text: no overflow, six columns, bar scrolls', (
    tester,
  ) async {
    _phone(tester, const Size(320, 640));
    final host = _Host();
    final many = [
      for (var i = 0; i < 9; i++)
        NotionEmojiSection(
          id: 's$i',
          title: 'Section $i',
          icon: Icons.circle_outlined,
          emoji: _filler(0x1F400 + i * 10, 10, 's$i'),
        ),
    ];
    await tester.pumpWidget(
      _app(
        NotionEmojiPicker(
          sections: many,
          search: _search(),
          onSelected: host.picked.add,
        ),
        size: const Size(320, 640),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final cell = tester.getSize(_cell(String.fromCharCode(0x1F400)));
    expect(cell.width, closeTo((320 - 16) / 6, .01));
    // Nine 48 pt cells do not fit 320 pt: the bar scrolls instead.
    expect(
      find.descendant(
        of: find.byType(NotionEmojiPicker),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('emoji-category-s5')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion jumps without animating; no timers left', (
    tester,
  ) async {
    _phone(tester);
    final host = _Host();
    await tester.pumpWidget(_app(host.picker(), reduced: true));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('emoji-category-symbols')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Symbols'), findsOneWidget);
  });

  group('goldens', () {
    Future<void> golden(
      WidgetTester tester,
      String name,
      Brightness brightness,
    ) async {
      _phone(tester, const Size(390, 520));
      final host = _Host()..remembered[NotionEmojiSearch.key('👍')] = '🏽';
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('golden'),
          child: _app(
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.md),
              child: host.picker(selected: {'😂'}),
            ),
            size: const Size(390, 520),
            brightness: brightness,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await expectLater(
        find.byKey(const Key('golden')),
        matchesGoldenFile('goldens/primitives/$name.png'),
      );
    }

    testWidgets(
      'emoji picker dark',
      (tester) => golden(tester, 'emoji-picker-dark', Brightness.dark),
    );
    testWidgets(
      'emoji picker light',
      (tester) => golden(tester, 'emoji-picker-light', Brightness.light),
    );
  });
}
