// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 13 conversation motion: a deleted bubble leaves (and can come back),
// an edited bubble glides to its new size, the reaction slot opens and
// closes, removed reaction chips pop out, the clock turns into the ✓ in
// place, and the keyboard's slide does not rebuild the bubbles. Fictional
// offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/events/message_reactions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

/// One theme for every pump: a new `ThemeData` per pump would make
/// `AnimatedTheme` tween (and rebuild) between equal-looking themes.
final _theme = NotionTheme.build(Brightness.dark);

Widget _app(
  Widget child, {
  bool reduced = false,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) => MaterialApp(
  theme: _theme,
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      disableAnimations: reduced,
      viewInsets: viewInsets,
    ),
    child: Scaffold(resizeToAvoidBottomInset: false, body: child),
  ),
);

double _height(WidgetTester tester, Finder finder) =>
    tester.getSize(finder).height;

Event _reaction(Event target, String id, String emoji, {String? sender}) =>
    Event(
      room: target.room,
      eventId: id,
      senderId: sender ?? target.room.client.userID!,
      originServerTs: DateTime.utc(2026, 1, 1, 9),
      type: EventTypes.Reaction,
      content: {
        'm.relates_to': {
          'rel_type': RelationshipTypes.reaction,
          'event_id': target.eventId,
          'key': emoji,
        },
      },
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('deleted message', () {
    Widget rows({bool reduced = false}) => _app(
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConversationMessageEntrance(
            identity: 'txn-gone',
            child: SizedBox(height: 40, child: Text('Bye')),
          ),
          SizedBox(height: 20, child: Text('Below')),
        ],
      ),
      reduced: reduced,
    );

    testWidgets('shrinks away, closes its slot and can come back', (
      tester,
    ) async {
      await tester.pumpWidget(rows());
      final row = find.byType(ConversationMessageEntrance);
      expect(_height(tester, row), 40);
      final exit = ConversationMessageEntrance.leave([r'$gone', 'txn-gone']);
      expect(exit, isNotNull);
      var done = false;
      exit!.then((_) => done = true);
      await tester.pump();
      await tester.pump(ConversationMotion.departure ~/ 2);
      final mid = _height(tester, row);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(40));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(_height(tester, row), 0);
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('Bye'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        0,
      );
      // A failed deletion puts it back at rest.
      ConversationMessageEntrance.restore(['txn-gone']);
      await tester.pump();
      expect(_height(tester, row), 40);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('nothing on screen or reduced motion: removed at once', (
      tester,
    ) async {
      expect(ConversationMessageEntrance.leave(['not-shown']), isNull);
      await tester.pumpWidget(rows(reduced: true));
      expect(ConversationMessageEntrance.leave(['txn-gone']), isNull);
      expect(_height(tester, find.byType(ConversationMessageEntrance)), 40);
    });

    testWidgets('a row that goes away mid-exit still finishes the exit', (
      tester,
    ) async {
      await tester.pumpWidget(rows());
      var done = false;
      ConversationMessageEntrance.leave(['txn-gone'])!.then((_) => done = true);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(_app(const SizedBox.shrink()));
      await tester.pump();
      expect(done, isTrue);
      expect(ConversationMessageEntrance.leave(['txn-gone']), isNull);
    });
  });

  group('ConversationContentMorph', () {
    Widget morph(Object revision, Size size, {bool reduced = false}) => _app(
      Align(
        alignment: Alignment.topLeft,
        child: ConversationContentMorph(
          revision: revision,
          child: SizedBox.fromSize(size: size, child: const Text('Body')),
        ),
      ),
      reduced: reduced,
    );

    final box = find.byType(ConversationContentMorph);

    testWidgets('an edit glides to the new size; other rebuilds snap', (
      tester,
    ) async {
      await tester.pumpWidget(morph('v1', const Size(100, 20)));
      expect(tester.hasRunningAnimations, isFalse);
      // Same revision (decryption, a status change): no motion.
      await tester.pumpWidget(morph('v1', const Size(120, 24)));
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.getSize(box), const Size(120, 24));
      // The edit: from the old size to the new one, never past it.
      await tester.pumpWidget(morph('v2', const Size(200, 64)));
      expect(tester.getSize(box), const Size(120, 24));
      await tester.pump(ConversationMotion.contentMorph ~/ 3);
      final mid = tester.getSize(box);
      expect(mid.width, inExclusiveRange(120, 200));
      expect(mid.height, inExclusiveRange(24, 64));
      await tester.pumpAndSettle();
      expect(tester.getSize(box), const Size(200, 64));
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: box, matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, 1);
      // A deletion that shrinks the bubble glides down the same way.
      await tester.pumpWidget(morph('deleted', const Size(90, 20)));
      await tester.pump(ConversationMotion.contentMorph ~/ 3);
      expect(tester.getSize(box).width, inExclusiveRange(90, 200));
      await tester.pumpAndSettle();
      expect(tester.getSize(box), const Size(90, 20));
    });

    testWidgets('reduced motion snaps', (tester) async {
      await tester.pumpWidget(morph('v1', const Size(100, 20), reduced: true));
      await tester.pumpWidget(morph('v2', const Size(200, 64), reduced: true));
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.getSize(box), const Size(200, 64));
    });
  });

  group('ConversationBubble', () {
    testWidgets('the keyboard slide does not rebuild the bubble', (
      tester,
    ) async {
      var builds = 0;
      // One instance, as the gated timeline hands it down: only a
      // dependency of the bubble itself could rebuild it.
      final message = ConversationBubble(
        outgoing: false,
        body: const Text('Hello'),
        surfaceBuilder: (surface) {
          builds++;
          return surface;
        },
      );
      Widget bubble(double keyboard) =>
          _app(message, viewInsets: EdgeInsets.only(bottom: keyboard));
      await tester.pumpWidget(bubble(0));
      final first = builds;
      for (final inset in [40.0, 120.0, 280.0]) {
        await tester.pumpWidget(bubble(inset));
      }
      expect(builds, first);
      // The message text still gets the message text scale.
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('Hello'))),
        isA<NotionMessageTextScaler>(),
      );
    });

    testWidgets('the reaction slot opens and closes; a first build is still', (
      tester,
    ) async {
      Widget bubble(Widget? reactions) => _app(
        Align(
          alignment: Alignment.topCenter,
          child: ConversationBubble(
            outgoing: true,
            body: const Text('Hello'),
            reactions: reactions,
          ),
        ),
      );
      final row = find.byType(ConversationBubble);
      await tester.pumpWidget(bubble(null));
      final bare = _height(tester, row);
      const chip = SizedBox(height: 28, width: 40, child: Text('chip'));
      await tester.pumpWidget(bubble(chip));
      await tester.pump(NotionMotion.medium ~/ 3);
      final opening = _height(tester, row);
      await tester.pumpAndSettle();
      final open = _height(tester, row);
      expect(open, greaterThan(bare));
      expect(opening, inExclusiveRange(bare, open));
      // Gone: the chips stay while the slot closes, then the row is bare.
      await tester.pumpWidget(bubble(null));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('chip'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('chip'), findsNothing);
      expect(_height(tester, row), bare);
      // A row built with reactions (history, scrolling) is open at once.
      await tester.pumpWidget(_app(const SizedBox.shrink()));
      await tester.pumpWidget(bubble(chip));
      expect(tester.hasRunningAnimations, isFalse);
      expect(_height(tester, row), open);
    });
  });

  group('reaction chips', () {
    Future<({Event event, Timeline timeline, Widget Function() view})> setUp(
      WidgetTester tester, {
      bool reduced = false,
    }) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!chips:example.invalid');
      final event = room.message(r'$chips-message', 'Fictional text');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(timeline.cancelSubscriptions);
      timeline.addAggregatedEvent(_reaction(event, r'$up', '👍'));
      timeline.addAggregatedEvent(
        _reaction(event, r'$heart', '❤️', sender: '@anna:example.invalid'),
      );
      Widget view() => Provider<MatrixState>.value(
        value: ConversationMatrix(client, AppSettings.store),
        child: _app(MessageReactions(event, timeline), reduced: reduced),
      );
      await tester.pumpWidget(view());
      return (event: event, timeline: timeline, view: view);
    }

    testWidgets('a removed chip pops out in place, then the row closes', (
      tester,
    ) async {
      final f = await setUp(tester);
      expect(tester.hasRunningAnimations, isFalse, reason: 'history is still');
      expect(find.text('❤️'), findsOneWidget);
      f.timeline.aggregatedEvents[f.event.eventId]![RelationshipTypes.reaction]!
          .removeWhere((e) => e.eventId == r'$heart');
      await tester.pumpWidget(f.view());
      // Still there, popping out and no longer tappable.
      expect(find.text('❤️'), findsOneWidget);
      final pop = tester.widget<NotionPop>(
        find.ancestor(of: find.text('❤️'), matching: find.byType(NotionPop)),
      );
      expect(pop.visible, isFalse);
      await tester.pumpAndSettle();
      expect(find.text('❤️'), findsNothing);
      expect(find.text('👍'), findsOneWidget);
    });

    testWidgets('reduced motion removes it at once', (tester) async {
      final f = await setUp(tester, reduced: true);
      f.timeline.aggregatedEvents[f.event.eventId]![RelationshipTypes.reaction]!
          .removeWhere((e) => e.eventId == r'$heart');
      await tester.pumpWidget(f.view());
      expect(find.text('❤️'), findsNothing);
    });
  });

  group('NotionDeliveryTick', () {
    Icon? icon(WidgetTester tester, IconData glyph) {
      final found = find.byIcon(glyph);
      return found.evaluate().isEmpty ? null : tester.widget<Icon>(found);
    }

    testWidgets('a fast send goes from nothing to a ✓ that grows in', (
      tester,
    ) async {
      Widget tick(NotionDeliveryState state) => _app(
        Center(
          child: NotionDeliveryTick(
            state: state,
            sendingClock: NotionSendingClock.delayed,
          ),
        ),
      );
      await tester.pumpWidget(tick(NotionDeliveryState.sending));
      await tester.pump(const Duration(milliseconds: 100));
      expect(icon(tester, Icons.schedule), isNull, reason: 'loader grace');
      final switcher = tester.state(find.byType(NotionLazySwitcher));
      final before = NotionLazySwitcher.debugControllers;
      await tester.pumpWidget(tick(NotionDeliveryState.sent));
      expect(NotionLazySwitcher.debugControllers, greaterThan(before));
      await tester.pump(const Duration(milliseconds: 30));
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.byIcon(Icons.done),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(scale.scale.value, lessThan(1));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(NotionLazySwitcher)), same(switcher));
      expect(icon(tester, Icons.done), isNotNull);
      expect(icon(tester, Icons.schedule), isNull);
      expect(
        tester.getSize(find.byType(NotionDeliveryTick)),
        const Size.square(NotionDeliveryTick.defaultSize),
      );
    });

    testWidgets('a slow send shows the clock after the grace', (tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: NotionDeliveryTick(
              state: NotionDeliveryState.sending,
              sendingClock: NotionSendingClock.delayed,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(icon(tester, Icons.schedule), isNotNull);
    });

    testWidgets('an upload keeps the slot but shows no clock', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          const Center(
            child: NotionDeliveryTick(
              state: NotionDeliveryState.sending,
              sendingClock: NotionSendingClock.hidden,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(icon(tester, Icons.schedule), isNull);
      expect(find.bySemanticsLabel('Sending'), findsOneWidget);
      expect(
        tester.getSize(find.byType(NotionDeliveryTick)),
        const Size.square(NotionDeliveryTick.defaultSize),
      );
      semantics.dispose();
    });

    testWidgets('read only fades the colour, without a morph', (tester) async {
      Widget tick(NotionDeliveryState state) =>
          _app(Center(child: NotionDeliveryTick(state: state)));
      await tester.pumpWidget(tick(NotionDeliveryState.delivered));
      await tester.pumpWidget(tick(NotionDeliveryState.read));
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        find.descendant(
          of: find.byType(NotionDeliveryTick),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
