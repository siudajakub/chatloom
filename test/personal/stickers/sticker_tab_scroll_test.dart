// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 11: the sticker tab's scrolling (strip ↔ grid sync, sticky titles,
// floating search, kept place, still anchor, fling physics, content loops
// only at rest), its search (ranking, states, back) and the preview.
// Offline fixtures, no network.
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/stickers/composer_panel.dart';
import 'package:chatloom/personal/stickers/gif_tab.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/personal/stickers/sticker_search.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:chatloom/personal/stickers/sticker_tile.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

class _SendingRoom extends ConversationRoom {
  _SendingRoom(super.client, super.id, {super.network});
  int sends = 0;

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    sends++;
    return r'$sent';
  }
}

class _Host implements ConversationComposerHost {
  _Host(this.room);

  @override
  final Room room;
  @override
  final FocusNode inputFocus = FocusNode();
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  bool showEmojiPicker = true;
  @override
  Event? replyEvent;

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() {}
  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {}
  @override
  void emojiPickerBackspace() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Geometry of the fixtures at 400 × 320 (see [_GridLayout]): 5 columns of
/// 80, titles of 30, the search field 48, the strip 48, the tab bar 48.
const _tile = 80.0;
const _title = 30.0;
const _search = 48.0;
const _packExtent = _title + 6 * _tile; // 30 stickers = 6 rows

/// Offset of pack [n] (1-based) when there are no favourites or recents.
double _packOffset(int n) => _search + (n - 1) * _packExtent;

void main() {
  late FakeStickerBackend backend;
  late StickerLibrary library;
  late _SendingRoom room;
  late _Host host;
  late FocusNode panelFocus;

  setUp(() {
    final client = ConversationClient();
    room = _SendingRoom(client, '!chat:example.invalid', network: 'telegram');
    host = _Host(room);
    backend = FakeStickerBackend();
    library = fakeLibrary(backend);
    panelFocus = FocusNode();
    StickerLibrary.debugSet(client, library);
    StickerPanel.debugResetTab(StickerPanelTab.stickers);
    StickerTab.debugResetPosition();
    GifTab.debugResetPosition();
    // Pack 1–7: 30 stickers (😀, the first of each 😂); pack 8: 5.
    backend.rooms['!space:example.invalid'] = {
      for (var p = 1; p <= 8; p++)
        'P$p': pack('Pack $p', {
          for (var i = 0; i < (p == 8 ? 5 : 30); i++)
            'P${p}_$i': packImage('p${p}s$i', emoji: i == 0 ? '😂' : '😀'),
        }),
    };
    // A new pack goes first: add from the last so they read 1 … 8.
    for (var p = 8; p >= 1; p--) {
      library.addPack(
        StickerPackRef(roomId: '!space:example.invalid', stateKey: 'P$p'),
      );
    }
  });
  tearDown(() {
    library.dispose();
    panelFocus.dispose();
    host.inputFocus.dispose();
    host.sendController.dispose();
  });

  void phone(WidgetTester tester, {Size size = const Size(400, 800)}) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
  }

  Widget panel({double height = 320}) => SizedBox(
    height: height,
    child: StickerPanel(host: host, searchFocus: panelFocus),
  );

  Widget app(
    Widget child, {
    Brightness brightness = Brightness.dark,
    MediaQueryData Function(MediaQueryData)? media,
  }) => MaterialApp(
    theme: NotionTheme.build(brightness),
    builder: media == null
        ? null
        : (context, child) =>
              MediaQuery(data: media(MediaQuery.of(context)), child: child!),
    home: Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: child),
    ),
  );

  ScrollPosition grid(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('sticker-grid')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// The pack the strip marks as selected.
  String? selectedPack(WidgetTester tester) {
    final selected = [
      for (final s in tester.widgetList<Semantics>(
        find.descendant(
          of: find.byKey(const ValueKey('sticker-pack-strip')),
          matching: find.byType(Semantics),
        ),
      ))
        if (s.properties.selected == true) s.properties.label,
    ];
    expect(selected.length, lessThanOrEqualTo(1));
    return selected.firstOrNull;
  }

  Future<void> tapPack(WidgetTester tester, int n) async {
    final strip = find.byKey(const ValueKey('sticker-pack-strip'));
    final target = find.descendant(
      of: strip,
      matching: find.byTooltip('Pack $n'),
    );
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.descendant(of: strip, matching: find.byType(Scrollable)),
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
  }

  group('scrolling', () {
    testWidgets('a strip tap glides to the pack and holds its selection', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      expect(selectedPack(tester), 'Pack 1');

      await tapPack(tester, 5);
      final seen = <String?>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final selected = selectedPack(tester);
        if (seen.isEmpty || seen.last != selected) seen.add(selected);
      }
      await tester.pumpAndSettle();
      // Before wave 11 the strip ran through Pack 1 → 2 → 3 → 4 → 5.
      expect(seen, ['Pack 5']);
      expect(grid(tester).pixels, _packOffset(5));
    });

    testWidgets('the last, short pack stays selected after its tap', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      await tapPack(tester, 8);
      await tester.pumpAndSettle();
      // Its header cannot reach the top (the grid ends first).
      expect(grid(tester).pixels, grid(tester).maxScrollExtent);
      expect(selectedPack(tester), 'Pack 8');
    });

    testWidgets('the strip follows the grid as it scrolls', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final position = grid(tester);
      position.jumpTo(_packOffset(3) + 10);
      await tester.pumpAndSettle();
      expect(selectedPack(tester), 'Pack 3');
      position.jumpTo(_packOffset(2) - 10);
      await tester.pumpAndSettle();
      expect(selectedPack(tester), 'Pack 1');
    });

    testWidgets('titles stick; the search floats back on an upward scroll', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final gridTop = tester
          .getTopLeft(find.byKey(const ValueKey('sticker-grid')))
          .dy;
      grid(tester).jumpTo(_packOffset(3) + 200);
      await tester.pumpAndSettle();
      // Pack 3's title sits at the top while its rows pass under it.
      final title = find.ancestor(
        of: find.text('Pack 3'),
        matching: find.byType(ColoredBox),
      );
      expect(tester.getTopLeft(title.first).dy, gridTop);
      // The search field scrolled away with the top of the grid.
      final field = find.byKey(const ValueKey('sticker-search-field'));
      expect(field, findsNothing);

      // A small pull down brings the search field back over the grid.
      await tester.drag(
        find.byKey(const ValueKey('sticker-grid')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(field).dy, greaterThanOrEqualTo(gridTop));
      expect(tester.getTopLeft(field).dy, lessThan(gridTop + _search));
      // The sticky title moved below it instead of under it.
      expect(
        tester.getTopLeft(title.first).dy,
        moreOrLessEquals(gridTop + _search),
      );
    });

    testWidgets('a favourite added above keeps the browsed pack still', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      await tapPack(tester, 4);
      await tester.pumpAndSettle();
      expect(grid(tester).pixels, _packOffset(4));
      final title = find.ancestor(
        of: find.text('Pack 4'),
        matching: find.byType(ColoredBox),
      );
      final before = tester.getTopLeft(title.first).dy;

      library.toggleFavourite(library.packs.first.stickers[3]);
      await tester.pump();
      // The same frame: no jump by the new row above.
      expect(find.text('Favourites'), findsNothing); // above the screen
      expect(grid(tester).pixels, _packOffset(4) + _title + _tile);
      expect(tester.getTopLeft(title.first).dy, before);
    });

    testWidgets('the place survives search, tab switches and reopening', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      await tapPack(tester, 4);
      await tester.pumpAndSettle();
      final tab = tester.state(find.byType(StickerTab));

      // Search from the strip: the grid goes to the top for the results.
      await tester.tap(find.byTooltip('Search stickers'));
      await tester.pumpAndSettle();
      expect(panelFocus.hasFocus, isTrue);
      expect(grid(tester).pixels, 0);
      await tester.enterText(
        find.byKey(const ValueKey('sticker-search-field')),
        '😂',
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Sticker 😂'), findsNWidgets(8));
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(grid(tester).pixels, _packOffset(4));

      // GIFs and back: the same tab state, the same place.
      await tester.tap(find.byKey(const ValueKey('panel-tab-gifs')));
      await tester.pump(const Duration(milliseconds: 40));
      // Fade-through: the stickers still show while they fade out.
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack).first).index,
        StickerPanelTab.stickers.index,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack).first).index,
        StickerPanelTab.gifs.index,
      );
      await tester.tap(find.byKey(const ValueKey('panel-tab-stickers')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(StickerTab)), same(tab));
      expect(grid(tester).pixels, _packOffset(4));

      // The panel closes and opens again (it is rebuilt from scratch).
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      expect(grid(tester).pixels, _packOffset(4));
    });

    testWidgets('a long jump under reduced motion is immediate', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(
        app(panel(), media: (m) => m.copyWith(disableAnimations: true)),
      );
      await tester.pumpAndSettle();
      await tapPack(tester, 6);
      await tester.pump();
      expect(grid(tester).pixels, _packOffset(6));
    });

    testWidgets('Android flings clamp at the edges', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final position = grid(tester);
      await tester.fling(
        find.byKey(const ValueKey('sticker-grid')),
        const Offset(0, 300),
        3000,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, 0);
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const ValueKey('sticker-grid')),
        const Offset(0, -200),
        3000,
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(400));
    });

    testWidgets(
      'iOS and macOS bounce',
      (tester) async {
        phone(tester);
        await tester.pumpWidget(app(panel()));
        await tester.pumpAndSettle();
        final position = grid(tester);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('sticker-grid'))),
        );
        await gesture.moveBy(const Offset(0, 60));
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        expect(position.pixels, lessThan(0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(position.pixels, 0);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('animated stickers rest while the grid moves', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      bool cellTickers() => tester
          .widget<TickerMode>(
            find
                .descendant(
                  of: find.byType(StickerTile).first,
                  matching: find.byType(TickerMode),
                )
                .first,
          )
          .enabled;
      expect(cellTickers(), isTrue);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('sticker-grid'))),
      );
      await gesture.moveBy(const Offset(0, -30));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(cellTickers(), isFalse);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(cellTickers(), isTrue);
    });

    testWidgets('cells built during a fast fling wait to load', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final gridFinder = find.byKey(const ValueKey('sticker-grid'));
      int images() => find
          .descendant(of: gridFinder, matching: find.byType(MxcImage))
          .evaluate()
          .length;
      int cells() => find
          .descendant(of: gridFinder, matching: find.byType(StickerTile))
          .evaluate()
          .length;
      expect(images(), cells());
      await tester.fling(gridFinder, const Offset(0, -300), 9000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(images(), lessThan(cells()));
      await tester.pumpAndSettle();
      expect(images(), cells());
    });

    testWidgets('a sent sticker dips once', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final cell = find.bySemanticsLabel('Sticker 😂').first;
      await tester.tap(cell);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(room.sends, 1);
      final scales = tester
          .widgetList<ScaleTransition>(
            find.descendant(
              of: find.byType(StickerTile),
              matching: find.byType(ScaleTransition),
            ),
          )
          .map((s) => s.scale.value);
      expect(scales.any((s) => s < .99), isTrue);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<ScaleTransition>(
              find.descendant(
                of: find.byType(StickerTile),
                matching: find.byType(ScaleTransition),
              ),
            )
            .every((s) => (s.scale.value - 1).abs() < .001),
        isTrue,
      );
    });
  });

  group('search', () {
    testWidgets('states: results, nothing found; the field stays pinned', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('sticker-search-field'));
      await tester.enterText(field, 'no-such-sticker');
      await tester.pumpAndSettle();
      expect(find.text('No stickers found'), findsOneWidget);
      expect(find.text('Add sticker packs'), findsOneWidget);

      await tester.enterText(field, '😀');
      await tester.pumpAndSettle();
      expect(find.text('Stickers'), findsWidgets);
      final top = tester.getTopLeft(field).dy;
      await tester.drag(
        find.byKey(const ValueKey('sticker-grid')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(grid(tester).pixels, greaterThan(0));
      expect(tester.getTopLeft(field).dy, top);

      // The keyboard goes, the results stay; Close ends the search.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('Stickers'), findsWidgets);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.text('Pack 1'), findsOneWidget);
      expect(find.byTooltip('Search stickers'), findsOneWidget);
    });

    testWidgets('back closes the search before the chat', (tester) async {
      phone(tester);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('Inbox')),
            routes: [
              GoRoute(
                path: 'chat',
                builder: (context, state) => Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: panel(),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          theme: NotionTheme.build(Brightness.dark),
          routerConfig: router,
        ),
      );
      router.go('/chat');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sticker-search-field')),
        '😂',
      );
      await tester.pumpAndSettle();
      expect(find.text('Stickers'), findsWidgets);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('sticker-search-field')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(panelFocus.hasFocus, isFalse);
      expect(find.text('Pack 1'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);
    });

    group('ranking', () {
      StickerItem item(
        String id, {
        String body = '😀',
        String? shortcode,
        String? packUrl,
      }) => StickerItem.fromJson({
        'url': 'mxc://example.invalid/$id',
        'body': body,
        'shortcode': ?shortcode,
        'info': {
          'mimetype': 'image/webp',
          if (packUrl != null)
            'fi.mau.bridged_sticker': {
              'network': 'telegram',
              'id': id,
              'emoji': body,
              'pack_url': packUrl,
            },
        },
      }, StickerKind.sticker)!;

      List<String> ids(List<StickerItem> items) => [
        for (final i in items) i.key.split('/').last,
      ];

      test('exact words, then emoji keywords, prefixes, substrings', () {
        final index = StickerSearchIndex([
          item('prefix', body: 'catalogue'),
          item('exact', body: 'cat'),
          item('substring', body: 'bobcat'),
          item('emoji', body: '😺'),
          item('other', body: 'dog'),
        ]);
        final found = ids(index.search('cat'));
        expect(found.first, 'exact');
        expect(found, isNot(contains('other')));
        expect(found.indexOf('prefix'), lessThan(found.indexOf('substring')));
        expect(found.indexOf('emoji'), lessThan(found.indexOf('substring')));
        expect(found.last, 'substring');
      });

      test('ties keep the index order (favourites first)', () {
        final index = StickerSearchIndex([
          item('favourite', body: 'cat'),
          item('pack', body: 'cat'),
        ]);
        expect(ids(index.search('cat')), ['favourite', 'pack']);
        expect(ids(index.search('CAT ')), ['favourite', 'pack']);
      });

      test('several emoji: stickers with more of them first', () {
        final index = StickerSearchIndex([
          item('joy', body: '😂'),
          item('thumb', body: '👍'),
          item('both', body: '😂👍'),
        ]);
        expect(ids(index.search('😂👍')), ['both', 'joy', 'thumb']);
        expect(ids(index.search('👍')), ['thumb', 'both']);
      });

      test('every word must match', () {
        final index = StickerSearchIndex([
          item('a', body: 'happy cat'),
          item('b', body: 'happy dog'),
        ]);
        expect(ids(index.search('happy cat')), ['a']);
        expect(ids(index.search(':happy:')), ['a', 'b']);
      });

      test('the pack name in a shortcode is not a match; titles are', () {
        const url = 'https://t.me/addstickers/FictionalPack';
        final grin = item(
          'grin',
          shortcode: 'FictionalPack_grin',
          packUrl: url,
        );
        final fictional = StickerPack(
          key: 'fictional',
          title: 'Fictional pack',
          stickers: [grin],
          source: StickerPackSource.installed,
        );
        StickerPack titled(String title) => StickerPack(
          key: title,
          title: title,
          stickers: [item(title)],
          source: StickerPackSource.installed,
        );
        final index = StickerSearchIndex(
          [grin],
          packs: [
            titled('Bobcats'),
            titled('Funny cats'),
            fictional,
            titled('Cats and dogs'),
          ],
        );
        final results = index.searchRanked('fictional');
        expect(results.stickers, isEmpty);
        expect(results.packs.single.title, 'Fictional pack');
        expect(ids(index.search('grin')), ['grin']);
        expect(index.searchRanked('cat').packs.map((p) => p.title), [
          'Cats and dogs',
          'Funny cats',
          'Bobcats',
        ]);
      });
    });
  });

  group('preview', () {
    testWidgets('enlarged, animated, with the pack and its actions', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      await tester.longPress(find.bySemanticsLabel('Sticker 😂').first);
      await tester.pumpAndSettle();
      final preview = tester.widget<StickerImage>(
        find.byKey(const ValueKey('sticker-preview-image')),
      );
      expect(preview.preview, isTrue);
      expect(preview.size, greaterThanOrEqualTo(160));
      // Its tickers run (the grid's do not matter here).
      expect(
        tester
            .widget<TickerMode>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('sticker-preview-image')),
                    matching: find.byType(TickerMode),
                  )
                  .first,
            )
            .enabled,
        isTrue,
      );
      expect(find.textContaining('Pack 1'), findsWidgets);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Add to favourites'), findsOneWidget);
      // Inside its own pack there is no "View pack".
      expect(find.text('View pack'), findsNothing);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(room.sends, 1);

      // From the recents: View pack.
      await tester.longPress(
        find.descendant(
          of: find.byKey(const ValueKey('section-recent')),
          matching: find.bySemanticsLabel('Sticker 😂'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('View pack'), findsOneWidget);
      expect(find.text('Remove from recent'), findsOneWidget);
    });
  });

  group('layout', () {
    for (final brightness in Brightness.values) {
      testWidgets('2× text at 320 pt wide (${brightness.name})', (
        tester,
      ) async {
        phone(tester, size: const Size(320, 640));
        await tester.pumpWidget(
          app(
            panel(),
            brightness: brightness,
            media: (m) => m.copyWith(textScaler: const TextScaler.linear(2)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final field = find.byKey(const ValueKey('sticker-search-field'));
        expect(tester.getSize(field).height, greaterThanOrEqualTo(40));
        expect(find.text('Pack 1'), findsOneWidget);
        await tapPack(tester, 3);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Search stickers'));
        await tester.pumpAndSettle();
        await tester.enterText(field, 'nothing-like-this');
        await tester.pumpAndSettle();
        expect(find.text('No stickers found'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('no packs at 2× text: the add-packs empty state fits', (
      tester,
    ) async {
      phone(tester, size: const Size(320, 640));
      for (final p in [...library.packs]) {
        library.removePack(p);
      }
      await tester.pumpWidget(
        app(
          panel(),
          media: (m) => m.copyWith(textScaler: const TextScaler.linear(2)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No sticker packs yet'), findsOneWidget);
      expect(find.text('Add sticker packs'), findsOneWidget);
    });

    testWidgets('packs whose content has not synced: a static note', (
      tester,
    ) async {
      phone(tester);
      backend.rooms.clear();
      await tester.pumpWidget(app(panel()));
      await tester.pumpAndSettle();
      expect(find.text('Sticker packs are syncing'), findsOneWidget);
      expect(find.text('Add sticker packs'), findsOneWidget);
    });

    testWidgets('on desktop a focused search keeps the panel height', (
      tester,
    ) async {
      phone(tester, size: const Size(400, 500));
      final input = FocusNode();
      final search = FocusNode();
      addTearDown(input.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                ComposerPanelSlot(
                  visible: true,
                  inputFocus: input,
                  searchFocus: search,
                  softKeyboard: false,
                  builder: (context, height) => Focus(
                    focusNode: search,
                    child: const SizedBox.expand(
                      key: ValueKey('panel-content'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const ValueKey('panel-content')))
          .height;
      expect(height, 240);
      search.requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('panel-content'))).height,
        height,
      );
    });
  });
}
