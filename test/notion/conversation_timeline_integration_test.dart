import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/reply_content.dart';
import 'package:chatloom/pages/chat/reply_display.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
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

  final attachments = <AddPopupMenuActions>[];
  @override
  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    attachments.add(choice);
  }

  final later = <String>[];
  @override
  Future<void> composerSendLater() async => later.add('schedule');
  @override
  Future<void> composerRemindMe() async => later.add('reminder');
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
            onInfoTab: (_) {
              infoTaps++;
            },
            scrollToEventId: (_) {},
            onSwipe: () => replies++,
            timeline: t,
            onMention: () {},
            scrollController: scroll,
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
          .firstWhere((w) => w.identity == original.eventId);
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
          .firstWhere((w) => w.identity == original.eventId)
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
      await tester.tap(
        find.descendant(
          of: find.byType(ReplyDisplay),
          matching: find.byIcon(Icons.close),
        ),
      );
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
    'ordinary plus opens the attach menu directly; emoji stays one tap',
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
      final editor = tester.state(find.byType(EditableText));
      // The emoji toggle is always beside "+", no tray to open first.
      expect(find.byTooltip('More message actions'), findsNothing);
      expect(find.byTooltip('Emoji picker').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Attach media or a file'));
      await tester.pumpAndSettle();
      // A glass menu above the composer, not a bottom sheet.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(NotionGlassPanel), findsOneWidget);
      // Send later lives in the conversation menu and on Send's long press.
      expect(find.text('Send later'), findsNothing);
      final l10n = L10n.of(tester.element(find.byType(ChatInputRow)));
      final file = l10n.sendFile;
      // Library media (photo and video together), then structured content.
      final order = [
        'Photo or video',
        file,
        l10n.startPoll,
      ].map((label) => tester.getCenter(find.text(label)).dy).toList();
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]));
      }
      expect(find.text(l10n.sendImage), findsNothing);
      expect(find.text(l10n.sendVideo), findsNothing);
      expect(find.text('Record a round video silently'), findsNothing);
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();
      // One tap from the menu to the combined picker; the chat stays.
      expect(controller.attachments, [AddPopupMenuActions.gallery]);
      expect(find.byType(NotionGlassPanel), findsNothing);
      expect(find.byType(ChatInputRow), findsOneWidget);
      await tester.tap(find.byTooltip('Attach media or a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(file));
      await tester.pumpAndSettle();
      expect(controller.attachments, [
        AddPopupMenuActions.gallery,
        AddPopupMenuActions.file,
      ]);
      await tester.tap(find.byTooltip('Emoji picker'));
      await tester.pumpAndSettle();
      expect(controller.emojiOpens, 1);
      expect(tester.state(find.byType(EditableText)), same(editor));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.sendController.dispose();
      controller.inputFocus.dispose();
      controller.scrollController.dispose();
    },
  );
  testWidgets('long press on Send offers Send later and Remind me', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!later:example.invalid');
    final controller = _ComposerController(room);
    await mountConversation(
      tester,
      // The fake does not rebuild on typing: listen to the text instead.
      Scaffold(
        body: ListenableBuilder(
          listenable: controller.sendController,
          builder: (_, _) => ChatInputRow(controller),
        ),
      ),
      client,
    );
    await tester.enterText(find.byType(TextField), 'Later text');
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPanel), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    await tester.tap(find.text('Send later'));
    await tester.pumpAndSettle();
    expect(controller.later, ['schedule']);
    await tester.longPress(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remind me'));
    await tester.pumpAndSettle();
    expect(controller.later, ['schedule', 'reminder']);
    // The text is untouched: Send later decides later whether to clear it.
    expect(controller.sendController.text, 'Later text');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.sendController.dispose();
    controller.inputFocus.dispose();
    controller.scrollController.dispose();
  });
  testWidgets(
    'merged plus opens the attach menu, compact chip keeps its picker',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!tray-a:example.invalid');
      final b = ConversationRoom(client, '!tray-b:example.invalid');
      a.message(r'$tray-a', 'A');
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      await mountConversation(
        tester,
        MergedChatPage(personal: personal, group: group(personal, a, b)),
        client,
      );
      expect(
        tester.getSize(find.byType(ConversationSourceChip)).width,
        lessThanOrEqualTo(56),
      );
      expect(find.byTooltip('Emoji picker'), findsOneWidget);
      await tester.tap(find.byTooltip('Attach media or a file'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Photo or video'), findsOneWidget);
      expect(find.text('Send later'), findsNothing);
      // Silent rounds stay in the attach menu, never as a bare composer icon.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Photo or video'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Typed');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Attach media or a file'), findsOneWidget);
      expect(find.byType(MergedChatPage), findsOneWidget);
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} reply quote has readable text on its fill',
      (tester) async {
        final client = ConversationClient();
        final room = ConversationRoom(
          client,
          '!quote-contrast:example.invalid',
        );
        final event = room.message(r'$quote-contrast', 'Fictional quote body');
        late Color fill;
        await tester.pumpWidget(
          MaterialApp(
            theme: NotionTheme.build(brightness),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final bubble = ConversationBubbleColors.of(context);
                  final colors = ConversationReplyQuote.colorsFor(
                    side: bubble.outgoing,
                    page: context.notion.colors.background,
                    muted: bubble.metadata,
                  );
                  fill = colors.fill;
                  return ReplyContent(
                    event,
                    fill: colors.fill,
                    textColor: colors.text,
                    outgoing: true,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final color = tester
            .widget<Text>(find.text('Fictional quote body'))
            .style!
            .color!;
        expect(
          NotionContrast.ratio(color, fill),
          greaterThanOrEqualTo(NotionContrast.minimum),
        );
      },
    );
  }
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
