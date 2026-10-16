import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/compact_composer.dart';
import 'package:fluffychat/pages/chat/conversation_message_gestures.dart';
import 'package:fluffychat/pages/chat/events/message.dart';
import 'package:fluffychat/pages/chat/events/message_content.dart';
import 'package:fluffychat/pages/chat/events/reply_content.dart';
import 'package:fluffychat/pages/chat/conversation_bubble.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/chat_input_row.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:fluffychat/personal/merged_chat_page.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'conversation_test_support.dart';

Future<ConversationMatrix> mountConversation(
  WidgetTester tester,
  Widget child,
  ConversationClient client,
) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

PersonGroup group(
  ConversationPersonal p,
  ConversationRoom a,
  ConversationRoom b,
) => PersonGroup(
  id: 'fixture-person',
  name: 'Anna',
  members: [p.ref(a), p.ref(b)],
  defaultRoomId: a.id,
);

class _ComposerController extends ChatController {
  final Room source;
  int emojiOpens = 0;
  _ComposerController(this.source) {
    sendingClient = source.client;
    inputFocus = FocusNode();
  }
  @override
  Room get room => source;
  @override
  bool get canRecordRoundSilently => false;
  @override
  void onInputBarChanged(String text) {}
  @override
  void emojiPickerAction() {
    emojiOpens++;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.doubleTapToReact.setItem(true);
    await AppSettings.swipeRightToLeftToReply.setItem(false);
  });
  testWidgets(
    'ordinary production presenter moves whole bubble and invokes real reply callback once',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!ordinary:example.invalid');
      final event = room.message(r'$ordinary', 'Fictional ordinary message');
      final t = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      final scroll = ScrollController();
      addTearDown(t.cancelSubscriptions);
      addTearDown(scroll.dispose);
      var replies = 0;
      var infoTaps = 0;
      await mountConversation(
        tester,
        Scaffold(
          body: Message(
            event,
            bigEmojis: const {},
            onSelect: (_) {},
            onInfoTab: (_) {
              infoTaps++;
            },
            scrollToEventId: (_) {},
            onSwipe: () => replies++,
            onEdit: () {},
            singleSelected: false,
            timeline: t,
            onMention: () {},
            scrollController: scroll,
            colors: const [Colors.grey, Colors.grey],
            enterThread: null,
          ),
        ),
        client,
      );
      final text = find.text('Fictional ordinary message');
      final before = tester.getTopLeft(text);
      final drag = await tester.startGesture(tester.getCenter(text));
      await drag.moveBy(const Offset(24, 0));
      await drag.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(tester.getTopLeft(text).dx, greaterThan(before.dx + 40));
      final fill = find
          .ancestor(of: text, matching: find.byType(ClipRRect))
          .first;
      expect(tester.getTopLeft(fill).dx, greaterThan(before.dx - 13 + 40));
      await drag.up();
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(room.reactionsSent, 0);
      expect(tester.getTopLeft(text).dx, closeTo(before.dx, .1));
      await tester.tap(text, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(text, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(infoTaps, 0);
      expect(room.reactionsSent, 0);
    },
  );
  testWidgets(
    'merged source picker preserves draft and swipe reply locks send to original source',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!one:example.invalid');
      final b = ConversationRoom(client, '!two:example.invalid');
      final original = a.message(
        r'$original',
        'Reply to this fictional message',
      );
      b.message(r'$other', 'Another source', minute: 41);
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      await mountConversation(
        tester,
        MergedChatPage(personal: personal, group: group(personal, a, b)),
        client,
      );
      await tester.enterText(find.byType(TextField), 'Draft remains');
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      editable.controller.value = editable.controller.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 4),
        composing: const TextRange(start: 0, end: 4),
      );
      await tester.pump();
      final value = editable.controller.value;
      await tester.tap(find.byType(ConversationSourceChip));
      await tester.pumpAndSettle();
      // Same-network rooms remain two distinct full-identity choices.
      expect(find.text('Fictional conversation'), findsNWidgets(2));
      expect(find.text('Current account · Source 1'), findsOneWidget);
      expect(find.text('Current account · Source 2'), findsOneWidget);
      await tester.tap(find.text('Fictional conversation').last);
      await tester.pumpAndSettle();
      expect(editable.controller.value, value);
      expect(personal.drafts.last.target.conversation, personal.ref(b));
      // Use the production wrapper's callback, which dispatches _action(reply).
      final gesture = tester
          .widgetList<ConversationMessageGestures>(
            find.byType(ConversationMessageGestures),
          )
          .firstWhere((w) => w.identity == personal.source(original).key);
      gesture.onReply!();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ConversationSourceChip>(find.byType(ConversationSourceChip))
            .locked,
        isTrue,
      );
      expect(personal.drafts.last.target.conversation, personal.ref(a));
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      expect(personal.sends.single.room, same(a));
      expect(personal.sends.single.reply, same(original));
      expect(personal.sends.single.text, 'Draft remains');
      expect(editable.controller.text, isEmpty);
    },
  );
  testWidgets(
    'merged unavailable source can recover; stale picker account cannot alter draft',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!missing:example.invalid');
      final b = ConversationRoom(client, '!healthy:example.invalid');
      a.message(r'$a', 'A');
      b.message(r'$b', 'B');
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      final g = group(personal, a, b);
      personal.values['draft:person:${g.id}'] = {
        'text': 'Kept draft',
        'target': SendTarget(conversation: personal.ref(a)).toJson(),
      };
      client.rooms.remove(a);
      final matrix = await mountConversation(
        tester,
        MergedChatPage(personal: personal, group: g),
        client,
      );
      await tester.tap(find.byType(ConversationSourceChip));
      await tester.pumpAndSettle();
      expect(find.text('Send via'), findsOneWidget);
      matrix.active = ConversationClient('@changed:example.invalid');
      await tester.tap(find.text('Fictional conversation'));
      await tester.pumpAndSettle();
      expect(personal.drafts, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Kept draft',
      );
      matrix.active = client;
      await tester.tap(find.byType(ConversationSourceChip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fictional conversation'));
      await tester.pumpAndSettle();
      expect(personal.drafts.last.target.conversation, personal.ref(b));
      expect(personal.drafts.last.text, 'Kept draft');
    },
  );
  testWidgets(
    'merged rejection retains text and reply; cancelling reply preserves editor',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!reject-a:example.invalid');
      final b = ConversationRoom(client, '!reject-b:example.invalid');
      final original = a.message(r'$a', 'Fictional reply source');
      final personal = ConversationPersonal(client)
        ..sendState = ImmediateSendState.failed;
      addTearDown(personal.dispose);
      await mountConversation(
        tester,
        MergedChatPage(personal: personal, group: group(personal, a, b)),
        client,
      );
      await tester.enterText(find.byType(TextField), 'Keep after rejection');
      tester
          .widgetList<ConversationMessageGestures>(
            find.byType(ConversationMessageGestures),
          )
          .firstWhere((w) => w.identity == personal.source(original).key)
          .onReply!();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep after rejection',
      );
      expect(
        tester
            .widget<ConversationSourceChip>(find.byType(ConversationSourceChip))
            .locked,
        isTrue,
      );
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ConversationSourceChip>(find.byType(ConversationSourceChip))
            .locked,
        isFalse,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep after rejection',
      );
    },
  );
  testWidgets(
    'ordinary plus exposes schedule/media/emoji and dismisses before dispatch',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!input:example.invalid');
      final controller = _ComposerController(room);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/wakelock'),
        (_) async => null,
      );
      await mountConversation(
        tester,
        Scaffold(body: ChatInputRow(controller)),
        client,
      );
      await tester.tap(find.byTooltip('More message actions'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Attach media or a file'), findsOneWidget);
      expect(find.byTooltip('Schedule a message'), findsOneWidget);
      await tester.tap(find.byTooltip('Schedule a message'));
      await tester.pumpAndSettle();
      expect(find.text('Schedule text'), findsOneWidget);
      expect(find.text('Schedule an attachment'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Emoji picker'));
      await tester.pumpAndSettle();
      expect(controller.emojiOpens, 1);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.sendController.dispose();
      controller.inputFocus.dispose();
      controller.scrollController.dispose();
    },
  );
  testWidgets(
    'light outgoing quote has readable sender and source text contrast',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!quote-contrast:example.invalid');
      final event = room.message(r'$quote-contrast', 'Fictional quote body');
      late Color surface;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.light),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                surface = ConversationBubbleColors.of(context).outgoing;
                return ColoredBox(
                  color: surface,
                  child: ReplyContent(event, ownMessage: true),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in ['Anna:', 'Fictional quote body']) {
        final color = tester.widget<Text>(find.text(text)).style!.color!;
        final a = surface.computeLuminance(), b = color.computeLuminance();
        expect(
          ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );
  testWidgets(
    'merged private palette preserves direction and readable source content',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!palette-a:example.invalid');
      final b = ConversationRoom(client, '!palette-b:example.invalid');
      a.message(r'$palette-in', 'Incoming custom palette');
      a.message(
        r'$palette-out',
        'Outgoing custom palette',
        outgoing: true,
        minute: 41,
      );
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      final g = group(personal, a, b);
      personal.values['org:person:${g.id}'] = {
        'theme': {'incomingColor': 0xFFF5F5F5, 'outgoingColor': 0xFF202020},
      };
      await mountConversation(
        tester,
        MergedChatPage(personal: personal, group: g),
        client,
      );
      final bubbles = tester
          .widgetList<ConversationBubble>(find.byType(ConversationBubble))
          .toList();
      expect(
        bubbles.firstWhere((w) => !w.outgoing).backgroundColor,
        const Color(0xFFF5F5F5),
      );
      expect(
        bubbles.firstWhere((w) => w.outgoing).backgroundColor,
        const Color(0xFF202020),
      );
      for (final content in tester.widgetList<MessageContent>(
        find.byType(MessageContent),
      )) {
        final surface = content.event.senderId == client.userID
            ? const Color(0xFF202020)
            : const Color(0xFFF5F5F5);
        final a = surface.computeLuminance(),
            b = content.textColor.computeLuminance();
        expect(
          ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );
}
