// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 11 regression suite for J's "this reaction isn't supported": every
// path that used to say "unsupported" while reacting, on a Telegram-like
// room whose bridge declares `allowed_reactions` the way
// mautrix-telegram does (`variationselector.Add`: 👍️ 👎️ ⚡️ 😐️ with
// U+FE0F). Fictional offline fixtures; no HTTP, no real messages.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/emoji/emoji_picker.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

const _vs = '\u{FE0F}';

/// Telegram's non-Premium reactions as the bridge declares them for a chat
/// that allows all (`getAvailableReactionsForCapability` +
/// `variationselector.Add`), abridged.
const _telegram = [
  '👍$_vs', '👎$_vs', '❤$_vs', '🔥', '🥰', '👏', '😁', '🤔', '🤯', '😱', //
  '🤬', '😢', '🎉', '🤩', '🤮', '💩', '🙏', '👌', '🕊$_vs', '🤡', //
  '😍', '🐳', '❤$_vs\u{200D}🔥', '💯', '🤣', '⚡$_vs', '🍌', '🏆', '💔', //
  '😐$_vs', '🍓', '🍾', '💋', '😈', '😴', '😭', '🤓', '👻', '👀', '🎃', //
  '🙈', '😇', '😨', '🤝', '✍$_vs', '🤗', '🫡', '🎅', '🎄', '☃$_vs', '💅', //
  '🤪', '🗿', '🆒', '💘', '🙉', '🦄', '😘', '💊', '🙊', '😎', '👾', '😡', //
];

class _OwnReaction extends Event {
  _OwnReaction(Event original, String key, {String id = r'$own-reaction'})
    : super(
        room: original.room,
        eventId: id,
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

  int removals = 0;

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

class _Fixture {
  _Fixture({
    Map<String, Object?>? features,
    bool declared = true,
    EventStatus status = EventStatus.synced,
    String id = r'$tg',
  }) {
    client = ConversationClient();
    room = ConversationRoom(client, '!tg:example.invalid', network: 'telegram');
    if (!declared) {
      room.states.remove(bridgeFeaturesEventType);
    } else {
      room.state(
        bridgeFeaturesEventType,
        features ??
            {
              'id': 'fi.mau.telegram.capabilities+reactions_any+any_list_x',
              'reply': 2,
              'reaction': 2,
              'reaction_count': 1,
              'allowed_reactions': _telegram,
            },
        key: 'fixture',
      );
    }
    event = room.message(id, 'Fictional Telegram message', status: status);
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

  void dispose() {
    timeline.cancelSubscriptions();
    scroll.dispose();
  }

  Future<void> mount(WidgetTester tester, {bool strict = false}) async {
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(client, AppSettings.store),
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Message(
                event,
                bigEmojis: const {},
                onInfoTab: (_) {},
                scrollToEventId: (_) {},
                onSwipe: () {},
                timeline: timeline,
                onMention: () {},
                scrollController: scroll,
                enterThread: null,
                strictCapabilities: strict,
                menuActions: (event) => [
                  ConversationMessageAction(
                    icon: Icons.reply_rounded,
                    label: 'Reply',
                    onSelected: () {},
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

  Future<bool> react(
    WidgetTester tester,
    String emoji, {
    bool toggle = false,
  }) => ConversationMessageActions.react(
    tester.element(find.byType(Message)),
    event,
    timeline,
    emoji,
    toggle: toggle,
  );
}

Finder _bar(String emoji) => find.byKey(ValueKey('reaction-$emoji'));
final _more = find.byKey(const ValueKey('reaction-more'));
Finder _cell(String glyph) => find.descendant(
  of: find.byType(NotionEmojiPicker),
  matching: find.bySemanticsLabel(glyph),
);

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(target);
  await tester.pump();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.swipeRightToLeftToReply.setItem(false);
  });
  setUp(() async {
    await AppSettings.doubleTapToReact.setItem(true);
    await AppSettings.doubleTapReaction.setItem('');
    await AppSettings.quickReactions.setItem('');
    await AppSettings.store.remove(EmojiRecents.key);
    EmojiRecents.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('root cause: spelling of allowed_reactions', () {
    test('the picker spelling of an allowed emoji is accepted', () {
      final f = _Fixture();
      addTearDown(f.dispose);
      // Before wave 11 every one of these said "This reaction isn't
      // supported in this chat." (exact match against 👍️ etc.).
      for (final picked in [
        '👍',
        '👎',
        '⚡',
        '😐',
        '✍️',
        '🕊️',
        '❤️',
        '❤️‍🔥',
      ]) {
        expect(
          ConversationMessageActions.canReact(f.event, f.timeline, picked),
          isTrue,
          reason: picked,
        );
      }
      expect(
        ConversationMessageActions.networkSpelling(f.room, '👍'),
        '👍$_vs',
      );
      expect(ConversationMessageActions.networkSpelling(f.room, '🔥'), '🔥');
      // Outside the network's set: refused, and never offered (below).
      expect(
        ConversationMessageActions.canReact(f.event, f.timeline, '😂'),
        isFalse,
      );
    });

    testWidgets('a picked 👍 goes out in the network spelling, no notice', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await f.react(tester, '👍');
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['👍$_vs']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('an own 👍 from before toggles off with the network 👍️', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final own = _OwnReaction(f.event, '👍');
      f.timeline.addAggregatedEvent(own);
      await f.mount(tester);
      await f.react(tester, '👍$_vs', toggle: true);
      await tester.pumpAndSettle();
      expect(own.removals, 1);
      expect(f.room.sentEmoji, isEmpty);
      // Not toggling: it is already given, nothing is sent twice.
      final again = _Fixture();
      addTearDown(again.dispose);
      again.timeline.addAggregatedEvent(_OwnReaction(again.event, '👍$_vs'));
      await again.mount(tester);
      await again.react(tester, '👍');
      await tester.pumpAndSettle();
      expect(again.room.sentEmoji, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('the picker offers exactly what the chat takes', () {
    test('choices are the network set in its order; "+" only for more', () {
      final f = _Fixture();
      addTearDown(f.dispose);
      expect(ConversationMessageActions.reactionChoices(f.room), _telegram);
      expect(ConversationMessageActions.hasMoreReactions(f.room), isTrue);
      final small = _Fixture(
        features: {
          'reaction': 2,
          'allowed_reactions': ['👍$_vs', '❤$_vs', 'mxc://example.invalid/x'],
        },
      );
      addTearDown(small.dispose);
      expect(ConversationMessageActions.reactionChoices(small.room), [
        '👍$_vs',
        '❤$_vs',
      ]);
      // Both are on the bar already: no "+" with nothing more behind it.
      expect(ConversationMessageActions.hasMoreReactions(small.room), isFalse);
      final any = _Fixture(features: {'reaction': 2});
      addTearDown(any.dispose);
      expect(ConversationMessageActions.reactionChoices(any.room), isNull);
      expect(ConversationMessageActions.hasMoreReactions(any.room), isTrue);
    });

    testWidgets('"+" grows into the chat\'s reactions; a pick reacts once', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      // The bar: the user's quick reactions the network has, its spelling.
      expect(_bar('❤$_vs'), findsOneWidget);
      expect(_bar('👍$_vs'), findsOneWidget);
      expect(_bar('😂'), findsNothing);
      await tester.tap(_more);
      await tester.pumpAndSettle();
      expect(find.byType(NotionEmojiPicker), findsOneWidget);
      expect(find.text('Reactions in this chat'), findsOneWidget);
      // Only what Telegram takes here; never 😂.
      expect(_cell('😂'), findsNothing);
      await tester.tap(_cell('⚡$_vs').first);
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['⚡$_vs']);
      expect(find.byType(NotionEmojiPicker), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search inside the expanded picker; Enter reacts', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      await tester.tap(_more);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('emoji-search')), 'lol');
      await tester.pumpAndSettle();
      // 😂 is not Telegram's; its "lol" neighbour 🤣 is.
      final state = tester.state<NotionEmojiPickerState>(
        find.byType(NotionEmojiPicker),
      );
      expect(state.results.map((e) => e.emoji), contains('🤣'));
      expect(state.results.map((e) => e.emoji), isNot(contains('😂')));
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, [state.results.first.emoji]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the expanded picker stays above the keyboard', (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      addTearDown(tester.view.reset);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      await tester.tap(_more);
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byKey(const ValueKey('emoji-search')));
      // A 300 pt keyboard (the fake view takes physical pixels).
      final ratio = tester.view.devicePixelRatio;
      tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
      await tester.pumpAndSettle();
      final screen = tester.view.physicalSize / ratio;
      final panel = tester.getRect(find.byType(NotionEmojiPicker));
      expect(panel.bottom, lessThanOrEqualTo(screen.height - 300));
      expect(panel.height, greaterThan(150));
      await tester.enterText(
        find.byKey(const ValueKey('emoji-search')),
        'fire',
      );
      await tester.pumpAndSettle();
      expect(_cell('🔥').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion: "+" opens the picker at once', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pump();
      await tester.tap(_more);
      await tester.pump();
      expect(find.byType(NotionEmojiPicker), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('any network: quick reactions on top, full set below', (
      tester,
    ) async {
      final f = _Fixture(features: {'reaction': 2, 'reaction_count': 1});
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      await tester.tap(_more);
      await tester.pumpAndSettle();
      expect(find.text('Quick reactions'), findsOneWidget);
      expect(find.text('Smileys & people'), findsOneWidget);
      await tester.tap(_cell('😂').first);
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['😂']);
      // Shared recents: the reaction is recent for every picker now.
      expect(EmojiRecents.emoji.first, '😂');
    });

    testWidgets('the sheet picker offers the same set', (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      final context = tester.element(find.byType(Message));
      final picked = showConversationReactionPicker(context, f.room);
      await tester.pumpAndSettle();
      expect(find.text('Reactions in this chat'), findsOneWidget);
      expect(_cell('😂'), findsNothing);
      await tester.tap(_cell('👍$_vs').first);
      await tester.pumpAndSettle();
      expect(await picked, '👍$_vs');
    });
  });

  group('no menu or gesture that only says "unsupported"', () {
    testWidgets('reactions turned off: no bar, no "+", double tap silent', (
      tester,
    ) async {
      final f = _Fixture(
        features: {
          'id': 'fi.mau.telegram.capabilities+reactions_none',
          'reply': 2,
          'reaction': -2,
        },
      );
      addTearDown(f.dispose);
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      expect(_more, findsNothing);
      expect(find.byType(NotionReactionBar), findsNothing);
      expect(find.text('Reply'), findsOneWidget);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      await _doubleTap(tester, find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      expect(f.room.reactionsSent, 0);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a message still sending: no bar, double tap silent', (
      tester,
    ) async {
      final f = _Fixture(id: 'local-echo', status: EventStatus.sending);
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      expect(f.room.reactionsSent, 0);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('unverified bridge: ordinary chats react, strict ones hide', (
      tester,
    ) async {
      final f = _Fixture(declared: false);
      addTearDown(f.dispose);
      expect(
        RoomCapabilities.forFeature(BridgeFeature.reaction, f.room).status,
        CapabilityStatus.unverified,
      );
      expect(ConversationMessageActions.canReactAtAll(f.event), isTrue);
      expect(
        ConversationMessageActions.canReactAtAll(f.event, strict: true),
        isFalse,
      );
      await f.mount(tester);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      await tester.tap(_bar('😂'));
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['😂']);
      expect(find.byType(SnackBar), findsNothing);
      // The merged chat (strict) offers no bar it could not keep.
      final merged = _Fixture(declared: false);
      addTearDown(merged.dispose);
      await merged.mount(tester, strict: true);
      await tester.longPress(find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      expect(find.byType(NotionReactionBar), findsNothing);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
    });

    testWidgets('slide-to-react on the bar reacts in the network spelling', (
      tester,
    ) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      final finger = await tester.startGesture(
        tester.getCenter(find.text('Fictional Telegram message')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      await finger.moveTo(tester.getCenter(_bar('👍$_vs')));
      await tester.pump();
      await finger.up();
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['👍$_vs']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('double tap reacts with the network\'s heart', (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.mount(tester);
      await _doubleTap(tester, find.text('Fictional Telegram message'));
      await tester.pumpAndSettle();
      expect(f.room.sentEmoji, ['❤$_vs']);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
