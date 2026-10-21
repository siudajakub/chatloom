// SPDX-License-Identifier: AGPL-3.0-or-later
// Behaviour of the Notion motion primitives (DESIGN.md "Motion"): every
// one-shot animation settles to identity, reduced motion is instant, no
// timers are left behind (the test binding asserts this after each test),
// loops stop under TickerMode off and reduced motion.
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/pulsating_widget.dart';
import 'package:chatloom/widgets/typing_animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: app!,
  ),
  home: Scaffold(body: Center(child: child)),
);

double _opacity(WidgetTester tester, Finder finder) => tester
    .widgetList<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)),
    )
    .fold(1.0, (value, fade) => value * fade.opacity.value);

/// Product of the horizontal scale of every [Transform] above [finder].
double _scale(WidgetTester tester, Finder finder) => tester
    .widgetList<Transform>(
      find.ancestor(of: finder, matching: find.byType(Transform)),
    )
    .fold(1.0, (value, t) {
      final m = t.transform;
      return value * Offset(m.entry(0, 0), m.entry(1, 0)).distance;
    });

/// Mounts [app] on a fresh tree (switching `disableAnimations` on a live
/// MaterialApp animates the app itself) and lets the first frame pass.
Future<void> _fresh(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(app);
  await tester.pump();
}

Offset _shift(WidgetTester tester, Finder finder) => tester
    .widgetList<Transform>(
      find.ancestor(of: finder, matching: find.byType(Transform)),
    )
    .fold(Offset.zero, (value, t) {
      final translation = t.transform.getTranslation();
      return value + Offset(translation.x, translation.y);
    });

bool _identity(WidgetTester tester, Finder finder) =>
    _opacity(tester, finder) == 1 &&
    _scale(tester, finder) == 1 &&
    _shift(tester, finder) == Offset.zero;

void main() {
  group('tokens', () {
    test('legacy ChatLoomThemes timing points at the Notion tokens', () {
      expect(ChatLoomThemes.animationDuration, NotionMotion.short);
      expect(ChatLoomThemes.animationCurve, NotionMotion.standard);
      expect(NotionMotion.forward, NotionMotion.long);
    });

    test('spring curves start at 0, end exactly at 1', () {
      for (final curve in [
        NotionMotion.snappyCurve,
        NotionMotion.smoothCurve,
        NotionMotion.bouncyCurve,
      ]) {
        expect(curve.transform(0), 0);
        expect(curve.transform(1), 1);
        expect(curve.duration, greaterThan(Duration.zero));
        expect(curve.duration, lessThan(const Duration(seconds: 1)));
      }
      final samples = [
        for (var i = 1; i < 100; i++)
          NotionMotion.bouncyCurve.transform(i / 100),
      ];
      expect(samples.any((v) => v > 1), isTrue, reason: 'bouncy overshoots');
      final smooth = [
        for (var i = 1; i < 100; i++)
          NotionMotion.smoothCurve.transform(i / 100),
      ];
      expect(smooth.every((v) => v <= 1.0005), isTrue, reason: 'no bounce');
    });

    test('stagger delays are capped', () {
      expect(NotionMotion.staggerFor(0), Duration.zero);
      expect(NotionMotion.staggerFor(50), NotionMotion.staggerFor(10));
    });
  });

  group('NotionEntrance', () {
    testWidgets('starts hidden and settles to identity', (tester) async {
      await tester.pumpWidget(_app(const NotionEntrance(child: Text('A'))));
      final text = find.text('A');
      expect(_opacity(tester, text), 0);
      expect(_shift(tester, text).dy, NotionMotion.rise);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacity(tester, text), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(_identity(tester, text), isTrue);
    });

    testWidgets('reduced motion shows the child at once', (tester) async {
      await _fresh(
        tester,
        _app(const NotionEntrance(child: Text('A')), reduced: true),
      );
      expect(_identity(tester, find.text('A')), isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('stagger delays later items', (tester) async {
      await tester.pumpWidget(
        _app(
          const NotionStaggeredColumn(
            children: [Text('0'), Text('1'), Text('2'), Text('3')],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(NotionMotion.stagger * 2);
      expect(_opacity(tester, find.text('0')), greaterThan(0));
      expect(_opacity(tester, find.text('3')), 0);
      await tester.pumpAndSettle();
      for (final label in ['0', '1', '2', '3']) {
        expect(_identity(tester, find.text(label)), isTrue);
      }
    });

    testWidgets('waits for the hosting route to finish its push', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: NotionTheme.build(Brightness.dark),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: NotionEntrance(child: Text('B'))),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_opacity(tester, find.text('B')), 0);
      await tester.pumpAndSettle();
      expect(_identity(tester, find.text('B')), isTrue);
    });

    testWidgets('scope plays a key once and closes after the first wave', (
      tester,
    ) async {
      final show = ValueNotifier<int>(1);
      await tester.pumpWidget(
        _app(
          NotionEntranceScope(
            child: ValueListenableBuilder<int>(
              valueListenable: show,
              builder: (context, count, _) => Column(
                children: [
                  for (var i = 0; i < count; i++)
                    NotionEntrance(
                      key: ValueKey('$i-$count'),
                      playKey: i,
                      child: Text('row $i'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Rebuilt (new key, same playKey) and later rows appear instantly.
      show.value = 3;
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        expect(_identity(tester, find.text('row $i')), isTrue);
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the shake replays only on a new trigger', (tester) async {
      Widget build(int trigger) =>
          _app(NotionShake(trigger: trigger, child: const Text('PIN')));
      await tester.pumpWidget(build(0));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(build(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(_shift(tester, find.text('PIN')).dx, isNot(0));
      await tester.pumpAndSettle();
      expect(_identity(tester, find.text('PIN')), isTrue);
    });
  });

  group('NotionPressable', () {
    testWidgets('scales on press and springs back exactly to 1', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          NotionPressable(
            onTap: () => taps++,
            child: const SizedBox(width: 120, height: 48, child: Text('Go')),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Go')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_scale(tester, find.text('Go')), closeTo(.96, .001));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scale(tester, find.text('Go')), 1);
      expect(taps, 1);
    });

    testWidgets('a quick tap still dips, a drag lets go', (tester) async {
      await tester.pumpWidget(
        _app(
          const NotionPressable(
            bounce: true,
            child: SizedBox(width: 120, height: 48, child: Text('Go')),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Go')),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(_scale(tester, find.text('Go')), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scale(tester, find.text('Go')), 1);
    });

    testWidgets('reduced motion and disabled stay still', (tester) async {
      for (final (reduced, enabled) in [(true, true), (false, false)]) {
        await tester.pumpWidget(
          _app(
            NotionPressable(
              enabled: enabled,
              child: const SizedBox(width: 120, height: 48, child: Text('Go')),
            ),
            reduced: reduced,
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Go')),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(_scale(tester, find.text('Go')), 1);
        await gesture.up();
        await tester.pumpAndSettle();
      }
    });
  });

  group('switchers', () {
    testWidgets('fade-through swaps and settles; instant when reduced', (
      tester,
    ) async {
      Widget build(String label, {bool reduced = false}) => _app(
        NotionFadeThrough(child: Text(label, key: ValueKey(label))),
        reduced: reduced,
      );
      await tester.pumpWidget(build('One'));
      expect(_identity(tester, find.text('One')), isTrue);
      await tester.pumpWidget(build('Two'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
      expect(_identity(tester, find.text('Two')), isTrue);
      await _fresh(tester, build('Two', reduced: true));
      await tester.pumpWidget(build('Three', reduced: true));
      await tester.pump();
      expect(find.text('Two'), findsNothing);
      expect(_identity(tester, find.text('Three')), isTrue);
    });

    testWidgets('morph switcher settles to identity', (tester) async {
      Widget build(IconData icon) => _app(
        NotionMorphSwitcher(
          bounce: true,
          child: Icon(icon, key: ValueKey(icon)),
        ),
      );
      await tester.pumpWidget(build(Icons.mic));
      await tester.pumpWidget(build(Icons.send));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_scale(tester, find.byIcon(Icons.send)), lessThan(1));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(_identity(tester, find.byIcon(Icons.send)), isTrue);
      final rotation = tester
          .widget<RotationTransition>(
            find.ancestor(
              of: find.byIcon(Icons.send),
              matching: find.byType(RotationTransition),
            ),
          )
          .turns
          .value;
      expect(rotation, 0);
    });

    testWidgets('animated count rolls to the new value', (tester) async {
      await tester.pumpWidget(_app(const NotionAnimatedCount(count: 3)));
      await tester.pumpWidget(_app(const NotionAnimatedCount(count: 4)));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);
      expect(_opacity(tester, find.text('4')), 1);
    });

    testWidgets('size reveal grows, collapses and drops the child', (
      tester,
    ) async {
      Widget build(bool visible, {bool reduced = false}) => _app(
        NotionSizeReveal(
          visible: visible,
          child: const SizedBox(height: 80, width: 100, child: Text('Callout')),
        ),
        reduced: reduced,
      );
      await tester.pumpWidget(build(false));
      expect(find.text('Callout'), findsNothing);
      await tester.pumpWidget(build(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final partial = tester.getSize(find.byType(NotionSizeReveal)).height;
      expect(partial, inExclusiveRange(0, 80));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(NotionSizeReveal)).height, 80);
      expect(_opacity(tester, find.text('Callout')), 1);
      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      expect(find.text('Callout'), findsNothing);
      await tester.pumpWidget(build(true, reduced: true));
      await tester.pump();
      expect(tester.getSize(find.byType(NotionSizeReveal)).height, 80);
    });

    testWidgets('pop springs in, pulses on a trigger and ends at 1', (
      tester,
    ) async {
      Widget build(int count, {bool visible = true}) => _app(
        NotionPop(trigger: count, visible: visible, child: Text('$count')),
      );
      await tester.pumpWidget(build(1));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_scale(tester, find.text('1')), lessThan(1));
      await tester.pumpAndSettle();
      expect(_identity(tester, find.text('1')), isTrue);
      await tester.pumpWidget(build(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_scale(tester, find.text('2')), lessThan(1));
      await tester.pumpAndSettle();
      expect(_identity(tester, find.text('2')), isTrue);
      await tester.pumpWidget(build(2, visible: false));
      await tester.pumpAndSettle();
      expect(_opacity(tester, find.text('2')), 0);
    });

    testWidgets('row highlight flashes only on a new trigger', (tester) async {
      Widget build(Object trigger) =>
          _app(NotionRowHighlight(trigger: trigger, child: const Text('Row')));
      await tester.pumpWidget(build('a'));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(build('b'));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('delayed spinner stays hidden during the grace period', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const NotionDelayedSpinner()));
      await tester.pump();
      expect(
        tester.getSize(find.byType(NotionDelayedSpinner)).width,
        NotionSize.icon,
      );
      await tester.pump(
        NotionMotion.loaderGrace - const Duration(milliseconds: 50),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Dispose while the indeterminate spinner runs: no timers remain.
      await tester.pumpWidget(_app(const SizedBox()));
    });

    testWidgets('a spinner gone before the grace period never shows', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const NotionDelayedReveal(child: Text('Loading'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(_app(const Text('Done')));
      expect(find.text('Loading'), findsNothing);
    });
  });

  group('loops', () {
    for (final (name, widget) in [
      ('typing dots', const NotionTypingDots()),
      ('pulse', const NotionPulse(child: SizedBox.square(dimension: 40))),
      ('legacy TypingAnimation', const TypingAnimation()),
      (
        'legacy PulsatingWidget',
        const PulsatingWidget(child: SizedBox.square(dimension: 40)),
      ),
    ]) {
      testWidgets('$name runs, stops under TickerMode off and reduced motion', (
        tester,
      ) async {
        await tester.pumpWidget(_app(widget));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isTrue);
        await _fresh(tester, _app(TickerMode(enabled: false, child: widget)));
        expect(tester.binding.hasScheduledFrame, isFalse);
        await _fresh(tester, _app(widget, reduced: true));
        expect(tester.binding.hasScheduledFrame, isFalse);
      });
    }

    testWidgets('legacy TypingAnimation keeps its footprint', (tester) async {
      await tester.pumpWidget(_app(const TypingAnimation()));
      expect(tester.getSize(find.byType(TypingAnimation)), const Size(36, 24));
      await tester.pumpWidget(_app(const SizedBox()));
    });
  });

  group('NotionSkeleton', () {
    testWidgets('shimmers while loading, static when reduced, then content', (
      tester,
    ) async {
      Widget build(bool loading, {bool reduced = false}) => _app(
        SizedBox(
          width: 300,
          child: NotionSkeleton(
            enabled: loading,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [NotionSkeletonRow(), Text('Loaded')],
            ),
          ),
        ),
        reduced: reduced,
      );
      await tester.pumpWidget(build(true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await _fresh(tester, build(true, reduced: true));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await _fresh(tester, build(true));
      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      expect(find.text('Loaded'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('modal routes', () {
    testWidgets('dialog scales in from 94 % and settles to identity', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const SizedBox()));
      final context = tester.element(find.byType(SizedBox).last);
      showNotionDialog<void>(context: context, title: 'Leave?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final title = find.text('Leave?');
      expect(_scale(tester, title), inExclusiveRange(.9, 1));
      expect(_opacity(tester, title), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(_scale(tester, title), 1);
      expect(_opacity(tester, title), 1);
      Navigator.of(tester.element(title)).pop();
      await tester.pumpAndSettle();
      expect(title, findsNothing);
    });

    testWidgets('dialog under reduced motion only fades', (tester) async {
      await tester.pumpWidget(_app(const SizedBox(), reduced: true));
      final context = tester.element(find.byType(SizedBox).last);
      showNotionCustomDialog<void>(
        context: context,
        builder: (_) => const NotionDialog(title: 'Quiet'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(_scale(tester, find.text('Quiet')), 1);
      await tester.pumpAndSettle();
    });

    testWidgets('popover glass grows from its anchor and dismisses', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const SizedBox()));
      final context = tester.element(find.byType(SizedBox).last);
      final result = showNotionPopover<String>(
        context: context,
        alignment: Alignment.bottomRight,
        builder: (_) => const Align(
          alignment: Alignment.bottomRight,
          child: NotionGlassPanel(child: Text('Menu')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      RenderNotionRevealClip clip() =>
          tester.renderObject(find.byType(NotionRevealClip));
      final size = tester.getSize(find.byType(NotionRevealClip));
      expect(clip().revealing, isTrue);
      expect(clip().currentClip.width, lessThan(size.width));
      // It grows out of the bottom-right anchor.
      expect(clip().currentClip.right, closeTo(size.width, .01));
      expect(clip().currentClip.bottom, closeTo(size.height, .01));
      expect(_opacity(tester, find.text('Menu')), lessThan(1));
      expect(_scale(tester, find.text('Menu')), 1, reason: 'never scaled');
      await tester.pumpAndSettle();
      expect(clip().revealing, isFalse);
      expect(_identity(tester, find.text('Menu')), isTrue);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Menu'), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('popover under reduced motion shows at once', (tester) async {
      await tester.pumpWidget(_app(const SizedBox(), reduced: true));
      final context = tester.element(find.byType(SizedBox).last);
      showNotionPopover<void>(
        context: context,
        builder: (_) =>
            const Center(child: NotionGlassPanel(child: Text('Quiet'))),
      );
      await tester.pump();
      expect(
        tester
            .renderObject<RenderNotionRevealClip>(find.byType(NotionRevealClip))
            .revealing,
        isFalse,
      );
      expect(_identity(tester, find.text('Quiet')), isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('sheet content rises in and settles', (tester) async {
      await tester.pumpWidget(_app(const SizedBox()));
      final context = tester.element(find.byType(SizedBox).last);
      showNotionSheet<void>(
        context: context,
        title: 'Send from',
        builder: (_) => const Text('Signal'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Signal'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_identity(tester, find.text('Signal')), isTrue);
      expect(_identity(tester, find.text('Send from')), isTrue);
    });
  });

  group('primitives keep their resting state', () {
    testWidgets('empty state settles within the golden window', (tester) async {
      await tester.pumpWidget(
        _app(
          const NotionEmptyState(
            icon: Icons.inbox_outlined,
            title: 'Nothing',
            message: 'Here',
            action: NotionButton(label: 'Act', onPressed: null),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final finder in [
        find.byIcon(Icons.inbox_outlined),
        find.text('Nothing'),
        find.text('Here'),
        find.text('Act'),
      ]) {
        expect(_identity(tester, finder), isTrue);
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('icon button tweens its selected background', (tester) async {
      Widget build(bool selected) => _app(
        NotionIconButton(
          icon: Icons.push_pin_outlined,
          label: 'Pin',
          selected: selected,
          onPressed: () {},
        ),
      );
      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('AfterRouteTransition fades the child in after a push', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: NotionTheme.build(Brightness.dark),
          home: const Scaffold(
            body: AfterRouteTransition(child: Text('Instant')),
          ),
        ),
      );
      expect(_opacity(tester, find.text('Instant')), 1);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: AfterRouteTransition(child: Text('Heavy'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(_opacity(tester, find.text('Heavy')), 1);
    });
  });
}
