// SPDX-License-Identifier: AGPL-3.0-or-later
// Composer send, reply cancel, jump button and per-message delivery status.
// Fictional offline fixtures only; no accounts, network or storage.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/pages/chat/reply_display.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

PersonGroup _group(PersonalClient p, Room a, Room b) => PersonGroup(
  id: 'send-person',
  name: 'Anna',
  members: [p.ref(a), p.ref(b)],
  defaultRoomId: a.id,
);

Future<void> _mount(WidgetTester tester, Widget home, Client client) async {
  final matrix = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: matrix,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ConversationComposerHost _host(WidgetTester tester) =>
    tester.state(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_MergedChatView',
          ),
        )
        as ConversationComposerHost;

Finder get _editor => find.descendant(
  of: find.byType(InputBar),
  matching: find.byType(TextField),
);

String _editorText(WidgetTester tester) =>
    tester.widget<TextField>(_editor).controller!.text;

/// Runs the send up to the fixture's durable point (microtasks and zero
/// timers), without letting the held "network" finish.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

/// Types into the composer and lets it swap the mic for the send button.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_editor, text);
  await tester.pump();
}

/// An own text message as the SDK shows it while (or after) sending.
Event _own(
  ConversationRoom room,
  String id,
  String text, {
  EventStatus status = EventStatus.synced,
  String? transactionId,
}) {
  final event = Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: room.client.userID!,
    originServerTs: DateTime.utc(2026, 10, 16, 16, 50),
    status: status,
    content: {'msgtype': MessageTypes.Text, 'body': text},
    unsigned: transactionId == null ? null : {'transaction_id': transactionId},
  );
  room.sourceEvents.insert(0, event);
  return event;
}

Widget _message(Event event, Timeline timeline) => Scaffold(
  body: Center(
    child: Message(
      event,
      bigEmojis: const {},
      onInfoTab: (_) {},
      scrollToEventId: (_) {},
      onSwipe: () {},
      timeline: timeline,
      onMention: () {},
      scrollController: ScrollController(),
      enterThread: null,
    ),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('composer send', () {
    testWidgets(
      'the composer is empty while the network send is still pending',
      (tester) async {
        final client = ConversationClient();
        final a = ConversationRoom(client, '!send-a:example.invalid');
        final b = ConversationRoom(
          client,
          '!send-b:example.invalid',
          network: 'telegram',
        );
        final original = a.message(r'$original', 'Reply to me');
        b.message(r'$other', 'Other source', minute: 39);
        final gate = Completer<void>();
        final personal = ConversationPersonal(client)..transportGate = gate;
        addTearDown(personal.dispose);
        await _mount(
          tester,
          MergedChatPage(personal: personal, group: _group(personal, a, b)),
          client,
        );
        _host(tester).replyAction(replyTo: original);
        await tester.pumpAndSettle();
        await _type(tester, 'First message');
        await tester.tap(find.byKey(const Key('send_button')));
        await _flush(tester);
        // Durable in the outbox, the bridge is still busy: Telegram clears.
        expect(gate.isCompleted, isFalse);
        expect(_editorText(tester), isEmpty);
        expect(_host(tester).replyEvent, isNull);
        expect(personal.sends.single.reply, same(original));
        expect(personal.drafts.last.text, isEmpty);
        // The next message can be sent while the first one is in flight.
        await _type(tester, 'Second');
        await tester.tap(find.byKey(const Key('send_button')));
        await _flush(tester);
        expect(personal.sends.map((s) => s.text), ['First message', 'Second']);
        expect(_editorText(tester), isEmpty);
        gate.complete();
        await tester.pumpAndSettle();
        expect(_editorText(tester), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('typing during a slow send keeps only the new text', (
      tester,
    ) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!slow-a:example.invalid');
      final b = ConversationRoom(
        client,
        '!slow-b:example.invalid',
        network: 'telegram',
      );
      a.message(r'$a', 'Earlier message');
      b.message(r'$b', 'Other source', minute: 39);
      final gate = Completer<void>();
      final personal = ConversationPersonal(client)..transportGate = gate;
      addTearDown(personal.dispose);
      await _mount(
        tester,
        MergedChatPage(personal: personal, group: _group(personal, a, b)),
        client,
      );
      await _type(tester, 'Old message');
      await tester.tap(find.byKey(const Key('send_button')));
      await _flush(tester);
      await _type(tester, 'New text');
      gate.complete();
      await tester.pumpAndSettle();
      expect(_editorText(tester), 'New text');
      expect(personal.drafts.last.text, 'New text');
      expect(personal.sends.single.text, 'Old message');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('an outbox that cannot persist keeps the text and says so', (
      tester,
    ) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!store-a:example.invalid');
      final b = ConversationRoom(
        client,
        '!store-b:example.invalid',
        network: 'telegram',
      );
      a.message(r'$a', 'Earlier message');
      b.message(r'$b', 'Other source', minute: 39);
      final personal = ConversationPersonal(client)..durable = false;
      addTearDown(personal.dispose);
      await _mount(
        tester,
        MergedChatPage(personal: personal, group: _group(personal, a, b)),
        client,
      );
      await _type(tester, 'Keep me');
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      expect(_editorText(tester), 'Keep me');
      expect(find.textContaining('it was not sent'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets(
      'a failure with its own bubble is not put back into the composer',
      (tester) async {
        final client = ConversationClient();
        final a = ConversationRoom(client, '!echo-a:example.invalid');
        final b = ConversationRoom(
          client,
          '!echo-b:example.invalid',
          network: 'telegram',
        );
        a.message(r'$a', 'Earlier message');
        b.message(r'$b', 'Other source', minute: 39);
        final personal = ConversationPersonal(client)
          ..sendState = ImmediateSendState.unknown
          ..echoShown = true;
        addTearDown(personal.dispose);
        await _mount(
          tester,
          MergedChatPage(personal: personal, group: _group(personal, a, b)),
          client,
        );
        await _type(tester, 'Flaky network');
        await tester.tap(find.byKey(const Key('send_button')));
        await tester.pumpAndSettle();
        expect(_editorText(tester), isEmpty);
        expect(personal.discarded, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  });

  group('ordinary chat', () {
    testWidgets(
      'clears on durable send, keeps text typed meanwhile, flushes the draft on leave',
      (tester) async {
        final client = ConversationClient();
        final room = ConversationRoom(client, '!ordinary-send:example.invalid');
        room.message(r'$hello', 'Hello');
        final gate = Completer<void>();
        final personal = ConversationPersonal(client)..transportGate = gate;
        PersonalClient.debugUse(client, personal);
        addTearDown(personal.dispose);
        await _mount(tester, ChatPageWithRoom(room: room), client);
        await _type(tester, 'Sent while the bridge is slow');
        await tester.tap(find.byKey(const Key('send_button')));
        await _flush(tester);
        expect(gate.isCompleted, isFalse);
        expect(personal.sends.single.text, 'Sent while the bridge is slow');
        expect(_editorText(tester), isEmpty);
        await _type(tester, 'Next one');
        gate.complete();
        await tester.pump();
        await tester.pump();
        expect(_editorText(tester), 'Next one');
        // Leaving within the 500 ms debounce still saves the draft.
        await tester.enterText(_editor, 'Next one, edited');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(personal.drafts.last.text, 'Next one, edited');
        await tester.pumpAndSettle();
      },
    );
  });

  group('reply cancel and jump button', () {
    testWidgets(
      'reply close stays tappable while scrolled up; the jump button sits above the composer',
      (tester) async {
        final client = ConversationClient();
        final a = ConversationRoom(client, '!jump-a:example.invalid');
        final b = ConversationRoom(
          client,
          '!jump-b:example.invalid',
          network: 'telegram',
        );
        late Event target;
        for (var i = 0; i < 40; i++) {
          final e = a.message('\$m$i', 'Fictional message number $i');
          if (i == 0) target = e;
        }
        final personal = ConversationPersonal(client);
        addTearDown(personal.dispose);
        await _mount(
          tester,
          MergedChatPage(personal: personal, group: _group(personal, a, b)),
          client,
        );
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pumpAndSettle();
        _host(tester).replyAction(replyTo: target);
        await tester.pumpAndSettle();
        final jump = find.byKey(const ValueKey('conversation-jump'));
        expect(jump, findsOneWidget);
        final close = find.descendant(
          of: find.byType(ReplyDisplay),
          matching: find.byType(IconButton),
        );
        expect(close, findsOneWidget);
        final jumpRect = tester.getRect(jump);
        final composerTop = tester.getRect(find.byType(ReplyDisplay)).top;
        expect(jumpRect.overlaps(tester.getRect(close)), isFalse);
        expect(jumpRect.bottom, lessThanOrEqualTo(composerTop));
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(_host(tester).replyEvent, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('system back cancels the reply before leaving the chat', (
      tester,
    ) async {
      final client = ConversationClient();
      final a = ConversationRoom(client, '!back-a:example.invalid');
      final b = ConversationRoom(
        client,
        '!back-b:example.invalid',
        network: 'telegram',
      );
      final original = a.message(r'$back', 'Quoted message');
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final matrix = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            navigatorKey: navigator,
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const Scaffold(body: Text('Inbox')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => MergedChatPage(
              personal: personal,
              group: _group(personal, a, b),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _host(tester).replyAction(replyTo: original);
      await tester.pumpAndSettle();
      expect(find.byType(ReplyDisplay), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      // Still in the chat, the reply is gone.
      expect(find.text('Inbox'), findsNothing);
      expect(_host(tester).replyEvent, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('the jump button shows the count of new messages', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: ConversationJumpButtonSlot(
                    composerInset: ValueNotifier(120),
                    child: ConversationJumpButton(
                      visible: true,
                      count: 3,
                      onPressed: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      final rect = tester.getRect(
        find.byKey(const ValueKey('conversation-jump')),
      );
      final screen = tester.getRect(find.byType(Scaffold));
      // Above the 120 px composer plus the gap.
      expect(rect.bottom, lessThanOrEqualTo(screen.bottom - 120));
    });
  });

  group('delivery status in the bubble', () {
    testWidgets('a failed send shows "Not sent" with Retry and Delete', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!fail:example.invalid');
      final personal = ConversationPersonal(client);
      PersonalClient.debugUse(client, personal);
      addTearDown(personal.dispose);
      final event = _own(
        room,
        'immediate-abc',
        'Did not reach the server',
        status: EventStatus.error,
        transactionId: 'immediate-abc',
      );
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: room.sourceEvents),
      );
      addTearDown(timeline.cancelSubscriptions);
      await _mount(tester, _message(event, timeline), client);
      expect(find.text('Not sent · Tap to retry'), findsOneWidget);
      await tester.tap(find.text('Not sent · Tap to retry'));
      await tester.pumpAndSettle();
      expect(find.text('Message not sent'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(
        find.text(L10n.of(tester.element(find.text('Retry'))).delete),
        findsOneWidget,
      );
      // Unknown, not rejected: the sheet says a retry cannot duplicate.
      expect(find.textContaining('never delivered twice'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(personal.retried, ['abc']);
    });

    testWidgets('"Sending" waits for the loader grace (no flash)', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!pending:example.invalid');
      final event = _own(
        room,
        'immediate-pending',
        'On its way',
        status: EventStatus.sending,
        transactionId: 'immediate-pending',
      );
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: room.sourceEvents),
      );
      addTearDown(timeline.cancelSubscriptions);
      final matrix = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: _message(event, timeline),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final sending = L10n.of(tester.element(find.text('On its way'))).sending;
      expect(find.text(sending), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(sending), findsOneWidget);
    });

    testWidgets('a bridge rejection says which network did not get it', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!bridge:example.invalid');
      room.state('m.bridge', {
        'protocol': {'id': 'whatsapp'},
        'bridgebot': '@whatsappbot:example.invalid',
      }, key: 'fixture');
      final event = _own(room, r'$sent', 'Bridged message');
      final report = Event(
        room: room,
        eventId: r'$status',
        type: beeperMessageSendStatusType,
        senderId: '@whatsappbot:example.invalid',
        originServerTs: DateTime.utc(2026, 10, 16, 16, 51),
        content: {
          'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$sent'},
          'status': 'FAIL_PERMANENT',
          'reason': 'm.foreign_network_error',
          'message': 'The recipient blocked you',
        },
      );
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [report, ...room.sourceEvents]),
      );
      addTearDown(timeline.cancelSubscriptions);
      await _mount(tester, _message(event, timeline), client);
      expect(
        find.text('Not delivered to WhatsApp · Tap for details'),
        findsOneWidget,
      );
      await tester.tap(
        find.text('Not delivered to WhatsApp · Tap for details'),
      );
      await tester.pumpAndSettle();
      expect(find.text('The recipient blocked you.'), findsOneWidget);
      // Permanent: no "Send again", only Cancel.
      expect(find.text('Send again'), findsNothing);
    });
  });

  group('delivery logic', () {
    final at = DateTime.utc(2026, 10, 20, 12);
    test('only the declared bridge bot may report delivery', () {
      final content = {'status': 'FAIL_PERMANENT', 'message': 'Nope'};
      expect(
        BridgeSendStatus.parse(
          content,
          sender: '@stranger:example.invalid',
          bridgeBots: {'@bot:example.invalid'},
          at: at,
        ),
        isNull,
      );
      expect(
        BridgeSendStatus.parse(
          content,
          sender: '@bot:example.invalid',
          bridgeBots: {'@bot:example.invalid'},
          at: at,
        )?.failed,
        isTrue,
      );
      expect(
        BridgeSendStatus.parse(
          {'status': 'MAYBE'},
          sender: '@bot:example.invalid',
          bridgeBots: {'@bot:example.invalid'},
          at: at,
        ),
        isNull,
      );
    });

    test('the newest report wins (a retried message can succeed)', () {
      final failed = BridgeSendStatus(status: 'FAIL_RETRIABLE', at: at);
      final ok = BridgeSendStatus(
        status: 'SUCCESS',
        at: at.add(const Duration(seconds: 5)),
      );
      expect(BridgeSendStatus.latest([ok, failed]), same(ok));
      expect(
        MessageDelivery.resolve(
          own: true,
          status: EventStatus.synced,
          bridge: BridgeSendStatus.latest([failed, ok]),
        ).kind,
        MessageDeliveryKind.none,
      );
      final retriable = MessageDelivery.resolve(
        own: true,
        status: EventStatus.synced,
        bridge: failed,
        network: 'Telegram',
      );
      expect(retriable.kind, MessageDeliveryKind.notDelivered);
      expect(retriable.canRetry, isTrue);
      expect(retriable.canDelete, isFalse);
      expect(retriable.label, 'Not delivered to Telegram · Tap for details');
      expect(retriable.detail, contains('Try sending it again.'));
      // An echo/ack timeout may have arrived: no retry, no "too old".
      final unconfirmed = MessageDelivery.resolve(
        own: true,
        status: EventStatus.synced,
        bridge: BridgeSendStatus(
          status: 'FAIL_RETRIABLE',
          reason: 'm.event_too_old',
          at: at,
        ),
        network: 'Telegram',
      );
      expect(unconfirmed.canRetry, isFalse);
      expect(unconfirmed.detail, contains('may still have arrived'));
    });

    test('server states map to the bubble', () {
      expect(
        MessageDelivery.resolve(own: false, status: EventStatus.error).kind,
        MessageDeliveryKind.none,
      );
      final error = MessageDelivery.resolve(
        own: true,
        status: EventStatus.error,
      );
      expect(error.kind, MessageDeliveryKind.notSent);
      expect(error.canRetry && error.canDelete, isTrue);
      expect(
        MessageDelivery.resolve(own: true, status: EventStatus.sending).kind,
        MessageDeliveryKind.sending,
      );
      final edit = MessageDelivery.resolve(
        own: true,
        status: EventStatus.synced,
        editStatuses: [EventStatus.synced, EventStatus.error],
      );
      expect(edit.edit, isTrue);
      expect(edit.label, 'Edit not sent · Tap to retry');
      expect(
        bridgeFailureText(
          BridgeSendStatus(
            status: 'FAIL_PERMANENT',
            reason: 'com.beeper.unsupported_event',
            at: at,
          ),
          network: 'Signal',
        ),
        'Signal doesn’t support this message.',
      );
    });
  });
}
