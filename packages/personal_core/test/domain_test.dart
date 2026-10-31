// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const wa = ConversationRef(
  accountId: 'fixture',
  roomId: 'a',
  network: 'WhatsApp',
);
const ig = ConversationRef(
  accountId: 'fixture',
  roomId: 'b',
  network: 'Instagram',
);
const slack = ConversationRef(
  accountId: 'fixture',
  roomId: 'c',
  network: 'Slack',
);
const groupChat = ConversationRef(accountId: 'fixture', roomId: 'g');
final now = DateTime.utc(2026, 10, 4, 12);

MergedEvent<String> event(
  ConversationRef conversation,
  int minutes, {
  String id = 'event',
  bool outgoing = false,
  String value = 'synthetic',
  int revision = 0,
}) => MergedEvent(
  source: SourceEventRef(conversation: conversation, eventId: id),
  timestamp: now.subtract(Duration(minutes: minutes)),
  isOutgoing: outgoing,
  value: value,
  revision: revision,
);

TextDraft draft(
  String id, {
  String text = 'synthetic',
  int base = 0,
  Iterable<String> parents = const [],
  ConversationRef conversation = wa,
}) => TextDraft(
  conversation: conversation,
  operationId: id,
  text: text,
  updatedAt: now,
  baseRevision: base,
  parentOperationIds: parents,
);

void main() {
  group('Privacy: central emission guard', () {
    test('incognito suppresses all automatic markers and presence', () {
      const policy = PrivacyPolicy(incognito: true);
      expect(policy.allowAutomaticRead, isFalse);
      expect(policy.allowPrivateFullyRead, isFalse);
      expect(policy.allowTyping, isFalse);
      expect(policy.allowOnlinePresence, isFalse);
      expect(policy.allowRead(), isFalse);
    });
    test(
      'manual exception is explicit and does not enable automatic reads',
      () {
        const policy = PrivacyPolicy(incognito: true);
        expect(policy.allowRead(manual: true), isTrue);
        expect(policy.allowAutomaticRead, isFalse);
        expect(policy.allowTyping, isFalse);
      },
    );
    test('an accepted source reply can release only its source room', () {
      const policy = PrivacyPolicy(incognito: true);
      expect(
        policy.mayMarkAfterReply(
          target: const SendTarget(conversation: wa),
          readConversation: wa,
          accepted: true,
        ),
        isTrue,
      );
      expect(
        policy.mayMarkAfterReply(
          target: const SendTarget(conversation: wa),
          readConversation: ig,
          accepted: true,
        ),
        isFalse,
      );
      expect(
        policy.mayMarkAfterReply(
          target: const SendTarget(conversation: wa),
          readConversation: wa,
          accepted: false,
        ),
        isFalse,
      );
    });
    test('disabling typing independently remains effective', () {
      const policy = PrivacyPolicy(typingEnabled: false);
      expect(policy.allowRead(), isTrue);
      expect(policy.allowPrivateFullyRead, isTrue);
      expect(policy.allowTyping, isFalse);
    });
    test('own presence is never online, incognito or not', () {
      expect(const PrivacyPolicy().allowOnlinePresence, isFalse);
      expect(const PrivacyPolicy(incognito: true).allowOnlinePresence, isFalse);
      // Outside incognito the other emissions stay allowed.
      expect(const PrivacyPolicy().allowTyping, isTrue);
      expect(const PrivacyPolicy().allowAutomaticRead, isTrue);
    });
    test('leaving incognito creates no queued receipt flush', () {
      const policy = PrivacyPolicy();
      expect(policy.allowAutomaticRead, isTrue);
      // This value object retains no earlier event or source to flush.
      expect(policy.toString(), isNot(contains('fixture')));
    });
  });

  group('Reversible person groups', () {
    final manager = PersonGroupManager({
      wa: true,
      ig: true,
      slack: true,
      groupChat: false,
    });
    PersonGroup create() => manager.create(
      id: 'person-fixture',
      name: 'Synthetic person',
      members: [wa, ig],
      defaultConversation: wa,
    );
    test('only verified DMs, no display-name heuristics', () {
      expect(
        () => manager.create(
          id: 'person',
          name: 'Synthetic',
          members: [wa, groupChat],
          defaultConversation: wa,
        ),
        throwsArgumentError,
      );
      expect(
        () => PersonGroupManager({wa: true}).create(
          id: 'person',
          name: 'Synthetic',
          members: [wa, ig],
          defaultConversation: wa,
        ),
        throwsArgumentError,
      );
    });
    test('default must belong to merge; duplicate members rejected', () {
      expect(
        () => manager.create(
          id: 'person',
          name: 'Synthetic',
          members: [wa, ig],
          defaultConversation: slack,
        ),
        throwsArgumentError,
      );
      expect(
        () => manager.create(
          id: 'person',
          name: 'Synthetic',
          members: [wa, wa],
          defaultConversation: wa,
        ),
        throwsArgumentError,
      );
    });
    test('cross-account merges rejected by frozen contract', () {
      const other = ConversationRef(accountId: 'another', roomId: 'd');
      expect(
        () => PersonGroupManager({wa: true, other: true}).create(
          id: 'person',
          name: 'Synthetic',
          members: [wa, other],
          defaultConversation: wa,
        ),
        throwsArgumentError,
      );
    });
    test('adding same member is idempotent and list is immutable', () {
      final merged = create();
      expect(manager.addMember(merged, wa), same(merged));
      expect(() => merged.members.add(slack), throwsUnsupportedError);
    });
    test('removal and re-add preserve source identity', () {
      final expanded = manager.addMember(create(), slack);
      final reduced = manager.removeMember(expanded, ig)!;
      final restored = manager.addMember(reduced, ig);
      expect(restored.members, containsAll([wa, ig, slack]));
      expect(restored.revision, 3);
      expect(manager.unmerge(restored), containsAll([wa, ig, slack]));
    });
    test('removing default requires explicit valid replacement', () {
      final expanded = manager.addMember(create(), slack);
      expect(() => manager.removeMember(expanded, wa), throwsArgumentError);
      final result = manager.removeMember(
        expanded,
        wa,
        replacementDefault: ig,
      )!;
      expect(result.defaultRoomId, ig.roomId);
      expect(
        () => manager.removeMember(expanded, wa, replacementDefault: wa),
        throwsArgumentError,
      );
    });
    test('two-member merge dissolves without deleting rooms', () {
      expect(manager.removeMember(create(), wa), isNull);
      expect(manager.unmerge(create()), [wa, ig]);
    });
  });

  group('Merged send routing', () {
    final person = PersonGroup(
      id: 'person',
      name: 'Synthetic',
      members: [wa, ig],
      defaultRoomId: wa.roomId,
    );
    SendTarget route({
      MergedEvent<Object?>? recent,
      ConversationRef? override,
      SourceEventRef? reply,
    }) => MergedSendRouter.resolve(
      group: person,
      now: now,
      recentEvent: recent,
      override: override,
      replyTo: reply,
    );
    test('incoming reply follows source even after a long pause', () {
      expect(route(recent: event(ig, 120)).conversation, ig);
    });
    test('outgoing follows recent source through exactly 30 minutes', () {
      expect(route(recent: event(ig, 30, outgoing: true)).conversation, ig);
      expect(route(recent: event(ig, 31, outgoing: true)).conversation, wa);
    });
    test('explicit override wins over recent traffic', () {
      expect(route(recent: event(ig, 0), override: wa).conversation, wa);
    });
    test(
      'reply source cannot silently move to default or overridden network',
      () {
        final reply = event(ig, 40).source;
        expect(route(recent: event(wa, 0), reply: reply).conversation, ig);
        expect(() => route(override: wa, reply: reply), throwsArgumentError);
        expect(route(override: ig, reply: reply).conversation, ig);
      },
    );
    test('foreign source and overrides rejected', () {
      expect(() => route(override: slack), throwsArgumentError);
      expect(() => route(reply: event(slack, 0).source), throwsArgumentError);
      expect(() => route(recent: event(slack, 0)), throwsArgumentError);
    });
    test('no traffic and future outgoing use configured default', () {
      expect(route().conversation, wa);
      expect(route(recent: event(ig, -1, outgoing: true)).conversation, wa);
    });
  });

  group('Merged history frontier, dedupe and edits', () {
    test('global coverage waits for each source, not only fast source', () {
      final buffer = MergedTimelineBuffer<String>([wa, ig]);
      buffer.addPage(
        member: wa,
        events: [
          event(wa, 0),
          event(wa, 20, id: 'old'),
        ],
        hasMore: true,
        cursor: 'opaque-a',
      );
      expect(buffer.coveredEvents, isEmpty);
      buffer.addPage(
        member: ig,
        events: [
          event(ig, 5),
          event(ig, 10, id: 'old'),
        ],
        hasMore: true,
        cursor: 'opaque-b',
      );
      expect(buffer.coveredEvents.map((e) => e.source.conversation), [ig, wa]);
      expect(
        buffer.sourcesNeededThrough(now.subtract(const Duration(minutes: 15))),
        [ig],
      );
      buffer.addPage(
        member: ig,
        events: [event(ig, 15, id: 'older')],
        hasMore: false,
      );
      expect(buffer.coveredEvents.length, 4);
      buffer.addPage(member: wa, events: [], hasMore: false);
      expect(buffer.coveredEvents.length, 5);
      expect(buffer.hasMore, isFalse);
      expect(buffer.cursorFor(wa), isNull);
    });
    test('same event ID on two networks remains two distinct events', () {
      final buffer = MergedTimelineBuffer<String>([wa, ig]);
      buffer.addPage(member: wa, events: [event(wa, 0)], hasMore: false);
      buffer.addPage(member: ig, events: [event(ig, 0)], hasMore: false);
      expect(buffer.events.length, 2);
      expect(buffer.events.map((e) => e.source.key).toSet().length, 2);
    });
    test(
      'edit upsert preserves source and older duplicate cannot undo edit',
      () {
        final buffer = MergedTimelineBuffer<String>([wa, ig]);
        buffer.addLive(event(ig, 2));
        buffer.addLive(event(ig, 2, value: 'edited fixture', revision: 1));
        buffer.addLive(event(ig, 2));
        expect(buffer.events.single.value, 'edited fixture');
        expect(buffer.events.single.source.conversation, ig);
      },
    );
    test('tie order deterministic regardless of arrival sequence', () {
      final first = MergedTimelineBuffer<String>([wa, ig]);
      final second = MergedTimelineBuffer<String>([wa, ig]);
      final one = event(wa, 0, id: 'z');
      final two = event(ig, 0, id: 'a');
      first.addLive(one);
      first.addLive(two);
      second.addLive(two);
      second.addLive(one);
      expect(
        first.events.map((e) => e.source.key),
        second.events.map((e) => e.source.key),
      );
    });
    test('empty continuing page does not erase and remains unproven', () {
      final buffer = MergedTimelineBuffer<String>([wa]);
      buffer.addPage(member: wa, events: [], hasMore: true, cursor: 'next');
      expect(buffer.coveredEvents, isEmpty);
      expect(buffer.sourcesNeededThrough(now), [wa]);
      buffer.addPage(member: wa, events: [event(wa, 0)], hasMore: false);
      expect(buffer.coveredEvents.length, 1);
    });
    test('page validation is atomic; cursor required when continuing', () {
      final buffer = MergedTimelineBuffer<String>([wa]);
      expect(
        () => buffer.addPage(
          member: wa,
          events: [event(wa, 0), event(ig, 0)],
          hasMore: false,
        ),
        throwsArgumentError,
      );
      expect(buffer.events, isEmpty);
      expect(buffer.initialized, isFalse);
      expect(
        () => buffer.addPage(member: wa, events: [event(wa, 0)], hasMore: true),
        throwsArgumentError,
      );
      expect(buffer.events, isEmpty);
    });
    test('published events and members cannot be mutated', () {
      final buffer = MergedTimelineBuffer<String>([wa]);
      buffer.addLive(event(wa, 0));
      expect(() => buffer.events.clear(), throwsUnsupportedError);
      expect(buffer.members.clear, throwsUnsupportedError);
    });
  });

  group('Private organization metadata', () {
    test('label deletion leaves pinned nickname and room metadata intact', () {
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
        labelIds: ['work', 'home'],
        pinOrder: 2,
        nickname: 'Fixture',
      );
      final result = metadata.withoutDeletedLabel('work');
      expect(result.labelIds, {'home'});
      expect(result.pinOrder, 2);
      expect(result.nickname, 'Fixture');
      expect(metadata.labelIds, {'work', 'home'});
    });
    test('hidden labels and low priority stay outside Inbox', () {
      final hidden = PersonalLabel(
        id: 'work',
        name: 'Synthetic',
        showInInbox: false,
      );
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
        labelIds: ['work'],
      );
      expect(metadata.visibleInInbox([hidden]), isFalse);
      expect(
        metadata.withoutDeletedLabel('work').visibleInInbox([hidden]),
        isTrue,
      );
      expect(metadata.setLowPriority(true).visibleInInbox([]), isFalse);
    });
    test('activity unarchives but does not undo low priority/mute', () {
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
        archived: true,
        lowPriority: true,
        muted: true,
      ).onActivity();
      expect(metadata.archived, isFalse);
      expect(metadata.lowPriority, isTrue);
      expect(metadata.muted, isTrue);
      expect(metadata.visibleInInbox([]), isFalse);
    });
    test('a timed mute ends by itself and round-trips through JSON', () {
      final now = DateTime.utc(2026, 10, 21, 12);
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
      ).setMuted(true, until: now.add(const Duration(hours: 1)));
      expect(metadata.mutedAt(now), isTrue);
      expect(metadata.mutedAt(now.add(const Duration(hours: 2))), isFalse);
      final json = metadata.toJson();
      expect(json['muted'], isTrue);
      expect(json['mutedUntil'], '2026-10-21T13:00:00.000Z');
      final parsed = ConversationMetadata.fromJson(json.cast());
      expect(parsed.mutedUntil, now.add(const Duration(hours: 1)));
      // "Until I unmute" clears the end; unmuting clears both.
      final always = parsed.setMuted(true);
      expect(always.toJson()['mutedUntil'], isNull);
      expect(always.mutedAt(now.add(const Duration(days: 400))), isTrue);
      expect(parsed.setMuted(false).toJson()['muted'], isFalse);
      expect(parsed.setMuted(false).mutedUntil, isNull);
      // An ended mute notifies again; an active one outranks "All messages".
      final ended = ConversationMetadata(
        entityId: 'synthetic',
        muted: true,
        mutedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(ended.muted, isFalse);
      expect(ended.shouldNotify(), isTrue);
      final activeAll = ConversationMetadata(
        entityId: 'synthetic',
        muted: true,
        notificationMode: PersonalNotificationMode.all,
      );
      expect(activeAll.shouldNotify(), isFalse);
      expect(activeAll.shouldNotify(mentioned: true), isTrue);
    });
    test('only mentions and thread replies bypass mute and low priority', () {
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
        lowPriority: true,
      );
      expect(metadata.shouldNotify(), isFalse);
      expect(metadata.shouldNotify(mentioned: true), isTrue);
      expect(metadata.shouldNotify(threadReplyToMe: true), isTrue);
    });
    test('optional private overrides can be cleared explicitly', () {
      final metadata = ConversationMetadata(
        entityId: 'synthetic',
        pinOrder: 0,
        nickname: 'Fixture',
        avatarAsset: 'fixture',
        theme: const ChatTheme(backgroundColor: 1),
      );
      final cleared = metadata
          .setPin(null)
          .setNickname(null)
          .setAvatar(null)
          .setTheme(null);
      expect(cleared.isPinned, isFalse);
      expect(cleared.nickname, isNull);
      expect(cleared.avatarAsset, isNull);
      expect(cleared.theme, isNull);
    });
    test('metadata roundtrip is stable and diagnostic output is redacted', () {
      final metadata = ConversationMetadata(
        entityId: 'private fixture ID',
        labelIds: ['b', 'a'],
        nickname: 'private fixture nickname',
        theme: const ChatTheme(outgoingColor: 123),
      );
      final result = ConversationMetadata.fromJson(
        jsonDecode(jsonEncode(metadata.toJson())) as Map<String, dynamic>,
      );
      expect(result.toJson(), metadata.toJson());
      expect(metadata.toString(), isNot(contains('private fixture')));
      expect(metadata.labelIds.clear, throwsUnsupportedError);
    });
    test('bookmark identity includes source and stores no copied content', () {
      final a = BookmarkRef(source: event(wa, 0).source, createdAt: now);
      final b = BookmarkRef(source: event(ig, 0).source, createdAt: now);
      expect(a.key, isNot(b.key));
      expect(a.toJson().containsKey('text'), isFalse);
      expect(
        BookmarkRef.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>,
        ).key,
        a.key,
      );
    });
  });

  group('Causal draft conflicts', () {
    test('two devices same revision preserve both text branches', () {
      final store = RevisionedDraftStore();
      expect(store.apply(draft('device-a')), DraftApplyResult.accepted);
      expect(
        store.apply(draft('device-b', text: 'another fixture')),
        DraftApplyResult.conflict,
      );
      expect(store.branchesFor(wa).length, 2);
    });
    test('same revision but wrong parent cannot overwrite another device', () {
      final store = RevisionedDraftStore();
      store.apply(draft('device-b'));
      expect(
        store.apply(draft('device-a-next', base: 1, parents: ['device-a'])),
        DraftApplyResult.conflict,
      );
      expect(store.branchesFor(wa).length, 2);
      store.apply(draft('device-a'));
      expect(store.branchesFor(wa).map((d) => d.operationId), [
        'device-a-next',
        'device-b',
      ]);
    });
    test('causal successors replace only known ancestors', () {
      final store = RevisionedDraftStore();
      store.apply(draft('a'));
      store.apply(draft('a-next', base: 1, parents: ['a']));
      expect(store.branchesFor(wa).single.operationId, 'a-next');
      expect(store.hasConflict(wa), isFalse);
    });
    test('out-of-order delivery converges to the same tips', () {
      final ordered = RevisionedDraftStore();
      final reordered = RevisionedDraftStore();
      final values = [
        draft('a'),
        draft('b'),
        draft('a2', base: 1, parents: ['a']),
      ];
      for (final value in values) {
        ordered.apply(value);
      }
      for (final value in values.reversed) {
        reordered.apply(value);
      }
      expect(
        ordered.branchesFor(wa).map((d) => d.operationId),
        reordered.branchesFor(wa).map((d) => d.operationId),
      );
    });
    test('concurrent delete does not silently erase new text', () {
      final store = RevisionedDraftStore();
      store.apply(draft('a'));
      store.apply(draft('clear', base: 1, parents: ['a'], text: ''));
      store.apply(
        draft('edit', base: 1, parents: ['a'], text: 'fresh fixture'),
      );
      expect(store.hasConflict(wa), isTrue);
      expect(store.hasDraft(wa), isTrue);
      expect(store.branchesFor(wa).map((d) => d.text), contains(''));
    });
    test(
      'explicit resolution acknowledges all branches and syncs causally',
      () {
        final store = RevisionedDraftStore();
        store.apply(draft('a'));
        store.apply(draft('b'));
        final resolved = store.resolve(
          conversation: wa,
          expectedBranchIds: {'a', 'b'},
          selectedBranchId: 'a',
          operationId: 'resolution',
          updatedAt: now,
        );
        expect(store.hasConflict(wa), isFalse);
        expect(resolved.parentOperationIds, {'a', 'b'});
        final remote = RevisionedDraftStore();
        remote.apply(resolved);
        remote.apply(draft('b'));
        remote.apply(draft('a'));
        expect(remote.hasConflict(wa), isFalse);
        expect(remote.branchesFor(wa).single.operationId, 'resolution');
      },
    );
    test('changed branch set blocks stale resolution', () {
      final store = RevisionedDraftStore();
      store.apply(draft('a'));
      store.apply(draft('b'));
      store.apply(draft('c'));
      expect(
        () => store.resolve(
          conversation: wa,
          expectedBranchIds: {'a', 'b'},
          selectedBranchId: 'a',
          operationId: 'resolution',
          updatedAt: now,
        ),
        throwsStateError,
      );
      expect(store.branchesFor(wa).length, 3);
    });
    test(
      'replay is idempotent; reused op ID with changed content rejected',
      () {
        final store = RevisionedDraftStore();
        store.apply(draft('a'));
        expect(store.apply(draft('a')), DraftApplyResult.duplicate);
        expect(
          () => store.apply(draft('a', text: 'changed fixture')),
          throwsStateError,
        );
      },
    );
    test('cross-room parent and revision cycles are rejected atomically', () {
      final store = RevisionedDraftStore();
      store.apply(draft('a'));
      expect(
        () =>
            store.apply(draft('b', base: 1, parents: ['a'], conversation: ig)),
        throwsStateError,
      );
      expect(
        () => store.apply(draft('jump', base: 9, parents: ['a'])),
        throwsStateError,
      );
      expect(store.branchesFor(wa).length, 1);
    });
    test('draft roundtrip and collections do not expose mutable state', () {
      final d = draft('b', base: 1, parents: ['a']);
      final decoded = TextDraft.fromJson(
        jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.toJson(), d.toJson());
      expect(d.parentOperationIds.clear, throwsUnsupportedError);
      expect(d.toString(), isNot(contains('synthetic')));
    });
  });

  group('Reminders without a send side effect', () {
    final reminder = ChatReminder(
      id: 'fixture',
      entityId: 'person',
      dueAt: now,
    );
    test('deadline is inclusive and triggers only once', () {
      expect(
        reminder.evaluate(now.subtract(const Duration(seconds: 1))).state,
        ReminderState.scheduled,
      );
      final due = reminder.evaluate(now);
      expect(due.state, ReminderState.due);
      expect(due.dueAtTime(now), isFalse);
    });
    test(
      'until reply dismisses only on new incoming, regardless retains schedule',
      () {
        expect(reminder.onIncoming().state, ReminderState.dismissed);
        final regardless = ChatReminder(
          id: 'fixture',
          entityId: 'person',
          dueAt: now,
          dismissOnIncomingMessage: false,
        );
        expect(regardless.onIncoming().state, ReminderState.scheduled);
      },
    );
    test('cancelled or dismissed reminders cannot become due again', () {
      expect(reminder.cancel().evaluate(now).state, ReminderState.cancelled);
      expect(reminder.dismiss().evaluate(now).state, ReminderState.dismissed);
    });
    test('UTC roundtrip preserves deadline and semantics', () {
      final value = ChatReminder.fromJson(
        jsonDecode(jsonEncode(reminder.toJson())) as Map<String, dynamic>,
      );
      expect(value.dueAt, reminder.dueAt);
      expect(value.entityId, reminder.entityId);
      expect(value.archiveUntilDue, isTrue);
    });
  });

  group('Search predicates', () {
    ConversationSearchEntry conversation({
      bool readOnly = false,
      bool group = false,
    }) => ConversationSearchEntry(
      conversation: wa,
      metadata: ConversationMetadata(
        entityId: 'synthetic',
        labelIds: ['work'],
        nickname: 'My fixture',
      ),
      displayName: 'Source name',
      unreadCount: 2,
      hasDraft: true,
      lastIncomingAt: now,
      lastOutgoingAt: now.subtract(const Duration(seconds: 1)),
      readOnly: readOnly,
      isGroup: group,
    );
    test('filters combine across nickname, labels, unread and unanswered', () {
      final query = PersonalSearchQuery(
        text: 'my fixture',
        networks: ['WhatsApp'],
        labelIds: ['work'],
        groups: false,
        unreadOnly: true,
        draftsOnly: true,
        unansweredOnly: true,
      );
      expect(query.matchesConversation(conversation()), isTrue);
      expect(query.matchesConversation(conversation(group: true)), isFalse);
      expect(query.matchesConversation(conversation(readOnly: true)), isFalse);
    });
    test(
      'search finds transcripts and file names, excludes redacted content',
      () {
        final query = PersonalSearchQuery(text: 'invoice fixture');
        MessageSearchEntry item({bool redacted = false}) => MessageSearchEntry(
          source: event(wa, 0).source,
          timestamp: now,
          transcript: 'Invoice fixture',
          redacted: redacted,
        );
        expect(query.matchesMessage(item()), isTrue);
        expect(query.matchesMessage(item(redacted: true)), isFalse);
        expect(
          PersonalSearchQuery(text: 'invoice').matchesMessage(
            MessageSearchEntry(
              source: event(wa, 0).source,
              timestamp: now,
              fileName: 'Invoice.pdf',
            ),
          ),
          isTrue,
        );
      },
    );
    test('time filters have strict documented boundaries', () {
      final item = MessageSearchEntry(
        source: event(wa, 0).source,
        timestamp: now,
      );
      expect(PersonalSearchQuery(after: now).matchesMessage(item), isFalse);
      expect(PersonalSearchQuery(before: now).matchesMessage(item), isFalse);
      expect(
        PersonalSearchQuery(
          after: now.subtract(const Duration(seconds: 1)),
          before: now.add(const Duration(seconds: 1)),
        ).matchesMessage(item),
        isTrue,
      );
      expect(
        () => PersonalSearchQuery(after: now, before: now),
        throwsArgumentError,
      );
    });
    test('bookmark and message-type filters respect original source', () {
      final item = MessageSearchEntry(
        source: event(ig, 0).source,
        timestamp: now,
        messageType: 'voice',
        bookmarked: true,
        isOutgoing: true,
      );
      expect(
        PersonalSearchQuery(
          networks: ['Instagram'],
          messageTypes: ['voice'],
          outgoing: true,
          bookmarksOnly: true,
        ).matchesMessage(item),
        isTrue,
      );
      expect(
        PersonalSearchQuery(networks: ['WhatsApp']).matchesMessage(item),
        isFalse,
      );
      expect(
        PersonalSearchQuery(messageTypes: ['image']).matchesMessage(item),
        isFalse,
      );
    });
    test(
      'message conversation filters fail closed without matching context',
      () {
        final item = MessageSearchEntry(
          source: event(wa, 0).source,
          timestamp: now,
          text: 'body fixture',
        );
        final query = PersonalSearchQuery(
          text: 'body',
          labelIds: ['work'],
          groups: false,
          unreadOnly: true,
        );
        expect(query.matchesMessage(item), isFalse);
        expect(
          query.matchesMessage(item, conversation: conversation()),
          isTrue,
        );
        final foreign = MessageSearchEntry(
          source: event(ig, 0).source,
          timestamp: now,
          text: 'body fixture',
        );
        expect(
          query.matchesMessage(foreign, conversation: conversation()),
          isFalse,
        );
      },
    );
  });
}
