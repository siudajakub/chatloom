import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(
  Widget child, {
  TextDirection direction = TextDirection.ltr,
  double width = 390,
  double scale = 1,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: TextScaler.linear(scale),
      ),
      child: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    ),
  ),
);

Finder fill(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(ClipRRect));

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('directional alignment in ${direction.name}', (tester) async {
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              ConversationBubble(
                key: Key('incoming'),
                outgoing: false,
                body: Text('Hello'),
              ),
              ConversationBubble(
                key: Key('outgoing'),
                outgoing: true,
                body: Text('Hello'),
              ),
            ],
          ),
          direction: direction,
        ),
      );
      final incoming = tester.getRect(fill('incoming'));
      final outgoing = tester.getRect(fill('outgoing'));
      if (direction == TextDirection.ltr) {
        expect(incoming.center.dx, lessThan(outgoing.center.dx));
        expect(incoming.left, 36);
        expect(outgoing.right, 390);
      } else {
        expect(incoming.center.dx, greaterThan(outgoing.center.dx));
        expect(incoming.right, 390 - 36);
        expect(outgoing.left, 0);
      }
      expect(incoming.width, lessThan(150));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('only chronological final incoming bubbles show an avatar', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Column(
          children: [
            for (final position in ConversationGroupPosition.values)
              ConversationBubble(
                key: Key(position.name),
                outgoing: false,
                groupPosition: position,
                avatar: Text('Avatar ${position.name}'),
                heading: Text('Source ${position.name}'),
                body: const Text('A message'),
                footer: const Text('16:40'),
                reactions: const Text('👍 1'),
              ),
            const ConversationBubble(
              outgoing: true,
              avatar: Text('Own avatar'),
              body: Text('Own message'),
            ),
          ],
        ),
      ),
    );
    expect(find.text('Avatar first'), findsNothing);
    expect(find.text('Avatar middle'), findsNothing);
    expect(find.text('Avatar single'), findsOneWidget);
    expect(find.text('Avatar last'), findsOneWidget);
    expect(find.text('Own avatar'), findsNothing);
    expect(find.text('Source first'), findsOneWidget);
    expect(find.text('Source single'), findsOneWidget);
    expect(find.text('Source middle'), findsNothing);
    expect(find.text('Source last'), findsNothing);
    final avatar = tester.getRect(find.text('Avatar last'));
    expect(avatar.bottom, tester.getRect(fill('last')).bottom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('joining corners and spacing follow chronology and direction', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const Column(
          children: [
            ConversationBubble(
              key: Key('first'),
              outgoing: false,
              groupPosition: ConversationGroupPosition.first,
              body: Text('First'),
            ),
            ConversationBubble(
              key: Key('middle'),
              outgoing: true,
              groupPosition: ConversationGroupPosition.middle,
              body: Text('Middle'),
            ),
            ConversationBubble(
              key: Key('last'),
              outgoing: false,
              groupPosition: ConversationGroupPosition.last,
              body: Text('Last'),
            ),
          ],
        ),
      ),
    );
    final first = tester
        .widget<ClipRRect>(fill('first'))
        .borderRadius
        .resolve(TextDirection.ltr);
    final middle = tester
        .widget<ClipRRect>(fill('middle'))
        .borderRadius
        .resolve(TextDirection.ltr);
    final last = tester
        .widget<ClipRRect>(fill('last'))
        .borderRadius
        .resolve(TextDirection.ltr);
    const outer = Radius.circular(NotionBubble.outer);
    const joined = Radius.circular(NotionBubble.joined);
    expect(first.topLeft, outer);
    expect(first.bottomLeft, joined);
    expect(middle.topRight, joined);
    expect(middle.bottomRight, joined);
    expect(last.topLeft, joined);
    expect(last.bottomLeft, outer);
    expect(
      tester.getRect(fill('middle')).top - tester.getRect(fill('first')).bottom,
      NotionBubble.groupGap,
    );
  });

  testWidgets(
    'reactions and status reserve space below media without padding',
    (tester) async {
      await tester.pumpWidget(
        host(
          ConversationBubble(
            key: const Key('media'),
            outgoing: false,
            media: true,
            avatar: const Icon(Icons.person_outline),
            body: const SizedBox(key: Key('photo'), width: 600, height: 180),
            reactions: const Text('👍 2'),
            footer: const Text('Sending · 16:40'),
          ),
        ),
      );
      final surface = tester.getRect(fill('media'));
      expect(tester.getRect(find.byKey(const Key('photo'))), surface);
      // Reactions overlap the bubble's bottom edge (Messenger).
      expect(
        tester.getRect(find.text('👍 2')).top,
        closeTo(surface.bottom - NotionReactions.overlap, .01),
      );
      expect(
        tester.getRect(find.text('Sending · 16:40')).top,
        greaterThan(tester.getRect(find.text('👍 2')).bottom),
      );
      expect(tester.getRect(find.byType(Icon)).bottom, surface.bottom);
      expect(tester.takeException(), isNull);
    },
  );

  for (final direction in TextDirection.values) {
    testWidgets('320dp 200 percent text wraps in ${direction.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              ConversationBubble(
                key: Key('long'),
                outgoing: false,
                heading: Text('Anna · WhatsApp'),
                body: Text(
                  'A longer fictional message wraps and remains readable. '
                  'https://example.test/a/very/long/path/without/spaces',
                  style: TextStyle(fontSize: 17),
                ),
                footer: Text('Edited · 16:40'),
              ),
              ConversationBubble(
                outgoing: true,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text('Anna: Original quote'), Text('A reply')],
                ),
              ),
            ],
          ),
          direction: direction,
          width: 320,
          scale: 2,
        ),
      );
      final rect = tester.getRect(fill('long'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.width, lessThanOrEqualTo(320 * .88));
      expect(find.text('Anna: Original quote'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('dark roles light roles and explicit theme overrides are used', (
    tester,
  ) async {
    Future<Color> renderedColor(ThemeData theme) async {
      await tester.pumpWidget(
        host(
          const ConversationBubble(
            key: Key('color'),
            outgoing: true,
            body: Text('Message'),
          ),
          theme: theme,
        ),
      );
      // MaterialApp animates a theme change on the retained tree. Assert the
      // requested roles after that transition, rather than its previous frame.
      await tester.pumpAndSettle();
      final decoration = tester.widget<DecoratedBox>(
        find.descendant(of: fill('color'), matching: find.byType(DecoratedBox)),
      );
      return (decoration.decoration as BoxDecoration).color!;
    }

    expect(await renderedColor(ThemeData.dark()), const Color(0xFF414141));
    final light = ThemeData.light();
    expect(
      await renderedColor(light),
      light.colorScheme.surfaceContainerHighest,
    );
    expect(
      await renderedColor(
        ThemeData.dark().copyWith(
          extensions: const [
            ConversationBubbleColors(
              incoming: Colors.grey,
              outgoing: Colors.blueGrey,
              text: Colors.white,
              metadata: Colors.grey,
            ),
          ],
        ),
      ),
      Colors.blueGrey,
    );
  });

  testWidgets('inherited font size and text scaler survive the surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const DefaultTextStyle(
          style: TextStyle(fontSize: 21),
          child: ConversationBubble(
            outgoing: false,
            body: Text('Inherited style'),
          ),
        ),
        scale: 2,
      ),
    );
    final text = tester.widget<RichText>(find.byType(RichText));
    expect(text.text.style?.fontSize, 21);
    expect(text.textScaler.scale(21), 42);
  });

  testWidgets('selected media outline paints above its opaque content', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const ConversationBubble(
          key: Key('selected'),
          outgoing: true,
          media: true,
          selected: true,
          body: SizedBox(
            width: 200,
            height: 100,
            child: ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    final decorations = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: fill('selected'),
        matching: find.byType(DecoratedBox),
      ),
    );
    final outline = decorations.singleWhere(
      (box) => box.position == DecorationPosition.foreground,
    );
    expect((outline.decoration as BoxDecoration).border, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('surface wrapper moves fill and body together without metadata', (
    tester,
  ) async {
    var offset = 0.0;
    Future<void> render() => tester.pumpWidget(
      host(
        ConversationBubble(
          key: const Key('moving'),
          outgoing: false,
          body: const Text('A moving message'),
          avatar: const Icon(Icons.person_outline, key: Key('still-avatar')),
          heading: const Text('Fictional sender'),
          footer: const Text('16:40'),
          reactions: const Text('👍 1'),
          surfaceBuilder: (surface) =>
              Transform.translate(offset: Offset(offset, 0), child: surface),
        ),
      ),
    );

    await render();
    final beforeFill = tester.getRect(fill('moving'));
    final beforeBody = tester.getRect(find.text('A moving message'));
    final beforeAvatar = tester.getRect(find.byKey(const Key('still-avatar')));
    final beforeHeading = tester.getRect(find.text('Fictional sender'));
    final beforeFooter = tester.getRect(find.text('16:40'));
    final beforeReactions = tester.getRect(find.text('👍 1'));
    offset = 64;
    await render();
    expect(
      tester.getRect(fill('moving')),
      beforeFill.shift(const Offset(64, 0)),
    );
    expect(
      tester.getRect(find.text('A moving message')),
      beforeBody.shift(const Offset(64, 0)),
    );
    expect(tester.getRect(find.byKey(const Key('still-avatar'))), beforeAvatar);
    expect(tester.getRect(find.text('Fictional sender')), beforeHeading);
    expect(tester.getRect(find.text('16:40')), beforeFooter);
    expect(tester.getRect(find.text('👍 1')), beforeReactions);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chromeless bubbles have no fill and a circular selection ring', (
    tester,
  ) async {
    Widget bubble({required bool selected, required bool outgoing}) =>
        ConversationBubble(
          key: Key('round-$outgoing'),
          outgoing: outgoing,
          chromeless: true,
          selected: selected,
          groupPosition: ConversationGroupPosition.middle,
          avatar: const Text('Avatar'),
          footer: const Text('16:40'),
          body: const ConversationSelectionRing(
            child: SizedBox.square(key: Key('circle'), dimension: 200),
          ),
        );
    await tester.pumpWidget(
      host(
        Column(
          children: [
            bubble(selected: false, outgoing: false),
            bubble(selected: true, outgoing: true),
          ],
        ),
      ),
    );
    expect(fill('round-false'), findsNothing);
    expect(fill('round-true'), findsNothing);
    final circles = tester.getRect(find.byKey(const Key('circle')).first);
    expect(circles.size, const Size.square(200));
    expect(circles.left, 36, reason: 'avatar slot kept, no padding');
    final ring = find.byKey(const ValueKey('conversation-selection-ring'));
    expect(ring, findsOneWidget);
    final decoration = tester.widget<DecoratedBox>(ring).decoration;
    expect((decoration as ShapeDecoration).shape, isA<CircleBorder>());
    expect(tester.getRect(find.byKey(const Key('circle')).last).right, 390);
    // Consecutive chromeless items keep at least 8 px between them.
    final gap =
        tester.getTopLeft(find.byKey(const Key('circle')).last).dy -
        tester.getBottomLeft(find.byKey(const Key('circle')).first).dy;
    expect(gap, greaterThanOrEqualTo(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-line bubble is a pill', (tester) async {
    await tester.pumpWidget(
      host(
        const ConversationBubble(
          key: Key('pill'),
          outgoing: true,
          body: Text('ojoj'),
        ),
      ),
    );
    final rect = tester.getRect(fill('pill'));
    // Corners of at least ~half the height leave no visible flat side.
    expect(NotionBubble.outer, greaterThanOrEqualTo(rect.height / 2 - 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply quote sits above the fill, which covers its bottom', (
    tester,
  ) async {
    var opened = 0;
    var bubbleTaps = 0;
    await tester.pumpWidget(
      host(
        ConversationBubble(
          key: const Key('reply'),
          outgoing: true,
          avatar: const Text('Avatar'),
          quote: ConversationReplyQuote(
            key: const Key('quote'),
            text: 'jestem w pracy',
            fill: const Color(0xFF2D2D2D),
            textColor: const Color(0xFFAAAAA5),
            outgoing: true,
            caption: const Text('Replied to Anna'),
            onTap: () => opened++,
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => bubbleTaps++,
            child: const Text('ojoj'),
          ),
        ),
      ),
    );
    final quoteRect = tester.getRect(
      find.descendant(
        of: find.byKey(const Key('quote')),
        matching: find.byType(DecoratedBox),
      ),
    );
    final fillRect = tester.getRect(fill('reply'));
    final caption = tester.getRect(find.text('Replied to Anna'));
    expect(caption.bottom, lessThanOrEqualTo(quoteRect.top));
    // Outgoing: quote and bubble share the end edge.
    expect(quoteRect.right, fillRect.right);
    expect(
      quoteRect.bottom - fillRect.top,
      moreOrLessEquals(NotionBubble.quoteOverlap),
    );
    // The quoted text stays above the covered strip.
    expect(
      tester.getRect(find.text('jestem w pracy')).bottom,
      lessThanOrEqualTo(fillRect.top),
    );
    // Taps on the visible quote open the original; on the covered strip
    // they reach the bubble.
    await tester.tapAt(Offset(quoteRect.right - 8, quoteRect.top + 6));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapAt(Offset(fillRect.center.dx, fillRect.top + 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(opened, 1);
    expect(bubbleTaps, 1);
    expect(tester.takeException(), isNull);
  });

  test('quote colours stay opaque and readable on every chat palette', () {
    const pages = [
      Color(0xFF191919),
      Color(0xFFFAF9F6),
      Color(0xFFFAFAFA),
      Color(0xFFF0F2F4),
      Color(0xFFF8F4EC),
      Color(0xFFECF3F0),
      Color(0xFF202329),
      Color(0xFF292329),
    ];
    const sides = [
      Color(0xFF2B2B2B),
      Color(0xFF414141),
      Color(0xFFF0EFEB),
      Color(0xFFE8E7E3),
      Color(0xFFDFEBDB),
      Color(0xFFDBE6F5),
      Color(0xFFF0DFE9),
      Color(0xFFF1E6D2),
      Color(0xFFD8EEEC),
      Color(0xFFE5DEF2),
      Color(0xFFF2DDDD),
      Color(0xFFE5E7EB),
    ];
    for (final page in pages) {
      for (final side in sides) {
        for (final muted in const [Color(0xFFACACA8), Color(0xFF65655F)]) {
          final colors = ConversationReplyQuote.colorsFor(
            side: side,
            page: page,
            muted: muted,
          );
          expect(colors.fill.a, 1);
          expect(
            NotionContrast.ratio(colors.text, colors.fill),
            greaterThanOrEqualTo(NotionContrast.minimum),
            reason: 'side $side on page $page',
          );
        }
      }
    }
  });
}
