import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: child),
  ),
);

Align _slot(WidgetTester tester, String text) => tester.widget<Align>(
  find.ancestor(of: find.text(text), matching: find.byType(Align)).first,
);

double _opacity(WidgetTester tester, String text) => tester
    .widget<Opacity>(
      find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  group('ConversationMessageEntrance', () {
    testWidgets('a new message grows its slot and settles to identity', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const ConversationMessageEntrance(
            identity: 'new',
            animate: true,
            outgoing: true,
            child: SizedBox(height: 40, child: Text('Fresh')),
          ),
        ),
      );
      // The slot starts collapsed, so older rows glide instead of jumping.
      expect(_slot(tester, 'Fresh').heightFactor, lessThan(.05));
      expect(_opacity(tester, 'Fresh'), lessThan(.05));
      await tester.pump(ConversationMotion.arrival ~/ 2);
      final mid = _slot(tester, 'Fresh').heightFactor!;
      expect(mid, greaterThan(.5));
      expect(mid, lessThan(1));
      await tester.pumpAndSettle();
      expect(_slot(tester, 'Fresh').heightFactor, 1);
      expect(_opacity(tester, 'Fresh'), 1);
      expect(
        tester.getSize(find.byType(ConversationMessageEntrance)).height,
        40,
      );
      final scale = tester.widget<Transform>(
        find
            .ancestor(of: find.text('Fresh'), matching: find.byType(Transform))
            .first,
      );
      expect(scale.transform.isIdentity(), isTrue);
    });

    testWidgets('reduced motion shows a new message at once', (tester) async {
      await tester.pumpWidget(
        _app(
          const ConversationMessageEntrance(
            identity: 'new',
            animate: true,
            child: Text('Instant'),
          ),
          reduced: true,
        ),
      );
      expect(tester.hasRunningAnimations, isFalse);
      expect(_slot(tester, 'Instant').heightFactor, 1);
      expect(_opacity(tester, 'Instant'), 1);
    });

    testWidgets('the first screenful staggers once; later rows are still', (
      tester,
    ) async {
      final rows = ValueNotifier<int>(3);
      addTearDown(rows.dispose);
      await tester.pumpWidget(
        _app(
          ConversationEntranceScope(
            child: ValueListenableBuilder<int>(
              valueListenable: rows,
              builder: (context, count, _) => Column(
                children: [
                  for (var i = 0; i < count; i++)
                    ConversationMessageEntrance(
                      key: ValueKey(i),
                      identity: i,
                      child: Text('Row $i'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      // Bottom-up stagger: the first claimed row is ahead of the third.
      expect(
        _opacity(tester, 'Row 0'),
        greaterThanOrEqualTo(_opacity(tester, 'Row 2')),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        expect(_opacity(tester, 'Row $i'), 1);
      }
      // A row built later (scrolling, history) appears without animation.
      rows.value = 4;
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(_opacity(tester, 'Row 3'), 1);
    });
  });

  testWidgets('a held bubble sinks and springs back on release', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Center(
          child: ConversationPressScale(
            child: SizedBox(width: 120, height: 60, child: Text('Held')),
          ),
        ),
      ),
    );
    double scale() => tester
        .widget<Transform>(
          find
              .ancestor(of: find.text('Held'), matching: find.byType(Transform))
              .first,
        )
        .transform
        .entry(0, 0);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Held')),
    );
    // A quick tap shows nothing yet.
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(), closeTo(1, .002));
    await tester.pump(const Duration(milliseconds: 500));
    expect(scale(), closeTo(NotionMotion.pressButton, .005));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), 1);
  });

  testWidgets('selection tween reaches the target and stays exact', (
    tester,
  ) async {
    Widget tween(double value) => _app(
      ConversationLazyTween(
        value: value,
        builder: (context, t, _) => Text('t=$t'),
      ),
    );
    await tester.pumpWidget(tween(0));
    expect(find.text('t=0.0'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(tween(1));
    await tester.pump(NotionMotion.quick ~/ 2);
    expect(find.text('t=1.0'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('t=1.0'), findsOneWidget);
  });

  testWidgets('a swapped slot pops in, an ordinary rebuild does not', (
    tester,
  ) async {
    Widget slot(String key) =>
        _app(ConversationSlotMorph(child: Text(key, key: ValueKey(key))));
    await tester.pumpWidget(slot('avatar'));
    await tester.pumpWidget(slot('avatar'));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(slot('check'));
    expect(tester.hasRunningAnimations, isTrue);
    expect(_opacity(tester, 'check'), lessThan(.2));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'check'), 1);
  });

  group('send button', () {
    testWidgets('springs when it turns enabled and ticks on send', (
      tester,
    ) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var sends = 0;
      await tester.pumpWidget(_app(const NotionSendButton()));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(_app(NotionSendButton(onPressed: () => sends++)));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets('busy morphs the arrow into a spinner', (tester) async {
      await tester.pumpWidget(_app(NotionSendButton(onPressed: () {})));
      await tester.pumpWidget(
        _app(NotionSendButton(busy: true, onPressed: () {})),
      );
      await tester.pump(const Duration(milliseconds: 40));
      // Both glyphs share the slot mid-morph.
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  testWidgets('composer morphs between mic and send', (tester) async {
    Widget composer(Widget primary) => _app(
      CompactComposer(
        input: const TextField(),
        source: const SizedBox.shrink(),
        addAction: const SizedBox.shrink(),
        primaryAction: primary,
      ),
    );
    await tester.pumpWidget(
      composer(
        IconButton(
          key: const ValueKey('voice'),
          onPressed: () {},
          icon: const Icon(Icons.mic_none),
        ),
      ),
    );
    await tester.pumpWidget(
      composer(NotionSendButton(key: const ValueKey('send'), onPressed: () {})),
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('send_button'))),
      const Size(48, 48),
    );
  });

  testWidgets('a revealed bar keeps its last content while it collapses', (
    tester,
  ) async {
    Widget reveal(Widget? child) => _app(ConversationReveal(child: child));
    await tester.pumpWidget(reveal(const Text('Playing')));
    expect(find.text('Playing'), findsOneWidget);
    await tester.pumpWidget(reveal(null));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('Playing'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Playing'), findsNothing);
  });
}
