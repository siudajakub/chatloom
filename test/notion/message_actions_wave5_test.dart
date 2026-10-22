// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 message actions: capability gates, delete, forward targets and
// content, reaction failures, network rejections, copy notices, haptics and
// the hover toolbar. Fictional offline fixtures only.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/network_rejections.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

const _bot = '@whatsappbot:example.invalid';

/// A room whose bridge bot is declared and whose events can be looked up.
class _Room extends ConversationRoom {
  final lookup = <String, Event>{};
  _Room(super.client, super.id) {
    state('m.bridge', {
      'protocol': {'id': 'whatsapp'},
      'bridgebot': _bot,
    }, key: 'fixture');
  }
  @override
  Future<Event?> getEventById(String eventID) async => lookup[eventID];
}

/// An own event whose redaction and cancellation are recorded.
class _Own extends Event {
  int redactions = 0;
  int cancels = 0;
  Object? redactFailure;
  Completer<void>? redactGate;
  _Own({
    required super.room,
    required String id,
    super.type = EventTypes.Message,
    Map<String, Object?>? content,
    super.status = EventStatus.synced,
    super.unsigned,
    DateTime? at,
  }) : super(
         eventId: id,
         senderId: room.client.userID!,
         originServerTs: at ?? DateTime.now(),
         content:
             content ?? {'msgtype': MessageTypes.Text, 'body': 'Fictional'},
       );
  @override
  Future<String?> redactEvent({
    String? reason,
    String? txid,
    bool redactAllEdits = false,
  }) async {
    redactions++;
    await redactGate?.future;
    if (redactFailure != null) throw redactFailure!;
    return '\$tidy-$eventId';
  }

  @override
  Future<void> cancelSend() async => cancels++;
}

Widget _host(Client client, Widget child) => Provider<MatrixState>.value(
  value: ConversationMatrix(client, AppSettings.store),
  child: MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    home: Scaffold(body: child),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('capability gates (UX-11)', () {
    test('edit hides past the network edit window and for non-text', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!edit:example.invalid');
      room.state(bridgeFeaturesEventType, {
        'edit': 2,
        'edit_max_age': 60,
        'delete': 2,
        'thread': -2,
      }, key: 'fixture');
      final fresh = _Own(room: room, id: r'$fresh');
      final old = _Own(
        room: room,
        id: r'$old',
        at: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      final image = _Own(
        room: room,
        id: r'$image',
        content: {'msgtype': MessageTypes.Image, 'body': 'photo.jpg'},
      );
      expect(ConversationMessageActions.canEditContent(fresh, null), isTrue);
      expect(ConversationMessageActions.canEditContent(old, null), isFalse);
      expect(ConversationMessageActions.canEditContent(image, null), isFalse);
      expect(ConversationMessageActions.canThread(room), isFalse);
      expect(ConversationMessageActions.canDeleteForEveryone(old), isTrue);
    });

    test('delete hides when the bridge refuses it; native rooms allow', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!delete:example.invalid');
      room.state(bridgeFeaturesEventType, {
        'delete': 2,
        'delete_max_age': 60,
      }, key: 'fixture');
      final old = _Own(
        room: room,
        id: r'$old',
        at: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      expect(ConversationMessageActions.canDeleteForEveryone(old), isFalse);
      final native = ConversationRoom(client, '!native:example.invalid')
        ..states.remove(bridgeFeaturesEventType);
      final message = _Own(room: native, id: r'$native');
      expect(ConversationMessageActions.canDeleteForEveryone(message), isTrue);
      expect(ConversationMessageActions.canThread(native), isTrue);
    });
  });

  group('delete for everyone (UX-06, CS-03, CC-05)', () {
    test('confirm text names the network, no reason field', () {
      final client = ConversationClient();
      final room = _Room(client, '!confirm:example.invalid');
      final text = MessageDeletions.confirmText(_Own(room: room, id: r'$a'));
      expect(text.title, 'Delete message?');
      expect(text.message, contains('on WhatsApp'));
    });

    testWidgets('the bubble goes at once; a failure brings it back + Retry', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = _Room(client, '!del:example.invalid');
      final event = _Own(room: room, id: r'$gone')
        ..redactGate = Completer<void>()
        ..redactFailure = TimeoutException('synthetic');
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          client,
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      var refreshes = 0;
      final done = MessageDeletions.delete(
        context,
        event,
        confirm: false,
        refresh: () => refreshes++,
      );
      expect(MessageDeletions.hides(event), isTrue);
      expect([event].filterByVisibleInGui(), isEmpty);
      expect(refreshes, 1);
      event.redactGate!.complete();
      await done;
      await tester.pump();
      expect(MessageDeletions.hides(event), isFalse);
      expect(refreshes, 2);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('Couldn’t delete'), findsOneWidget);
      MessageDeletions.debugReset(client);
    });

    testWidgets('a sending message is deleted as soon as it lands', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = _Room(client, '!sending:example.invalid');
      final sending = _Own(
        room: room,
        id: 'txn-1',
        status: EventStatus.sending,
        unsigned: {'transaction_id': 'txn-1'},
      );
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          client,
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await MessageDeletions.delete(
        context,
        sending,
        confirm: false,
        refresh: () {},
      );
      expect(sending.redactions, 0);
      final landed = _Own(
        room: room,
        id: r'$landed',
        status: EventStatus.sent,
        unsigned: {'transaction_id': 'txn-1'},
      );
      // Still hidden under its new event ID.
      expect(MessageDeletions.hides(landed), isTrue);
      client.onTimelineEvent.add(landed);
      await tester.pump();
      expect(landed.redactions, 1);
      MessageDeletions.debugReset(client);
    });
  });

  group('forward (UX-05, FT-13)', () {
    test('content loses relations and the reply fallback, keeps media', () {
      final content = forwardableContent({
        'msgtype': MessageTypes.Text,
        'body': '> <@a:example.invalid> quoted\n\nmy answer',
        'formatted_body': '<mx-reply>quoted</mx-reply>my answer',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$x'},
        },
        'm.new_content': {'body': 'x'},
      });
      expect(content.containsKey('m.relates_to'), isFalse);
      expect(content.containsKey('m.new_content'), isFalse);
      expect(content['body'], 'my answer');
      expect(content['formatted_body'], 'my answer');
      final media = forwardableContent({
        'msgtype': MessageTypes.Image,
        'body': 'photo.jpg',
        'file': {'url': 'mxc://example.invalid/fictional'},
      });
      expect(media['file'], isA<Map>());
    });

    test('targets skip the journal, technical and ignored chats', () {
      final client = ConversationClient();
      final personal = ConversationPersonal(client);
      final normal = ConversationRoom(client, '!normal:example.invalid');
      final journal = ConversationRoom(client, '!journal:example.invalid')
        ..state(personalRoomMarker, {'schema': personalSchemaVersion});
      final muted = ConversationRoom(client, '!blocked:example.invalid')
        ..sendingAllowed = false;
      final targets = forwardTargets(personal);
      final ids = targets.expand((t) => t.rooms).map((r) => r.id).toSet();
      expect(ids, contains(normal.id));
      expect(ids, isNot(contains(journal.id)));
      expect(ids, isNot(contains(muted.id)));
      for (final target in targets) {
        expect(target.name, isNot(contains('example.invalid')));
      }
    });

    test('a network that refuses the media explains why', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!media:example.invalid');
      room.state(bridgeFeaturesEventType, {
        'file': {
          'm.image': {
            'mime_types': {'image/jpeg': -2},
          },
        },
      }, key: 'fixture');
      final reason = forwardUnavailableReason(room, [
        ContentShareItem({
          'msgtype': MessageTypes.Image,
          'body': 'photo.jpg',
          'info': {'mimetype': 'image/jpeg'},
        }),
      ]);
      expect(reason, isNotNull);
      expect(forwardUnavailableReason(room, [TextShareItem('hi')]), isNull);
    });

    testWidgets('several chats, sent in place, closes with one notice', (
      tester,
    ) async {
      final client = ConversationClient();
      final personal = ConversationPersonal(client);
      ConversationRoom(client, '!one:example.invalid');
      ConversationRoom(client, '!two:example.invalid');
      final sent = <String>[];
      await tester.pumpWidget(
        _host(
          client,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showNotionSheet<void>(
                context: context,
                builder: (_) => ForwardSheet(
                  personal: personal,
                  send: (_, room) async {
                    sent.add(room.id);
                    return null;
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final rows = find.text('Fictional conversation');
      expect(rows, findsNWidgets(2));
      await tester.tap(rows.first);
      await tester.tap(rows.last);
      await tester.pump();
      expect(find.text('Send to 2 chats'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(2));
      expect(find.text('Forwarded to 2 chats'), findsOneWidget);
      expect(find.byType(ForwardSheet), findsNothing);
    });

    testWidgets('a failed chat stays with its reason and Try again', (
      tester,
    ) async {
      final client = ConversationClient();
      final personal = ConversationPersonal(client);
      ConversationRoom(client, '!fail:example.invalid');
      var attempts = 0;
      await tester.pumpWidget(
        _host(
          client,
          ForwardSheet(
            personal: personal,
            send: (_, room) async => ++attempts == 1 ? 'Not sent.' : null,
          ),
        ),
      );
      await tester.tap(find.text('Fictional conversation'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();
      expect(find.text('Not sent.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('reactions (CC-11)', () {
    testWidgets('an error echo fails the intent, is dropped and retriable', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!react:example.invalid');
      final event = room.message(r'$target', 'Fictional');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(timeline.cancelSubscriptions);
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          client,
          Builder(
            builder: (c) {
              context = c;
              return ConversationReactionFeedback(event, timeline);
            },
          ),
        ),
      );
      room.reactionGate = Completer<String?>();
      final attempt = ConversationMessageActions.react(
        context,
        event,
        timeline,
        '👍',
      );
      final echo = _Own(
        room: room,
        id: 'txn-reaction',
        type: EventTypes.Reaction,
        status: EventStatus.error,
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': event.eventId,
            'key': '👍',
          },
        },
      );
      timeline.addAggregatedEvent(echo);
      room.reactionGate!.complete(null);
      expect(await attempt, isFalse);
      final key = ConversationMessageActions.key(event, '👍');
      final manager = ConversationMessageActions.coordinator(event);
      expect(manager.state(key), ConversationReactionState.failed);
      expect(echo.cancels, 1);
      expect(
        ConversationMessageActions.ownReactionKeys(event, timeline),
        isEmpty,
      );
      await tester.pump();
      expect(find.text('Reaction not sent · Tap to retry'), findsOneWidget);
      room.reactionGate = null;
      timeline.aggregatedEvents.clear();
      await tester.tap(find.byKey(const ValueKey('reaction-retry')));
      await tester.pump();
      expect(room.reactionsSent, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('network rejections (BR-05)', () {
    Event report(
      Room room,
      String target, {
      String status = 'FAIL_PERMANENT',
    }) => Event(
      room: room,
      eventId: '\$mss-$target',
      senderId: _bot,
      originServerTs: DateTime.now(),
      type: beeperMessageSendStatusType,
      content: {
        'status': status,
        'reason': 'com.beeper.unsupported_event',
        'm.relates_to': {
          'rel_type': RelationshipTypes.reference,
          'event_id': target,
        },
      },
    );

    test('a refused reaction is reverted and said once', () async {
      final client = ConversationClient();
      final room = _Room(client, '!mss:example.invalid');
      final reaction = _Own(
        room: room,
        id: r'$reaction',
        type: EventTypes.Reaction,
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': r'$m',
            'key': '🦄',
          },
        },
      );
      room.lookup[reaction.eventId] = reaction;
      final notices = <String>[];
      final watcher = NetworkRejectionWatcher(
        client,
        rooms: () => {room.id},
        notify: notices.add,
      );
      addTearDown(watcher.dispose);
      await watcher.handle(report(room, reaction.eventId));
      await watcher.handle(report(room, reaction.eventId));
      expect(notices, ['WhatsApp didn’t accept this reaction.']);
      expect(reaction.redactions, 1);
      // The bridge's report about that tidy-up redaction is not shown.
      expect(MessageDeletions.isQuiet(room, r'$tidy-$reaction'), isTrue);
      MessageDeletions.debugReset(client);
    });

    test('a refused edit is reverted; a refused delete is explained', () async {
      final client = ConversationClient();
      final room = _Room(client, '!edit-mss:example.invalid');
      final edit = _Own(
        room: room,
        id: r'$edit',
        content: {
          'msgtype': MessageTypes.Text,
          'body': '* new',
          'm.new_content': {'msgtype': MessageTypes.Text, 'body': 'new'},
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': r'$m',
          },
        },
      );
      final message = _Own(room: room, id: r'$m');
      final redaction = Event(
        room: room,
        eventId: r'$redaction',
        senderId: client.userID,
        originServerTs: DateTime.now(),
        type: EventTypes.Redaction,
        redacts: r'$m',
        content: {'redacts': r'$m'},
      );
      room.lookup
        ..[edit.eventId] = edit
        ..[message.eventId] = message
        ..[redaction.eventId] = redaction;
      final notices = <String>[];
      final watcher = NetworkRejectionWatcher(
        client,
        rooms: () => {room.id},
        notify: notices.add,
      );
      addTearDown(watcher.dispose);
      await watcher.handle(report(room, edit.eventId));
      await watcher.handle(report(room, redaction.eventId));
      // Other rooms, old reports and untrusted senders are ignored.
      await watcher.handle(
        Event(
          room: room,
          eventId: r'$spoof',
          senderId: '@mallory:example.invalid',
          originServerTs: DateTime.now(),
          type: beeperMessageSendStatusType,
          content: {
            'status': 'FAIL_PERMANENT',
            'm.relates_to': {
              'rel_type': RelationshipTypes.reference,
              'event_id': message.eventId,
            },
          },
        ),
      );
      expect(edit.redactions, 1);
      expect(notices, hasLength(2));
      expect(notices.first, contains('didn’t accept the edit'));
      expect(
        notices.last,
        'Not deleted on WhatsApp. The other person may '
        'still see it.',
      );
      MessageDeletions.debugReset(client);
    });
  });

  group('copy and haptics (UX-28, UX-29, CS-10)', () {
    testWidgets('no copy notice where the system shows its own', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      debugSystemShowsClipboardOverlay = true;
      addTearDown(() => debugSystemShowsClipboardOverlay = null);
      await showCopiedNotice(context, 'Copied');
      await tester.pump();
      expect(find.text('Copied'), findsNothing);
      debugSystemShowsClipboardOverlay = false;
      await showCopiedNotice(context, 'Copied');
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('NotionHaptics.selection is a selection click', (tester) async {
      final calls = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments);
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
      NotionHaptics.selection();
      await tester.pump();
      expect(calls, ['HapticFeedbackType.selectionClick']);
    });
  });

  group('hover actions (UX-24)', () {
    testWidgets('a mouse over the bubble shows react · reply · more', (
      tester,
    ) async {
      var replies = 0;
      ConversationMessagePress? press;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: ConversationMessageGestures(
                identity: 'fixture',
                hoverActions: true,
                hoverReact: () => true,
                onReply: () => replies++,
                onLongPress: (p) => press = p,
                child: const SizedBox(width: 200, height: 40),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(NotionHoverToolbar), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(SizedBox).last));
      await tester.pumpAndSettle();
      expect(find.byType(NotionHoverToolbar), findsOneWidget);
      expect(find.byTooltip('React'), findsOneWidget);
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.reply_rounded)));
      await tester.pumpAndSettle();
      expect(find.byType(NotionHoverToolbar), findsOneWidget);
      await tester.tap(
        find.byIcon(Icons.reply_rounded),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(replies, 1);
      await mouse.moveTo(tester.getCenter(find.byType(SizedBox).last));
      await tester.pumpAndSettle();
      await mouse.moveTo(
        tester.getCenter(find.byIcon(Icons.add_reaction_outlined)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byIcon(Icons.add_reaction_outlined),
        kind: PointerDeviceKind.mouse,
      );
      expect(press?.reactionsOnly, isTrue);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.byType(NotionHoverToolbar), findsNothing);
    });

    testWidgets('touch never shows the toolbar', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConversationMessageGestures(
                identity: 'touch',
                hoverActions: true,
                onReply: () {},
                child: const SizedBox(width: 200, height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SizedBox).last);
      await tester.pumpAndSettle();
      expect(find.byType(NotionHoverToolbar), findsNothing);
    });
  });

  test('the privacy filter still drops the journal from every target', () {
    final client = ConversationClient();
    final journal = ConversationRoom(client, '!only-journal:example.invalid')
      ..state(personalRoomMarker, {'schema': personalSchemaVersion});
    expect(PersonalPrivacy.isJournal(journal), isTrue);
    expect(forwardTargets(ConversationPersonal(client)), isEmpty);
  });
}
