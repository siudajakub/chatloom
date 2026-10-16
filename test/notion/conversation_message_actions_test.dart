import 'dart:async';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/conversation_message_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:provider/provider.dart';
import 'conversation_test_support.dart';

class _Reaction extends Event {
  int removals = 0;
  Object? removalFailure;
  _Reaction(Event original, {EventStatus status = EventStatus.synced})
    : super(
        room: original.room,
        eventId: r'$own-reaction',
        senderId: original.room.client.userID!,
        originServerTs: DateTime.utc(2026),
        status: status,
        type: EventTypes.Reaction,
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': original.eventId,
            'key': '👍',
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
    if (removalFailure != null) throw removalFailure!;
    return r'$redacted';
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  test(
    'in-flight then echo lag retains one intention; confirmed sync releases',
    () async {
      final c = ConversationReactionCoordinator();
      final gate = Completer<void>();
      var requests = 0;
      var local = false;
      var confirmed = false;
      Future<ConversationReactionResult> add() => c.perform(
        key: 'synthetic',
        exists: () => local,
        confirmed: () => confirmed,
        allowed: () => true,
        add: () async {
          requests++;
          await gate.future;
        },
        remove: () async {},
        definitiveFailure: (_) => false,
      );
      final first = add();
      expect(await add(), ConversationReactionResult.pending);
      gate.complete();
      expect(await first, ConversationReactionResult.added);
      expect(await add(), ConversationReactionResult.pending);
      local = true;
      expect(await add(), ConversationReactionResult.pending);
      expect(requests, 1);
      confirmed = true;
      expect(await add(), ConversationReactionResult.existing);
      expect(c.state('synthetic'), ConversationReactionState.idle);
    },
  );
  test(
    'unknown is not automatically retried; explicit definitive failure can retry',
    () async {
      final c = ConversationReactionCoordinator();
      var requests = 0;
      var definite = false;
      Future<ConversationReactionResult> attempt() => c.perform(
        key: 'synthetic',
        exists: () => false,
        allowed: () => true,
        add: () async {
          requests++;
          throw StateError('synthetic');
        },
        remove: () async {},
        definitiveFailure: (_) => definite,
      );
      expect(await attempt(), ConversationReactionResult.unknown);
      expect(await attempt(), ConversationReactionResult.pending);
      expect(requests, 1);
      definite = true;
      final d = ConversationReactionCoordinator();
      Future<ConversationReactionResult> rejected() => d.perform(
        key: 'other',
        exists: () => false,
        allowed: () => true,
        add: () async {
          requests++;
          throw StateError('synthetic');
        },
        remove: () async {},
        definitiveFailure: (_) => true,
      );
      expect(await rejected(), ConversationReactionResult.failed);
      expect(await rejected(), ConversationReactionResult.failed);
      expect(requests, 3);
    },
  );
  test(
    'revalidates capability after pending listener changes context',
    () async {
      final c = ConversationReactionCoordinator();
      var allowed = true;
      var requests = 0;
      c.addListener(() => allowed = false);
      expect(
        await c.perform(
          key: 'source',
          exists: () => false,
          allowed: () => allowed,
          add: () async {
            requests++;
          },
          remove: () async {},
          definitiveFailure: (_) => false,
        ),
        ConversationReactionResult.denied,
      );
      expect(requests, 0);
    },
  );
  testWidgets(
    'real SDK adapter shares add-only, chips, local echo, unknown and removal guards',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!source:example.invalid');
      final event = room.message(r'$message', 'Fictional text');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(timeline.cancelSubscriptions);
      late BuildContext context;
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, AppSettings.store),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  context = c;
                  return ConversationReactionFeedback(event, timeline);
                },
              ),
            ),
          ),
        ),
      );
      expect(room.reactionsSent, 0);
      room.reactionFailure = TimeoutException('synthetic');
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          timeline,
          '👍',
          strict: true,
        ),
        isFalse,
      );
      expect(room.reactionsSent, 1);
      final local = _Reaction(event, status: EventStatus.sending);
      timeline.addAggregatedEvent(local);
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          timeline,
          '👍',
          strict: true,
          toggle: true,
        ),
        isFalse,
      );
      expect(local.removals, 0);
      expect(room.reactionsSent, 1);
      local.status = EventStatus.synced;
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          timeline,
          '👍',
          strict: true,
        ),
        isFalse,
      );
      expect(local.removals, 0);
      // At bridge reaction_count=1, explicit removal remains permitted.
      room.reactionsAllowed = false;
      room.sendingAllowed = false;
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          timeline,
          '👍',
          strict: true,
          toggle: true,
        ),
        isFalse,
      );
      expect(local.removals, 1);
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          timeline,
          '👍',
          strict: true,
          toggle: true,
        ),
        isFalse,
      );
      expect(local.removals, 1);
      timeline.aggregatedEvents.clear();
      ConversationMessageActions.reconcile(event, timeline);
      expect(
        ConversationMessageActions.coordinator(
          event,
        ).state(ConversationMessageActions.key(event, '👍', removal: true)),
        ConversationReactionState.idle,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'capability, unavailable/local event and stale account deny all transport',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!guard:example.invalid');
      final event = room.message(r'$guard', 'Fictional');
      final t = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(t.cancelSubscriptions);
      late BuildContext context;
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, AppSettings.store),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  context = c;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      room.reactionsAllowed = false;
      await ConversationMessageActions.react(
        context,
        event,
        t,
        '👍',
        strict: true,
      );
      room.reactionsAllowed = true;
      await ConversationMessageActions.react(
        context,
        event,
        t,
        '👍',
        strict: true,
        isCurrent: () => false,
      );
      event.status = EventStatus.sending;
      await ConversationMessageActions.react(
        context,
        event,
        t,
        '👍',
        strict: true,
      );
      event.status = EventStatus.synced;
      room.state('com.beeper.room_features', {'reaction': 0}, key: 'fixture');
      await ConversationMessageActions.react(
        context,
        event,
        t,
        '👍',
        strict: true,
      );
      expect(room.reactionsSent, 0);
    },
  );
  testWidgets('different pending emoji share source capacity before SDK echo', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!capacity:example.invalid');
    final event = room.message(r'$capacity', 'Fictional');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    addTearDown(timeline.cancelSubscriptions);
    late BuildContext context;
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(client, AppSettings.store),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    room.reactionGate = Completer<String?>();
    final first = ConversationMessageActions.react(
      context,
      event,
      timeline,
      '👍',
      strict: true,
    );
    expect(
      await ConversationMessageActions.react(
        context,
        event,
        timeline,
        '❤️',
        strict: true,
      ),
      isFalse,
    );
    expect(room.reactionsSent, 1);
    room.reactionGate!.complete(r'$accepted');
    expect(await first, isTrue);
    expect(
      await ConversationMessageActions.react(
        context,
        event,
        timeline,
        '❤️',
        strict: true,
      ),
      isFalse,
    );
    expect(room.reactionsSent, 1);
  });
  testWidgets(
    'unknown removal survives fresh unloaded timeline until source redaction evidence',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!remove-evidence:example.invalid');
      final event = room.message(r'$remove-evidence', 'Fictional');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      final fresh = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      addTearDown(timeline.cancelSubscriptions);
      addTearDown(fresh.cancelSubscriptions);
      final own = _Reaction(event)
        ..removalFailure = TimeoutException('synthetic');
      timeline.addAggregatedEvent(own);
      late BuildContext context;
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, AppSettings.store),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  context = c;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      await ConversationMessageActions.react(
        context,
        event,
        timeline,
        '👍',
        strict: true,
        toggle: true,
      );
      expect(own.removals, 1);
      ConversationMessageActions.reconcile(event, fresh);
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          fresh,
          '❤️',
          strict: true,
        ),
        isFalse,
      );
      expect(room.reactionsSent, 0);
      fresh.events.add(
        Event(
          room: room,
          type: EventTypes.Redaction,
          eventId: r'$redaction-proof',
          senderId: client.userID,
          originServerTs: DateTime.utc(2026),
          content: const {},
          redacts: own.eventId,
          status: EventStatus.synced,
        ),
      );
      ConversationMessageActions.reconcile(event, fresh);
      expect(
        await ConversationMessageActions.react(
          context,
          event,
          fresh,
          '❤️',
          strict: true,
        ),
        isTrue,
      );
      expect(room.reactionsSent, 1);
    },
  );
  test('reaction keys distinguish accounts and source rooms', () {
    final a = ConversationRoom(
      ConversationClient(),
      '!one:example.invalid',
    ).message(r'$same', 'A');
    final b = ConversationRoom(
      ConversationClient(),
      '!two:example.invalid',
    ).message(r'$same', 'B');
    final c = ConversationRoom(
      ConversationClient('@other:example.invalid'),
      '!one:example.invalid',
    ).message(r'$same', 'C');
    expect(
      {
        ConversationMessageActions.key(a, '👍'),
        ConversationMessageActions.key(b, '👍'),
        ConversationMessageActions.key(c, '👍'),
      }.length,
      3,
    );
  });
  test(
    'quick-like fallback preserves explicit custom emoji and disabled preference',
    () async {
      expect(AppSettings.doubleTapReaction.defaultValue, '👍');
      await AppSettings.doubleTapReaction.setItem('❤️');
      expect(AppSettings.doubleTapReaction.value, '❤️');
      await AppSettings.doubleTapToReact.setItem(false);
      expect(AppSettings.doubleTapToReact.value, isFalse);
    },
  );
}
