// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Media viewer motion (DESIGN.md "Motion", NotionMediaRoute and friends) and
// the inbox motion added with it: the photo flies from its thumbnail and
// back, a short swipe springs back exactly to rest, a long one closes, a
// double tap zooms around the tapped point, reduced motion has no flight and
// no spring, and every animation ends on identity.
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget home, {bool reduced = false}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: app!,
  ),
  home: home,
);

Future<void> _fresh(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(app);
  await tester.pump();
}

const _thumbKey = ValueKey('thumb');
const _viewerKey = ValueKey('viewer-media');
const _tag = 'photo';

/// The flying copy of the thumbnail (the hero shuttle in the overlay).
final _shuttle = find.descendant(
  of: find.byType(ClipRRect, skipOffstage: false),
  matching: find.byKey(_thumbKey, skipOffstage: false),
);

/// A chat-like page with one thumbnail hero that opens the viewer.
class _Source extends StatelessWidget {
  const _Source();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            NotionMediaRoute<void>(builder: (_) => const _Viewer()),
          ),
          child: const Hero(
            tag: _tag,
            createRectTween: NotionMediaHero.rectTween,
            child: SizedBox(
              key: _thumbKey,
              width: 80,
              height: 60,
              child: ColoredBox(color: Color(0xFF3366CC)),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Viewer extends StatefulWidget {
  const _Viewer();

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> with TickerProviderStateMixin {
  late final drag = NotionDismissDrag(vsync: this);

  @override
  void dispose() {
    drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: NotionMediaBackdrop(drag: drag)),
      Center(
        child: NotionMediaHero(
          tag: _tag,
          child: const SizedBox(
            key: _viewerKey,
            width: 400,
            height: 300,
            child: ColoredBox(color: Color(0xFFCC6633)),
          ),
        ),
      ),
    ],
  );
}

Color _backdrop(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find.descendant(
        of: find.byType(NotionMediaBackdrop),
        matching: find.byType(ColoredBox),
      ),
    )
    .color;

void main() {
  group('NotionMediaRoute + NotionMediaHero', () {
    testWidgets('the photo flies out of its thumbnail and back', (
      tester,
    ) async {
      await _fresh(tester, _app(const _Source()));
      final thumb = tester.getRect(find.byKey(_thumbKey));

      await tester.tap(find.byKey(_thumbKey));
      await tester.pump();
      await tester.pump(NotionMotion.medium * .4);
      // Mid-flight the thumbnail itself flies (it is already decoded): it
      // is larger than the thumbnail and smaller than the stage.
      final flying = tester.getRect(_shuttle);
      expect(flying.width, greaterThan(thumb.width));
      expect(flying.width, lessThan(400));
      expect(find.byKey(_viewerKey), findsNothing);
      // The backdrop is fading in, never painted at once.
      expect(_backdrop(tester).a, inExclusiveRange(0, NotionMediaColors.viewer.a));

      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_viewerKey)), const Size(400, 300));
      expect(_backdrop(tester).a, closeTo(NotionMediaColors.viewer.a, 1e-6));
      // The page below never moved; its thumbnail stays hidden behind the
      // viewer (Telegram), so the photo has an empty slot to fly back into.
      expect(find.byKey(_thumbKey), findsNothing);
      expect(
        tester.getRect(find.byType(Hero, skipOffstage: false).first),
        thumb,
      );

      Navigator.of(tester.element(find.byKey(_viewerKey))).pop();
      await tester.pump();
      await tester.pump(NotionMotion.reverse * .5);
      final back = tester.getRect(_shuttle);
      expect(back.width, inExclusiveRange(thumb.width, 400));
      await tester.pumpAndSettle();
      expect(find.byType(NotionMediaBackdrop), findsNothing);
      expect(tester.getRect(find.byKey(_thumbKey)), thumb);
    });

    testWidgets('without a thumbnail the media fades and scales in', (
      tester,
    ) async {
      await _fresh(
        tester,
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  NotionMediaRoute<void>(builder: (_) => const _Viewer()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(NotionMotion.medium * .3);
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(_viewerKey),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      for (final f in tester.widgetList<FadeTransition>(
        find.ancestor(
          of: find.byKey(_viewerKey),
          matching: find.byType(FadeTransition),
        ),
      )) {
        expect(f.opacity.value, 1);
      }
      for (final s in tester.widgetList<ScaleTransition>(
        find.ancestor(
          of: find.byKey(_viewerKey),
          matching: find.byType(ScaleTransition),
        ),
      )) {
        expect(s.scale.value, 1);
      }
    });

    testWidgets('reduced motion: no flight', (tester) async {
      await _fresh(tester, _app(const _Source(), reduced: true));
      await tester.tap(find.byKey(_thumbKey));
      await tester.pump();
      await tester.pump(NotionMotion.medium * .4);
      // No shuttle: the viewer media sits in place, the thumbnail stays.
      expect(find.byKey(_viewerKey), findsOneWidget);
      expect(tester.getSize(find.byKey(_thumbKey)), const Size(80, 60));
      await tester.pumpAndSettle();
    });
  });

  group('NotionDismissDrag', () {
    late NotionDismissDrag drag;
    tearDown(() => drag.dispose());

    testWidgets('a short swipe springs back exactly to rest', (tester) async {
      drag = NotionDismissDrag(vsync: tester);
      drag
        ..start()
        ..update(40)
        ..update(30);
      expect(drag.offset.value, 70);
      expect(drag.progress, closeTo(70 / 400, 1e-9));
      expect(drag.end(200), isFalse);
      await tester.pump();
      await tester.pump(NotionMotion.quick);
      expect(drag.offset.value, inExclusiveRange(-70, 70));
      await tester.pumpAndSettle();
      expect(drag.offset.value, 0);
      expect(drag.dragging, isFalse);
    });

    testWidgets('past the distance or flung, it closes', (tester) async {
      drag = NotionDismissDrag(vsync: tester);
      drag
        ..start()
        ..update(NotionDismissDrag.defaultDistance + 1);
      expect(drag.end(0), isTrue);

      drag.offset.value = 0;
      drag
        ..start()
        ..update(30);
      expect(drag.end(NotionDismissDrag.defaultVelocity + 1), isTrue);

      // A fling back towards the start is not a dismissal.
      drag.offset.value = 0;
      drag
        ..start()
        ..update(30);
      expect(drag.end(-NotionDismissDrag.defaultVelocity - 1), isFalse);
      await tester.pumpAndSettle();
      expect(drag.offset.value, 0);
    });

    testWidgets('reduced motion puts the media back at once', (tester) async {
      drag = NotionDismissDrag(vsync: tester);
      drag
        ..start()
        ..update(50);
      expect(drag.end(0, reduced: true), isFalse);
      expect(drag.offset.value, 0);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('transform and chrome follow the drag, identity at rest', (
      tester,
    ) async {
      drag = NotionDismissDrag(vsync: tester);
      const child = SizedBox(key: ValueKey('media'), width: 10, height: 10);
      await _fresh(
        tester,
        _app(
          Scaffold(
            body: Column(
              children: [
                NotionDismissTransform(drag: drag, child: child),
                NotionMediaChrome(
                  drag: drag,
                  visible: true,
                  child: const Text('chrome'),
                ),
              ],
            ),
          ),
        ),
      );
      double chromeOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('chrome'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('media')),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(chromeOpacity(), 1);
      drag
        ..start()
        ..update(80);
      await tester.pump();
      expect(find.byType(Transform), findsWidgets);
      expect(chromeOpacity(), lessThan(1));
      expect(drag.end(0), isFalse);
      await tester.pumpAndSettle();
      expect(chromeOpacity(), 1);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('media')),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
    });

    testWidgets('chrome hides and returns when toggled', (tester) async {
      drag = NotionDismissDrag(vsync: tester);
      Widget chrome(bool visible) => _app(
        Scaffold(
          body: NotionMediaChrome(
            drag: drag,
            visible: visible,
            child: const Text('chrome'),
          ),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('chrome'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      await _fresh(tester, chrome(true));
      await tester.pumpWidget(chrome(false));
      await tester.pump(NotionMotion.instant);
      expect(opacity(), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(opacity(), 0);
      await tester.pumpWidget(chrome(true));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });
  });

  group('NotionDoubleTapZoom', () {
    testWidgets('zooms around the tapped point and back to fit', (
      tester,
    ) async {
      final zoom = NotionDoubleTapZoom(vsync: tester);
      final transform = TransformationController();
      addTearDown(() {
        zoom.dispose();
        transform.dispose();
      });
      const focal = Offset(120, 80);
      zoom.toggle(transform, focal);
      await tester.pump();
      await tester.pump(NotionMotion.quick);
      final mid = transform.value.getMaxScaleOnAxis();
      expect(mid, inExclusiveRange(1, zoom.scale));
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), zoom.scale);
      // The tapped point stays under the finger.
      expect(MatrixUtils.transformPoint(transform.value, focal), focal);
      expect(NotionDoubleTapZoom.isZoomed(transform), isTrue);

      zoom.toggle(transform, focal);
      await tester.pumpAndSettle();
      expect(transform.value, Matrix4.identity());
    });

    testWidgets('reduced motion jumps; a gesture stops the animation', (
      tester,
    ) async {
      final zoom = NotionDoubleTapZoom(vsync: tester);
      final transform = TransformationController();
      addTearDown(() {
        zoom.dispose();
        transform.dispose();
      });
      zoom.toggle(transform, Offset.zero, reduced: true);
      expect(transform.value.getMaxScaleOnAxis(), zoom.scale);
      expect(tester.hasRunningAnimations, isFalse);

      zoom.toggle(transform, Offset.zero);
      await tester.pump();
      await tester.pump(NotionMotion.instant);
      zoom.stop();
      final held = transform.value.clone();
      await tester.pumpAndSettle();
      expect(transform.value, held);
    });
  });

  test('notionFitMedia contains and scales up', () {
    expect(notionFitMedia(400, 300, const Size(800, 1200)), const Size(800, 600));
    expect(notionFitMedia(1000, 4000, const Size(400, 800)), const Size(200, 800));
    expect(notionFitMedia(null, 300, const Size(400, 800)), isNull);
    expect(notionFitMedia(0, 300, const Size(400, 800)), isNull);
  });

  group('inbox motion', () {
    testWidgets('a row an action just created flashes once on mount', (
      tester,
    ) async {
      Widget row({required bool fresh}) => _app(
        Scaffold(
          body: NotionInboxRow(
            key: ValueKey(fresh),
            avatar: const SizedBox.shrink(),
            name: 'Ada',
            preview: 'Preview',
            highlight: fresh ? (0, 1) : null,
            highlightOnMount: fresh,
            onTap: () {},
          ),
        ),
      );
      await _fresh(tester, row(fresh: false));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(row(fresh: true));
      await tester.pump(NotionMotion.short);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(NotionMotion.highlight);
      expect(tester.hasRunningAnimations, isFalse);
    });

    Widget row({bool typing = false, bool pinned = false, int count = 0}) =>
        _app(
          Scaffold(
            body: NotionInboxRow(
              avatar: const SizedBox.shrink(),
              name: 'Ada',
              preview: typing ? 'is typing…' : 'Preview',
              time: '09:12',
              typing: typing,
              pinned: pinned,
              unreadCount: count,
              onTap: () {},
            ),
          ),
        );

    testWidgets('typing dots grow in, loop and leave with the message', (
      tester,
    ) async {
      await _fresh(tester, row());
      expect(find.byType(NotionTypingDots), findsNothing);
      await tester.pumpWidget(row(typing: true));
      await tester.pump(NotionMotion.quick);
      expect(find.byType(NotionTypingDots), findsOneWidget);
      // The dots loop: let a few frames pass instead of settling.
      await tester.pump(NotionMotion.medium);
      await tester.pump(NotionMotion.medium);
      final text = tester.widget<Text>(find.text('is typing…'));
      expect(
        text.style?.color,
        tester.element(find.text('is typing…')).notion.colors.accent,
      );
      await tester.pumpWidget(row());
      await tester.pumpAndSettle();
      expect(find.byType(NotionTypingDots), findsNothing);
    });

    testWidgets('the pin glyph pops in when pinned and yields to unread', (
      tester,
    ) async {
      await _fresh(tester, row());
      final pin = find.byKey(const ValueKey('notion_inbox_pin'));
      expect(pin, findsNothing);
      await tester.pumpWidget(row(pinned: true));
      await tester.pump(NotionMotion.instant);
      expect(pin, findsOneWidget);
      await tester.pumpAndSettle();
      for (final s in tester.widgetList<ScaleTransition>(
        find.ancestor(of: pin, matching: find.byType(ScaleTransition)),
      )) {
        expect(s.scale.value, 1);
      }
      await tester.pumpWidget(row(pinned: true, count: 2));
      await tester.pumpAndSettle();
      expect(pin, findsNothing);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a new pinned card pops in; existing cards stay still', (
      tester,
    ) async {
      NotionPinnedShortcut pin(String name, int order) => NotionPinnedShortcut(
        name: name,
        avatar: const SizedBox.shrink(),
        onTap: () {},
        order: order,
      );
      Widget pins(List<NotionPinnedShortcut> list) => _app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: NotionPinnedShortcuts(pins: list),
          ),
        ),
      );
      double scaleOf(String name) => tester
          .widgetList<ScaleTransition>(
            find.ancestor(of: find.text(name), matching: find.byType(ScaleTransition)),
          )
          .fold(1.0, (v, s) => v * s.scale.value);

      await _fresh(tester, pins([pin('Anna', 0)]));
      expect(scaleOf('Anna'), 1);
      await tester.pumpWidget(pins([pin('Anna', 0), pin('Team', 1)]));
      await tester.pump();
      await tester.pump(NotionMotion.instant);
      expect(scaleOf('Anna'), 1);
      expect(scaleOf('Team'), inExclusiveRange(NotionMotion.dialogFrom - .01, 1));
      await tester.pumpAndSettle();
      expect(scaleOf('Team'), 1);

      // A third pin opens a new page: the carousel slides to it.
      await tester.pumpWidget(
        pins([pin('Anna', 0), pin('Team', 1), pin('Mia', 2)]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mia'), findsOneWidget);
      expect(scaleOf('Mia'), 1);
      expect(
        tester.getTopLeft(find.text('Mia')).dx,
        lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio),
      );
    });
  });
}
