// SPDX-License-Identifier: AGPL-3.0-or-later
// Long-press menu, quick reactions, double tap and swipe on fictional
// offline fixtures. No HTTP, no account storage, no real messages.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

/// An own reaction already in the timeline; counts its removals.
class _OwnReaction extends Event {
  int removals = 0;
  _OwnReaction(Event original, String key)
    : super(
        room: original.room,
        eventId: r'$own-reaction',
        senderId: original.room.client.userID!,
        originServerTs: DateTime.utc(2026),
        type: EventTypes.Reaction,
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': original.eventId,
            'key': key,
          },
        },
      );

  @override
  Future<String?> redactEvent({
    String? reason,
    String? txid,
    bool redactAllEdits = false,
  }) async {
    removals++;
    return r'$redacted';
  }
}

void _allowReactions(ConversationRoom room, List<String> allowed) => room.state(
  bridgeFeaturesEventType,
  {'reply': 2, 'reaction': 2, 'allowed_reactions': allowed},
  key: 'fixture',
);

class _Fixture {
  _Fixture({List<String>? allowed, Map<String, dynamic>? content}) {
    client = ConversationClient();
    room = ConversationRoom(client, '!menu:example.invalid');
    if (allowed != null) _allowReactions(room, allowed);
    event = room.message(r'$menu', 'Fictional menu message', content: content);
    timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
  }

  late final ConversationClient client;
  late final ConversationRoom room;
  late final Event event;
  late final Timeline timeline;
  final scroll = ScrollController();
  var replies = 0;
  final selected = <String>[];

  void dispose() {
    timeline.cancelSubscriptions();
    scroll.dispose();
  }

  Future<void> mount(
    WidgetTester tester, {
    bool reduced = false,
    List<ConversationMessageAction> Function(Event event)? actions,
  }) async {
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(client, AppSettings.store),
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Message(
                event,
                bigEmojis: const {},
                onInfoTab: (_) {},
                scrollToEventId: (_) {},
                onSwipe: () => replies++,
                timeline: timeline,
                onMention: () {},
                scrollController: scroll,
                enterThread: null,
                menuActions:
                    actions ??
                    (event) => [
                      ConversationMessageAction(
                        icon: Icons.reply_rounded,
                        label: 'Reply',
                        onSelected: () => selected.add('reply'),
                      ),
                      ConversationMessageAction(
                        icon: Icons.delete_outlined,
                        label: 'Delete',
                        destructive: true,
                        onSelected: () => selected.add('delete'),
                      ),
                    ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder _emoji(String emoji) => find.byKey(ValueKey('reaction-$emoji'));

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(target);
  await tester.pump();
}

void main() {
  final haptics = <Object?>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.swipeRightToLeftToReply.setItem(false);
  });
  setUp(() async {
    haptics.clear();
    await AppSettings.doubleTapToReact.setItem(true);
    await AppSettings.doubleTapReaction.setItem('');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('quick reactions', () {
    test(
      'Messenger order with the heart first when the network allows any',
      () {
        final f = _Fixture();
        addTearDown(f.dispose);
        expect(ConversationMessageActions.quickReactions(f.room), [
          '❤️',
          '😂',
          '😮',
          '😢',
          '😡',
          '👍',
        ]);
        expect(ConversationMessageActions.doubleTapReaction(f.room), '❤️');
      },
    );

    test('allowed_reactions keep our order in the network spelling', () {
      final f = _Fixture(allowed: ['👍', '👎', '❤', '🔥', '😢']);
      addTearDown(f.dispose);
      expect(ConversationMessageActions.quickReactions(f.room), [
        '❤',
        '😢',
        '👍',
      ]);
      // The heart without the presentation selector, as the network has it.
      expect(ConversationMessageActions.doubleTapReaction(f.room), '❤');
    });

    test('no match falls back to the network order; no heart, first one', () {
      final none = _Fixture(allowed: ['🔥', '🎉', 'mxc://example.invalid/x']);
      addTearDown(none.dispose);
      expect(ConversationMessageActions.quickReactions(none.room), [
        '🔥',
        '🎉',
      ]);
      expect(ConversationMessageActions.doubleTapReaction(none.room), '🔥');
      final thumbs = _Fixture(allowed: ['👍', '🔥']);
      addTearDown(thumbs.dispose);
      expect(ConversationMessageActions.doubleTapReaction(thumbs.room), '👍');
    });

    test(
      'an explicitly picked emoji wins only where the network has it',
      () async {
        await AppSettings.doubleTapReaction.setItem('🔥');
        final any = _Fixture();
        final telegram = _Fixture(allowed: ['👍', '❤', '🔥']);
        final limited = _Fixture(allowed: ['👍', '❤']);
        addTearDown(any.dispose);
        addTearDown(telegram.dispose);
        addTearDown(limited.dispose);
        expect(ConversationMessageActions.doubleTapReaction(any.room), '🔥');
        expect(
          ConversationMessageActions.doubleTapReaction(telegram.room),
          '🔥',
        );
        expect(ConversationMessageActions.doubleTapReaction(limited.room), '❤');
        expect(AppSettings.doubleTapReaction.defaultValue, isEmpty);
        expect(AppSettings.doubleTapToReact.defaultValue, isTrue);
      },
    );
  });

  testWidgets(
    'long-press opens the overlay: quick reactions, the host actions, no selection',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      // Android long-press buzz: HapticFeedback.vibrate() has no arguments.
      expect(haptics, [null]);
      for (final emoji in NotionReactions.defaults) {
        expect(_emoji(emoji), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('reaction-more')), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // Nothing of the old selection mode: no check circles, no count, no
      // selection tint, no reaction row inside the footer.
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
      expect(find.byTooltip('React 👍'), findsNothing);
      // The list bubble stays where it is; the overlay draws a copy.
      expect(find.text('Fictional menu message'), findsOneWidget);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(f.selected, ['reply']);
      expect(_emoji('❤️'), findsNothing);
      expect(f.room.reactionsSent, 0);
    },
  );

  testWidgets('choosing an emoji reacts once and closes the overlay', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.mount(tester);
    await tester.longPress(find.text('Fictional menu message'));
    await tester.pumpAndSettle();
    await tester.tap(_emoji('😂'));
    await tester.pumpAndSettle();
    expect(f.room.sentEmoji, ['😂']);
    expect(_emoji('😂'), findsNothing);
    expect(f.selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slide to react: release over an emoji while still holding', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.mount(tester);
    final finger = await tester.startGesture(
      tester.getCenter(find.text('Fictional menu message')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(_emoji('😮'), findsOneWidget);
    await finger.moveTo(tester.getCenter(_emoji('😮')));
    await tester.pump();
    await tester.pumpAndSettle();
    await finger.up();
    await tester.pumpAndSettle();
    expect(f.room.sentEmoji, ['😮']);
    expect(_emoji('😮'), findsNothing);
  });

  testWidgets(
    'releasing away from the bar keeps the menu; a scroll closes it',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      final finger = await tester.startGesture(
        tester.getCenter(find.text('Fictional menu message')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      await finger.up();
      await tester.pumpAndSettle();
      expect(_emoji('❤️'), findsOneWidget);
      // A drag on the scrim is a scroll attempt.
      await tester.dragFrom(const Offset(400, 80), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(_emoji('❤️'), findsNothing);
      expect(f.room.reactionsSent, 0);
      // Back dismisses as well.
      await tester.longPress(find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(_emoji('❤️'), findsOneWidget);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.maybePop();
      await tester.pumpAndSettle();
      expect(_emoji('❤️'), findsNothing);
      expect(f.room.reactionsSent, 0);
    },
  );

  testWidgets(
    'own reactions are marked in the bar and choosing one removes it',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final own = _OwnReaction(f.event, '❤️');
      f.timeline.addAggregatedEvent(own);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      final heart = tester.widget<Semantics>(
        find
            .descendant(of: _emoji('❤️'), matching: find.byType(Semantics))
            .first,
      );
      expect(heart.properties.selected, isTrue);
      await tester.tap(_emoji('❤️'));
      await tester.pumpAndSettle();
      expect(own.removals, 1);
      expect(f.room.reactionsSent, 0);
    },
  );

  testWidgets('reduced motion opens and closes the same overlay instantly', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.mount(tester, reduced: true);
    await tester.longPress(find.text('Fictional menu message'));
    await tester.pump();
    expect(_emoji('❤️'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();
    expect(f.selected, ['delete']);
    expect(_emoji('❤️'), findsNothing);
  });

  group('double tap', () {
    testWidgets('reacts with the first quick reaction and toggles it off', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['❤️']);
      // The burst played at the finger and is gone again.
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(find.byType(NotionReactionBurst), findsNothing);
      // Once the network echoed the heart, a second double tap removes it.
      final own = _OwnReaction(f.event, '❤️');
      f.timeline.addAggregatedEvent(own);
      await f.mount(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await _doubleTap(tester, find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(own.removals, 1);
      expect(f.room.sentEmoji, ['❤️']);
    });

    testWidgets('uses the network spelling where allowed_reactions apply', (
      tester,
    ) async {
      final f = _Fixture(allowed: ['👍', '❤', '🔥']);
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['❤']);
    });

    testWidgets('a network without hearts gets its first reaction', (
      tester,
    ) async {
      final f = _Fixture(allowed: ['🔥', '👏']);
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['🔥']);
    });

    testWidgets('turned off in the settings, double tap does nothing', (
      tester,
    ) async {
      await AppSettings.doubleTapToReact.setItem(false);
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional menu message'));
      await tester.pumpAndSettle();
      expect(f.room.reactionsSent, 0);
    });
  });

  testWidgets('swipe replies on an image message', (tester) async {
    await AppSettings.showThumbnailsInTimeline.setItem(false);
    addTearDown(() => AppSettings.showThumbnailsInTimeline.setItem(true));
    final f = _Fixture(
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'fictional.png',
        'url': 'mxc://example.invalid/fictional',
        'info': {'w': 400, 'h': 300, 'mimetype': 'image/png'},
      },
    );
    addTearDown(f.dispose);
    await f.mount(tester);
    final image = find.byType(InkWell).first;
    final drag = await tester.startGesture(tester.getCenter(image));
    await drag.moveBy(const Offset(24, 0));
    await drag.moveBy(const Offset(70, 0));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(f.replies, 1);
    expect(f.room.reactionsSent, 0);
  });

  testWidgets('menu card and bar are glass panels; chips are pills', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.timeline.addAggregatedEvent(_OwnReaction(f.event, '👍'));
    await f.mount(tester);
    final chip = find.byType(NotionReactionChip);
    expect(chip, findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(of: chip, matching: find.byType(Material)).first,
    );
    expect(material.shape, isA<StadiumBorder>());
    // The chip overlaps the bubble's bottom edge.
    final bubble = tester.getRect(
      find
          .ancestor(
            of: find.text('Fictional menu message'),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(tester.getRect(chip).top, lessThan(bubble.bottom));
    await tester.longPress(find.text('Fictional menu message'));
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPanel), findsNWidgets(2));
  });
}
