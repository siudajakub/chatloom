// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

class MemoryStore {
  final data = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  String? failNextKey;
  Future<Map<String, dynamic>?> read(String key) async =>
      data[key] == null ? null : copy(data[key]!);
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (key == failNextKey) {
      failNextKey = null;
      throw StateError('Injected persistence failure');
    }
    writes.add(key);
    data[key] = copy(value);
  }

  Map<String, dynamic> copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  /// Whether [opId] carries a durable seen marker.
  bool seen(String opId) =>
      (data[PersonalReplica.seenKeyOf(opId)]?['ids'] as List? ?? const [])
          .contains(opId);
}

const conversation = ConversationRef(
  accountId: 'fixture',
  roomId: 'fixture-room',
);
const source = SourceEventRef(conversation: conversation, eventId: r'$fixture');
final clock = DateTime.utc(2026, 10, 4);
int id = 0;
PersonalReplica replica(MemoryStore store) => PersonalReplica(
  read: store.read,
  write: store.write,
  newOperationId: () => 'fixture-op-${id++}',
  clock: () => clock,
)..restore(store.data);
PersonalOperation result(
  String id,
  String entity,
  String kind,
  Map<String, dynamic> payload,
) => PersonalOperation(
  opId: id,
  kind: kind,
  entityId: entity,
  baseRevision: payload['revision'] as int? ?? 0,
  createdAt: clock,
  payload: payload,
);
PersonalOperation metadataAck(PersonalOperation command, int revision) =>
    result('ack:${command.opId}', command.entityId, 'metadata.result', {
      'revision': revision,
      'acceptedOpId': command.opId,
      'value': command.payload['value'],
      'deleted': command.kind == 'metadata.delete',
    });

void main() {
  setUp(() => id = 0);
  test(
    'network defaults and chat exceptions survive restart, ACK and conflict',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      const key = 'network-policy:telegram';
      final policy = NetworkPreferences(
        groupPlacement: ChatPlacement.groups,
        showInGroups: false,
        groupNotifications: PersonalNotificationMode.muted,
      ).toJson();
      await r.queueMetadata(key, policy);
      final op = (await r.markPublishing(r.pending.keys.single))!;
      expect(replica(store).values[key], policy);
      await r.acceptResult(metadataAck(op, 1));
      final chat = ConversationMetadata(
        entityId: 'fixture',
        placement: ChatPlacement.inbox,
        notificationMode: PersonalNotificationMode.mentionsOnly,
      ).setIgnored(true);
      await r.queueMetadata(
        'org:fixture',
        chat.toJson().cast<String, dynamic>(),
      );
      final restarted = replica(store);
      expect(
        NetworkPreferences.fromJson(
          restarted.values[key]!, 'telegram',
        ).showInGroups,
        isFalse,
      );
      expect(
        NetworkPreferences.fromJson(
          restarted.values[key]!,
          'telegram',
        ).groupNotifications,
        PersonalNotificationMode.muted,
      );
      final restored = ConversationMetadata.fromJson(
        restarted.values['org:fixture']!,
      );
      expect(restored.ignored, isTrue);
      expect(restored.restoreIgnored().placement, ChatPlacement.inbox);
      expect(
        restored.restoreIgnored().notificationMode,
        PersonalNotificationMode.mentionsOnly,
      );
      await restarted.queueMetadata(key, {
        ...policy,
        'groupNotifications': 'mentionsOnly',
      });
      final own = restarted.pending.values.singleWhere(
        (op) => op.entityId == key,
      );
      await restarted.markPublishing(own.opId);
      // Another device changed the same network default meanwhile.
      final remote = {...policy, 'groupNotifications': 'all'};
      await restarted.acceptResult(
        result('remote-conflict', key, 'metadata.result', {
          'state': 'conflict',
          'revision': 2,
          'acceptedOpId': own.opId,
          'existingValue': remote,
          'proposedValue': own.payload['value'],
        }),
      );
      expect(replica(store).conflicts, contains(key));
      expect(replica(store).conflicts[key]!['existingValue'], remote);
    },
  );
  test(
    'old metadata retains mentions-only semantics and restores placement',
    () {
      final old = ConversationMetadata.fromJson({
        'entityId': 'fixture',
        'muted': true,
      });
      expect(old.shouldNotify(), isFalse);
      expect(old.shouldNotify(mentioned: true), isTrue);
      expect(old.setIgnored(true).shouldNotify(mentioned: true), isFalse);
      expect(old.setIgnored(true).restoreIgnored().muted, isTrue);
      expect(
        old.restoreIgnored(inheritedIgnored: true).placement,
        ChatPlacement.inbox,
      );
    },
  );

  test(
    'restoring ignored chat stays durable while original ignore awaits ACK',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      const key = 'org:fixture';
      final original = ConversationMetadata(
        entityId: 'fixture',
        notificationMode: PersonalNotificationMode.mentionsOnly,
      );
      await r.queueMetadata(
        key,
        original.setIgnored(true).toJson().cast<String, dynamic>(),
      );
      final ignore = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata(
        key,
        original
            .setIgnored(true)
            .restoreIgnored()
            .toJson()
            .cast<String, dynamic>(),
      );
      final restarted = replica(store);
      expect(restarted.values[key]!['ignored'], isFalse);
      expect(restarted.pending[ignore.opId]!.toJson(), ignore.toJson());
      await restarted.acceptResult(metadataAck(ignore, 1));
      final restore = restarted.pending.values.single;
      expect(restore.baseRevision, 1);
      expect((restore.payload['value'] as Map)['ignored'], isFalse);
      expect(replica(store).values[key]!['notificationMode'], 'mentionsOnly');
    },
  );

  group('durable transcription cancellation', () {
    Future<PersonalOperation> request(PersonalReplica r) async {
      final job = TranscriptionJob(
        id: 'transcript-fixture',
        source: source,
        state: JobState.waitingSync,
      );
      return r.stageCommand(
        'transcript.request',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: job.toJson().cast<String, dynamic>(),
      );
    }

    PersonalOperation ack(
      PersonalOperation op, {
      int revision = 1,
      String state = 'queued',
      String? actualState,
    }) => result('ack:${op.opId}:$revision', op.entityId, 'transcript.result', {
      'revision': revision,
      'acceptedOpId': op.opId,
      'state': state,
      if (state == 'conflict') 'errorCode': 'conflict',
      if (actualState != null) 'actualState': actualState,
    });
    test(
      'offline cancel is durable and a stale drain cannot publish it',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        expect(
          await r.cancelTranscript(op.entityId),
          TranscriptCancellation.cancelledLocally,
        );
        expect(await r.markPublishing(op.opId), isNull);
        final restarted = replica(store);
        expect(restarted.pending, isEmpty);
        expect(restarted.transcripts[op.entityId]!.state, JobState.cancelled);
        expect(restarted.transcriptCancellations, isEmpty);
      },
    );
    test(
      'publication wins race; intent survives restart and queues cancel at ACK revision',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        final publication = r.markPublishing(op.opId);
        final cancellation = r.cancelTranscript(op.entityId);
        expect(await publication, isNotNull);
        expect(
          await cancellation,
          TranscriptCancellation.waitingAcknowledgement,
        );
        final restarted = replica(store);
        expect(restarted.pending[op.opId]!.kind, 'transcript.request');
        expect(restarted.transcripts[op.entityId]!.state, JobState.waitingSync);
        expect(restarted.transcriptCancellations, contains(op.entityId));
        await restarted.acceptResult(ack(op, revision: 3));
        final cancel = restarted.pending.values.single;
        expect(cancel.kind, 'transcript.cancel');
        expect(cancel.baseRevision, 3);
        expect(restarted.transcripts[op.entityId]!.state, JobState.queued);
        await restarted.markPublishing(cancel.opId);
        await restarted.acceptResult(
          ack(cancel, revision: 4, state: 'cancelled'),
        );
        expect(replica(store).pending, isEmpty);
        expect(restarted.transcriptCancellations, isEmpty);
        expect(restarted.transcripts[op.entityId]!.state, JobState.cancelled);
      },
    );
    test('cancel wins race before publication; no request remains', () async {
      final store = MemoryStore();
      final r = replica(store);
      final op = await request(r);
      final cancellation = r.cancelTranscript(op.entityId);
      final publication = r.markPublishing(op.opId);
      expect(await cancellation, TranscriptCancellation.cancelledLocally);
      expect(await publication, isNull);
    });
    test(
      'failed cancel commit retains the durable request for retry',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        store.failNextKey = 'replica:${op.entityId}';
        await expectLater(r.cancelTranscript(op.entityId), throwsStateError);
        expect(replica(store).pending, contains(op.opId));
        expect(r.transcripts[op.entityId]!.state, JobState.waitingSync);
        await r.cancelTranscript(op.entityId);
        expect(replica(store).pending, isEmpty);
      },
    );
    test('revision conflict requeues only cancel with new revision', () async {
      final store = MemoryStore();
      final r = replica(store);
      final op = await request(r);
      await r.markPublishing(op.opId);
      await r.acceptResult(ack(op));
      await r.cancelTranscript(op.entityId);
      final firstCancel = r.pending.values.single;
      await r.markPublishing(firstCancel.opId);
      await r.acceptResult(
        ack(
          firstCancel,
          revision: 2,
          state: 'conflict',
          actualState: 'processing',
        ),
      );
      final nextCancel = r.pending.values.single;
      expect(nextCancel.kind, 'transcript.cancel');
      expect(nextCancel.opId, isNot(firstCancel.opId));
      expect(nextCancel.baseRevision, 2);
      expect(r.transcripts[op.entityId]!.state, JobState.processing);
      expect(replica(store).transcriptCancellations, contains(op.entityId));
    });
    test(
      'duplicate cancellation and lost ACK retain one immutable cancel',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        await r.markPublishing(op.opId);
        await r.acceptResult(ack(op));
        await r.cancelTranscript(op.entityId);
        final cancel = r.pending.values.single;
        await r.markPublishing(cancel.opId);
        await r.cancelTranscript(op.entityId);
        final restarted = replica(store);
        expect(restarted.pending.keys, [cancel.opId]);
        expect(
          (await restarted.markPublishing(cancel.opId))!.toJson(),
          cancel.toJson(),
        );
      },
    );
    test(
      'completion before cancel ACK stays done; no further paid request',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        await r.markPublishing(op.opId);
        await r.cancelTranscript(op.entityId);
        await r.acceptResult(ack(op, revision: 2, state: 'done'));
        expect(r.pending, isEmpty);
        expect(r.transcriptCancellations, isEmpty);
        expect(r.transcripts[op.entityId]!.state, JobState.done);
        expect(
          await r.cancelTranscript(op.entityId),
          TranscriptCancellation.alreadyFinished,
        );
      },
    );
    test(
      'ACK seen-marker failure cannot duplicate queued cancellation after restart',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        await r.markPublishing(op.opId);
        await r.cancelTranscript(op.entityId);
        final acknowledged = ack(op);
        store.failNextKey = PersonalReplica.seenKeyOf(acknowledged.opId);
        await expectLater(r.acceptResult(acknowledged), throwsStateError);
        final cancel = r.pending.values.single;
        final restarted = replica(store);
        await restarted.acceptResult(acknowledged);
        expect(restarted.pending.keys, [cancel.opId]);
        expect(restarted.pending.values.single.kind, 'transcript.cancel');
      },
    );
    test(
      'rejected request without an existing job stops deferred cancellation',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        await r.markPublishing(op.opId);
        await r.cancelTranscript(op.entityId);
        await r.acceptResult(
          result('rejected', op.entityId, 'transcript.result', {
            'revision': 0,
            'acceptedOpId': op.opId,
            'state': 'conflict',
            'actualState': null,
            'errorCode': 'invalid_source',
          }),
        );
        expect(replica(store).pending, isEmpty);
        expect(r.transcriptCancellations, isEmpty);
        expect(r.transcripts[op.entityId]!.state, JobState.failed);
      },
    );
    test(
      'not_found cancel rejection cannot generate another cancel opId',
      () async {
        final store = MemoryStore();
        final r = replica(store);
        final op = await request(r);
        await r.markPublishing(op.opId);
        await r.acceptResult(ack(op));
        await r.cancelTranscript(op.entityId);
        final cancel = r.pending.values.single;
        await r.markPublishing(cancel.opId);
        await r.acceptResult(
          result('missing', op.entityId, 'transcript.result', {
            'revision': 1,
            'acceptedOpId': cancel.opId,
            'state': 'conflict',
            'actualState': null,
            'errorCode': 'not_found',
          }),
        );
        expect(replica(store).pending, isEmpty);
        expect(r.transcriptCancellations, isEmpty);
        expect(r.transcripts[op.entityId]!.state, JobState.failed);
      },
    );
  });
  test(
    'foreign active job cannot be marked cancelled by withdrawing our unsent request',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final job = TranscriptionJob(
        id: 'transcript-fixture',
        source: source,
        state: JobState.waitingSync,
      );
      final op = await r.stageCommand(
        'transcript.request',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: job.toJson().cast<String, dynamic>(),
      );
      await r.acceptResult(
        result('other-device-processing', op.entityId, 'transcript.result', {
          'revision': 2,
          'acceptedOpId': 'other-device-request',
          'state': 'processing',
        }),
      );
      expect(
        await r.cancelTranscript(op.entityId),
        TranscriptCancellation.queued,
      );
      expect(r.pending, isNot(contains(op.opId)));
      final cancel = r.pending.values.single;
      expect(cancel.kind, 'transcript.cancel');
      expect(cancel.baseRevision, 2);
      expect(r.transcripts[op.entityId]!.state, JobState.processing);
      expect(replica(store).transcriptCancellations, contains(op.entityId));
    },
  );
  test(
    'foreign completion removes our unsent duplicate but keeps completed state',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final job = TranscriptionJob(
        id: 'transcript-fixture',
        source: source,
        state: JobState.waitingSync,
      );
      final op = await r.stageCommand(
        'transcript.request',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: job.toJson().cast<String, dynamic>(),
      );
      await r.acceptResult(
        result('other-device-done', op.entityId, 'transcript.result', {
          'revision': 2,
          'acceptedOpId': 'other-device-request',
          'state': 'done',
        }),
      );
      expect(
        await r.cancelTranscript(op.entityId),
        TranscriptCancellation.alreadyFinished,
      );
      expect(replica(store).pending, isEmpty);
      expect(r.transcripts[op.entityId]!.state, JobState.done);
    },
  );
  test(
    'offline autosaves are durable and coalesce an unattempted command',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await Future.wait([
        r.queueMetadata('draft:fixture', {'text': 'a'}),
        r.queueMetadata('draft:fixture', {'text': 'ab'}),
        r.queueMetadata('draft:fixture', {'text': 'abc'}),
      ]);
      expect(r.pending.length, 1);
      expect(r.pending.values.single.payload['value'], {'text': 'abc'});
      expect(replica(store).values['draft:fixture'], {'text': 'abc'});
      expect(r.hasUnattemptedCommands, isTrue);
    },
  );
  test(
    'attempted command is immutable; newer keystrokes wait for its ACK',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'first'});
      final first = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata('draft:fixture', {'text': 'newest'});
      expect(r.pending.values.single.payload, first.payload);
      expect(r.values['draft:fixture'], {'text': 'newest'});
      await r.acceptResult(metadataAck(first, 1));
      expect(r.pending.values.single.baseRevision, 1);
      expect(r.pending.values.single.payload['value'], {'text': 'newest'});
      final next = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(metadataAck(next, 2));
      expect(r.pending, isEmpty);
      expect(r.revisions['draft:fixture'], 2);
      expect(r.conflicts, isEmpty);
    },
  );
  test(
    'fast metadata ACK cannot be reverted by later optimistic writes',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('nickname:fixture', {'name': 'Fixture'});
      final command = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(metadataAck(command, 1));
      expect(r.revisions['nickname:fixture'], 1);
      expect(replica(store).revisions['nickname:fixture'], 1);
      expect(r.pending, isEmpty);
    },
  );
  test('fast completed transcript stays done through restart', () async {
    final store = MemoryStore();
    final r = replica(store);
    final job = TranscriptionJob(
      id: 'transcript-fixture',
      source: source,
      state: JobState.waitingSync,
    );
    final command = await r.stageCommand(
      'transcript.request',
      job.id,
      job.toJson().cast<String, dynamic>(),
      optimisticJob: job.toJson().cast<String, dynamic>(),
    );
    expect(r.transcripts[job.id]!.state, JobState.waitingSync);
    await r.markPublishing(command.opId);
    await r.acceptResult(
      result('done', job.id, 'transcript.result', {
        ...job.toJson(),
        'state': 'done',
        'text': 'synthetic transcript',
        'revision': 4,
        'acceptedOpId': command.opId,
      }),
    );
    expect(r.transcripts[job.id]!.state, JobState.done);
    expect(replica(store).transcripts[job.id]!.state, JobState.done);
    expect(r.revisions[job.id], 4);
  });
  test(
    'genuine remote draft conflict retains local and both copies durably',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'mine'});
      final command = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(
        result('conflict', 'draft:fixture', 'metadata.result', {
          'state': 'conflict',
          'revision': 7,
          'acceptedOpId': command.opId,
          'existingValue': {'text': 'remote'},
          'proposedValue': {'text': 'mine'},
        }),
      );
      await r.queueMetadata('draft:fixture', {'text': 'mine continued'});
      expect(r.pending, isEmpty);
      final restored = replica(store);
      expect(restored.values['draft:fixture'], {'text': 'mine continued'});
      expect(restored.conflicts['draft:fixture']!['existingValue'], {
        'text': 'remote',
      });
      expect(restored.conflicts['draft:fixture']!['proposedValue'], {
        'text': 'mine',
      });
      expect(restored.revisions['draft:fixture'], 7);
    },
  );
  test(
    'explicit conflict resolution uses expected server revision and clears only after ACK',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'mine'});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(
        result('conflict', 'draft:fixture', 'metadata.result', {
          'state': 'conflict',
          'revision': 3,
          'acceptedOpId': mine.opId,
          'existingValue': {'text': 'other'},
          'proposedValue': {'text': 'mine'},
        }),
      );
      final resolution = await r.stageCommand('metadata.put', 'draft:fixture', {
        'value': {'text': 'combined'},
      }, baseRevision: 3);
      expect(r.conflicts.containsKey('draft:fixture'), isTrue);
      await r.acceptResult(metadataAck(resolution, 4));
      expect(r.conflicts, isEmpty);
      expect(r.values['draft:fixture'], {'text': 'combined'});
    },
  );
  test(
    'failure before result commit does not mark seen or drop pending',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'mine'});
      final command = r.pending.values.single;
      store.failNextKey = 'replica:draft:fixture';
      await expectLater(
        r.acceptResult(metadataAck(command, 1)),
        throwsStateError,
      );
      expect(store.seen('ack:${command.opId}'), isFalse);
      expect(r.pending.containsKey(command.opId), isTrue);
      await r.acceptResult(metadataAck(command, 1));
      expect(r.pending, isEmpty);
    },
  );
  test(
    'crash after durable conflict but before seen restores revision and copies',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'mine'});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      final conflict = result('conflict', 'draft:fixture', 'metadata.result', {
        'state': 'conflict',
        'revision': 9,
        'acceptedOpId': mine.opId,
        'existingValue': {'text': 'remote'},
        'proposedValue': {'text': 'mine'},
      });
      store.failNextKey = PersonalReplica.seenKeyOf('conflict');
      await expectLater(r.acceptResult(conflict), throwsStateError);
      final restored = replica(store);
      expect(restored.revisions['draft:fixture'], 9);
      expect(restored.conflicts['draft:fixture']!['proposedValue'], {
        'text': 'mine',
      });
      await restored.acceptResult(conflict);
      expect(store.seen('conflict'), isTrue);
      expect(
        store.writes.indexOf('replica:draft:fixture'),
        lessThan(
          store.writes.indexOf(PersonalReplica.seenKeyOf('conflict')),
        ),
      );
    },
  );
  test(
    'autosave record failure preserves prior durable draft and queue remains usable',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'saved'});
      store.failNextKey = 'replica:draft:fixture';
      await expectLater(
        r.queueMetadata('draft:fixture', {'text': 'not saved'}),
        throwsStateError,
      );
      expect(r.values['draft:fixture'], {'text': 'saved'});
      await r.queueMetadata('draft:fixture', {'text': 'next saved'});
      expect(replica(store).values['draft:fixture'], {'text': 'next saved'});
    },
  );
  test(
    'schedule placeholder precedes any publication and survives restart',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final job = ScheduledSend(
        id: 'schedule',
        target: const SendTarget(conversation: conversation),
        dueAt: clock.add(const Duration(hours: 1)),
        content: {'msgtype': 'm.text', 'body': 'fixture'},
        transactionId: 'fixed-tx',
      );
      await r.stageCommand(
        'schedule.create',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: {...job.toJson(), 'state': 'waitingSync'},
      );
      final restored = replica(store);
      expect(restored.schedules[job.id]!['state'], 'waitingSync');
      expect(restored.pending.length, 1);
      expect(
        ScheduledSend.fromJson(restored.schedules[job.id]!).target.conversation,
        conversation,
      );
    },
  );
  test(
    'every job transition updates revision; retry/cancel defaults to latest ACK',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.acceptResult(
        result('queued', 'schedule', 'schedule.result', {
          'id': 'schedule',
          'revision': 1,
          'state': 'queued',
        }),
      );
      await r.acceptResult(
        result('paused', 'schedule', 'schedule.result', {
          'id': 'schedule',
          'revision': 8,
          'state': 'paused',
        }),
      );
      final cancel = await r.stageCommand('schedule.cancel', 'schedule', {
        'id': 'schedule',
      });
      expect(cancel.baseRevision, 8);
      await r.acceptResult(
        result('cancelled', 'schedule', 'schedule.result', {
          'id': 'schedule',
          'revision': 9,
          'state': 'cancelled',
          'acceptedOpId': cancel.opId,
        }),
      );
      expect(replica(store).revisions['schedule'], 9);
    },
  );
  test('reminder results are exposed and persisted for due hooks', () async {
    final store = MemoryStore();
    final r = replica(store);
    await r.acceptResult(
      result('due', 'reminder', 'reminder.result', {
        'id': 'reminder',
        'conversation': conversation.toJson(),
        'revision': 5,
        'state': 'done',
        'dueAt': clock.toIso8601String(),
      }),
    );
    expect(r.reminders['reminder']!['state'], 'done');
    expect(replica(store).reminders['reminder']!['state'], 'done');
    expect(r.revisions['reminder'], 5);
  });
  test('older job result cannot regress completed state or revision', () async {
    final store = MemoryStore();
    final r = replica(store);
    await r.acceptResult(
      result('done', 'schedule', 'schedule.result', {
        'id': 'schedule',
        'revision': 9,
        'state': 'done',
      }),
    );
    await r.acceptResult(
      result('old', 'schedule', 'schedule.result', {
        'id': 'schedule',
        'revision': 2,
        'state': 'queued',
      }),
    );
    expect(r.schedules['schedule']!['state'], 'done');
    expect(r.revisions['schedule'], 9);
  });
  test(
    'duplicate rapid transcript request produces one outbox operation',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final job = TranscriptionJob(
        id: 'transcript',
        source: source,
        state: JobState.waitingSync,
      );
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          r.stageCommand(
            'transcript.request',
            job.id,
            job.toJson().cast<String, dynamic>(),
            optimisticJob: job.toJson().cast<String, dynamic>(),
          ),
      ]);
      expect(results.map((op) => op.opId).toSet().length, 1);
      expect(r.pending.length, 1);
    },
  );
  test(
    'foreign higher revision does not silently erase newer local edits',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'first'});
      final own = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata('draft:fixture', {'text': 'second'});
      await r.acceptResult(
        result('remote', 'draft:fixture', 'metadata.result', {
          'revision': 2,
          'value': {'text': 'remote'},
        }),
      );
      await r.acceptResult(metadataAck(own, 1));
      expect(r.values['draft:fixture'], {'text': 'second'});
      expect(r.conflicts['draft:fixture']!['existingValue'], {
        'text': 'remote',
      });
      expect(r.pending, isEmpty);
    },
  );
  test(
    'typing after an attempted delete is preserved and coalesced after ACK',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final deleted = await r.stageCommand(
        'metadata.delete',
        'draft:fixture',
        {},
      );
      await r.markPublishing(deleted.opId);
      await r.queueMetadata('draft:fixture', {'text': 'new text'});
      await r.acceptResult(metadataAck(deleted, 1));
      expect(r.values['draft:fixture'], {'text': 'new text'});
      expect(r.pending.values.single.baseRevision, 1);
    },
  );
  test(
    'seen replay is idempotent and cannot create a duplicate coalesced autosave',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'a'});
      final command = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata('draft:fixture', {'text': 'b'});
      final ack = metadataAck(command, 1);
      await r.acceptResult(ack);
      final queued = r.pending.keys.single;
      await r.acceptResult(ack);
      expect(r.pending.keys.single, queued);
    },
  );
  test(
    'resolution preserves a third unsent local version through restart',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata('draft:fixture', {'text': 'first local'});
      final submitted = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata('draft:fixture', {'text': 'newest local'});
      await r.acceptResult(
        result('conflict', 'draft:fixture', 'metadata.result', {
          'state': 'conflict',
          'revision': 3,
          'acceptedOpId': submitted.opId,
          'existingValue': {'text': 'remote'},
          'proposedValue': {'text': 'first local'},
        }),
      );
      final resolution = await r.stageCommand('metadata.put', 'draft:fixture', {
        'value': {'text': 'chosen'},
      }, baseRevision: 3);
      await r.acceptResult(metadataAck(resolution, 4));
      final restored = replica(store);
      final copies = restored.values.entries
          .where((e) => e.key.startsWith('draft-copy:'))
          .map((e) => e.value['text'])
          .toSet();
      expect(copies, containsAll(['first local', 'newest local', 'remote']));
    },
  );
  test(
    'job conflict preserves actual processing state through restart',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final op = await r.stageCommand(
        'schedule.create',
        'schedule-fixture',
        {'id': 'schedule-fixture'},
        optimisticJob: {'id': 'schedule-fixture', 'state': 'waitingSync'},
      );
      await r.acceptResult(
        result('queued-ack', 'schedule-fixture', 'schedule.result', {
          'id': 'schedule-fixture',
          'revision': 1,
          'state': 'processing',
          'acceptedOpId': op.opId,
        }),
      );
      await r.acceptResult(
        result('conflicting-edit', 'schedule-fixture', 'schedule.result', {
          'revision': 1,
          'state': 'conflict',
          'actualState': 'processing',
          'errorCode': 'dispatch_started',
        }),
      );
      expect(r.schedules['schedule-fixture']!['state'], 'processing');
      expect(r.schedules['schedule-fixture']!['errorCode'], 'dispatch_started');
      // A refused job command is part of the job's state, not a choice
      // between two settings versions (Sync settings listed it as one).
      expect(r.conflicts.containsKey('schedule-fixture'), isFalse);
      expect(
        replica(store).schedules['schedule-fixture']!['state'],
        'processing',
      );
    },
  );

  test(
    'confirmed source redaction clears text durably and replay cannot restore it',
    () async {
      final store = MemoryStore();
      final r = replica(store);
      final job = TranscriptionJob(
        id: 'fixture-transcript',
        source: source,
        state: JobState.waitingSync,
      );
      final op = await r.stageCommand(
        'transcript.request',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: job.toJson().cast<String, dynamic>(),
      );
      final done =
          result('done-before-redaction', job.id, 'transcript.result', {
            'id': job.id,
            'source': source.toJson(),
            'state': 'done',
            'text': 'synthetic-source-deletion-canary',
            'revision': 1,
            'acceptedOpId': op.opId,
          });
      await r.acceptResult(done);
      expect(r.transcripts[job.id]!.text, 'synthetic-source-deletion-canary');
      await r.acceptResult(
        result('redaction-tombstone', job.id, 'transcript.result', {
          'id': job.id,
          'state': 'cancelled',
          'errorCode': 'source_redacted',
          'text': null,
          'revision': 2,
        }),
      );
      final restored = replica(store);
      expect(restored.transcripts[job.id]!.text, isNull);
      expect(restored.transcripts[job.id]!.state, JobState.cancelled);
      expect(
        jsonEncode(store.data),
        isNot(contains('synthetic-source-deletion-canary')),
      );
      await restored.acceptResult(done);
      expect(restored.transcripts[job.id]!.text, isNull);
    },
  );

  group('conflicts and unconfirmed changes (2026-10-20)', () {
    const key = 'transcription-policy';
    PersonalOperation refusal(
      String id,
      PersonalOperation command,
      int revision,
      Map<String, dynamic>? existing,
    ) => result(id, command.entityId, 'metadata.result', {
      'state': 'conflict',
      'revision': revision,
      'acceptedOpId': command.opId,
      'existingValue': existing,
      'proposedValue': command.payload['value'],
    });

    test('a refusal that already holds the wanted value is no conflict', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': true});
      final sent = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('same', sent, 2, {'auto': true}));
      final restored = replica(store);
      expect(restored.conflicts, isEmpty);
      expect(restored.pending, isEmpty);
      expect(restored.values[key], {'auto': true});
      expect(restored.revisions[key], 2);
    });

    test('an own write whose acknowledgement was lost is rebased', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': true});
      final first = (await r.markPublishing(r.pending.keys.single))!;
      await r.queueMetadata(key, {'auto': false});
      // The worker accepted the first write (revision 1), but its answer
      // never reached this device; the change is re-issued and refused.
      final again = (await r.reissue(first.opId))!;
      expect(again.opId, isNot(first.opId));
      expect(again.payload['value'], {'auto': false});
      await r.markPublishing(again.opId);
      await r.acceptResult(refusal('lost-ack', again, 1, {'auto': true}));
      expect(r.conflicts, isEmpty);
      final rebased = r.pending.values.single;
      expect(rebased.baseRevision, 1);
      expect(rebased.payload['value'], {'auto': false});
      await r.markPublishing(rebased.opId);
      await r.acceptResult(metadataAck(rebased, 2));
      expect(r.pending, isEmpty);
      expect(replica(store).values[key], {'auto': false});
    });

    test('a newer revision with the unchanged base value is rebased', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.acceptResult(
        result('remote-1', key, 'metadata.result', {
          'revision': 1,
          'value': {'auto': true},
        }),
      );
      await r.queueMetadata(key, {'auto': false});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      expect(mine.baseRevision, 1);
      // Another device saved the same value again (revision 2).
      await r.acceptResult(refusal('echo', mine, 2, {'auto': true}));
      expect(r.conflicts, isEmpty);
      expect(r.pending.values.single.baseRevision, 2);
    });

    test('a real concurrent change keeps both versions until chosen', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': false});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('remote', mine, 4, {'auto': true, 'x': 1}));
      final restored = replica(store);
      expect(restored.conflicts[key]!['existingValue'], {'auto': true, 'x': 1});
      expect(restored.conflicts[key]!['proposedValue'], {'auto': false});
      expect(restored.values[key], {'auto': false});
      expect(restored.pending, isEmpty);
    });

    test('rebasing is bounded, then the conflict is shown', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': false});
      var op = (await r.markPublishing(r.pending.keys.single))!;
      for (var i = 1; i <= PersonalReplica.maxAutomaticRebases; i++) {
        await r.acceptResult(refusal('echo-$i', op, i, null));
        expect(r.conflicts, isEmpty, reason: 'rebase $i');
        op = (await r.markPublishing(r.pending.keys.single))!;
      }
      await r.acceptResult(refusal('echo-last', op, 9, null));
      expect(r.pending, isEmpty);
      expect(r.conflicts[key]!['proposedValue'], {'auto': false});
    });

    test('a worker that never stored the entity accepts it again', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.acceptResult(
        result('old-worker', key, 'metadata.result', {
          'revision': 5,
          'value': {'auto': true},
        }),
      );
      await r.queueMetadata(key, {'auto': false});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('empty-worker', mine, 0, null));
      expect(r.conflicts, isEmpty);
      final again = r.pending.values.single;
      expect(again.baseRevision, 0);
      await r.markPublishing(again.opId);
      await r.acceptResult(metadataAck(again, 1));
      expect(r.pending, isEmpty);
      expect(r.values[key], {'auto': false});
      expect(r.revisions[key], 1);
    });

    test("another device's refused write is never this device's conflict", () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.acceptResult(
        result('foreign-refusal', key, 'metadata.result', {
          'state': 'conflict',
          'revision': 3,
          'acceptedOpId': 'other-device-op',
          'existingValue': {'auto': true},
          'proposedValue': {'auto': false},
        }),
      );
      expect(r.conflicts, isEmpty);
      expect(r.values[key], {'auto': true});
      expect(r.revisions[key], 3);
      await r.queueMetadata(key, {'maxSeconds': 60});
      expect(r.pending.values.single.baseRevision, 3);
    });

    test('a later foreign write refreshes or settles a held conflict', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': false});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('remote', mine, 2, {'auto': true}));
      expect(r.conflicts, contains(key));
      await r.acceptResult(
        result('remote-3', key, 'metadata.result', {
          'revision': 3,
          'value': {'auto': true, 'maxSeconds': 60},
        }),
      );
      expect(r.conflicts[key]!['revision'], 3);
      expect(r.conflicts[key]!['existingValue'], {
        'auto': true,
        'maxSeconds': 60,
      });
      await r.acceptResult(
        result('remote-4', key, 'metadata.result', {
          'revision': 4,
          'value': {'auto': false},
        }),
      );
      expect(replica(store).conflicts, isEmpty);
      expect(replica(store).values[key], {'auto': false});
    });

    test('one-tap resolution: keep this device or use the other version', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': false});
      final mine = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('remote', mine, 2, {'auto': true}));
      await r.resolveConflict(key, keepLocal: true);
      expect(r.conflicts, isEmpty);
      final keep = r.pending.values.single;
      expect(keep.baseRevision, 2);
      expect(keep.payload['value'], {'auto': false});
      await r.markPublishing(keep.opId);
      await r.acceptResult(metadataAck(keep, 3));
      expect(r.values[key], {'auto': false});

      const draft = 'draft:fixture';
      await r.queueMetadata(draft, {'text': 'mine'});
      final typed = (await r.markPublishing(r.pending.keys.single))!;
      await r.acceptResult(refusal('remote-draft', typed, 5, {'text': 'other'}));
      final writes = store.writes.length;
      await r.resolveConflict(draft, keepLocal: false);
      final restored = replica(store);
      expect(restored.conflicts, isEmpty);
      expect(restored.pending, isEmpty);
      expect(restored.values[draft], {'text': 'other'});
      expect(restored.revisions[draft], 5);
      // Nothing was published; this device's text is kept as a draft copy.
      expect(store.writes.length, writes + 1);
      expect(
        restored.values.entries
            .where((e) => e.key.startsWith('draft-copy:'))
            .map((e) => e.value['text']),
        contains('mine'),
      );
    });

    test('stored echo conflicts are settled; real ones are kept', () async {
      final store = MemoryStore();
      Map<String, dynamic> record(Map<String, dynamic> conflict) => {
        'revision': 2,
        'generation': 1,
        'commands': <String, dynamic>{},
        'attempted': <String>[],
        'appliedResults': <String>[],
        'serverValue': {'auto': true},
        'localValue': conflict['proposedValue'],
        'conflict': conflict,
      };
      store.data['replica:echo'] = record({
        'state': 'conflict',
        'revision': 4,
        'existingValue': {'auto': true},
        'proposedValue': {'auto': true},
      });
      store.data['replica:real'] = record({
        'state': 'conflict',
        'revision': 4,
        'existingValue': {'auto': true},
        'proposedValue': {'auto': false},
      });
      store.data['replica:legacy'] = {
        ...record({'state': 'synthetic conflict'}),
      }..remove('localValue');
      final r = replica(store);
      expect(r.conflicts.keys, containsAll(['echo', 'real', 'legacy']));
      expect(await r.settleObsoleteConflicts(), 1);
      final restored = replica(store);
      expect(restored.conflicts.keys.toSet(), {'real', 'legacy'});
      expect(restored.values['echo'], {'auto': true});
      expect(restored.revisions['echo'], 4);
    });

    test('unconfirmed commands: publication time and bounded re-issue', () async {
      final store = MemoryStore();
      final r = replica(store);
      await r.queueMetadata(key, {'auto': true});
      final op = r.pending.values.single;
      expect(await r.reissue(op.opId), isNull, reason: 'never sent');
      expect(r.attemptedAt(op.opId), isNull);
      await r.markPublishing(op.opId);
      expect(r.attemptedAt(op.opId), clock);
      expect(r.isAttempted(op.opId), isTrue);
      var current = op;
      for (var i = 0; i < PersonalReplica.maxAutomaticReissues; i++) {
        current = (await r.reissue(current.opId, automatic: true))!;
        expect(r.pending.keys.single, current.opId);
        expect(r.isAttempted(current.opId), isFalse);
        await r.markPublishing(current.opId);
      }
      expect(r.reissueCount(current.opId), PersonalReplica.maxAutomaticReissues);
      expect(await r.reissue(current.opId, automatic: true), isNull);
      final manual = (await r.reissue(current.opId))!;
      await r.markPublishing(manual.opId);
      // The answer to the very first id still arrives: applied like a
      // foreign result; the re-issued change then settles as an echo.
      await r.acceptResult(metadataAck(op, 1));
      expect(r.pending.keys.single, manual.opId);
      await r.acceptResult(refusal('echo', manual, 1, {'auto': true}));
      expect(r.pending, isEmpty);
      expect(r.conflicts, isEmpty);
      expect(replica(store).values[key], {'auto': true});

      // Paid jobs are re-issued only on request, at the current revision.
      final job = TranscriptionJob(
        id: 'transcript-fixture',
        source: source,
        state: JobState.waitingSync,
      );
      final request = await r.stageCommand(
        'transcript.request',
        job.id,
        job.toJson().cast<String, dynamic>(),
        optimisticJob: job.toJson().cast<String, dynamic>(),
      );
      await r.markPublishing(request.opId);
      expect(await r.reissue(request.opId, automatic: true), isNull);
      final resent = (await r.reissue(request.opId))!;
      expect(resent.kind, 'transcript.request');
      expect(resent.baseRevision, 0);
      expect(r.pending.keys, [resent.opId]);
    });
  });

  group('journal watermark', () {
    const room = '!fixture-journal';
    final t0 = DateTime.utc(2026, 10, 17, 12);
    JournalPosition at(
      String id,
      int minute, [
      JournalSettlement settlement = JournalSettlement.settled,
    ]) => JournalPosition(id, t0.add(Duration(minutes: minute)), settlement);

    test('new or migrated store has no watermark: full replay', () async {
      final store = MemoryStore();
      store.data['replica:draft:fixture'] = {
        'revision': 1,
        'commands': <String, dynamic>{},
      };
      expect(await replica(store).journalWatermark(room), isNull);
    });

    test('round-trips through the store and survives restart', () async {
      final store = MemoryStore();
      final watermark = JournalWatermark(
        roomId: room,
        eventId: r'$fixture-b',
        originServerTs: t0,
        held: [r'$fixture-utd'],
      );
      await replica(store).saveJournalWatermark(watermark);
      final restored = await replica(store).journalWatermark(room);
      expect(restored?.sameAs(watermark), isTrue);
      expect(restored!.originServerTs, t0);
      expect(restored.held, [r'$fixture-utd']);
      expect(
        await replica(store).journalWatermark('!another-journal'),
        isNull,
        reason: 'A new journal room starts with a full replay',
      );
    });

    test('unknown schema or malformed record means full replay', () async {
      final valid = JournalWatermark(
        roomId: room,
        eventId: r'$fixture',
        originServerTs: t0,
      ).toJson();
      for (final broken in <Map<String, dynamic>>[
        {...valid, 'schema': JournalWatermark.schema + 1},
        {...valid}..remove('schema'),
        {...valid, 'eventId': 'local-echo'},
        {...valid, 'eventId': 42},
        {...valid, 'originServerTs': '2026'},
        {...valid, 'roomId': ''},
        {...valid, 'held': 'not-a-list'},
        {
          ...valid,
          'held': [r'$ok', 'txn-not-an-event'],
        },
        {
          ...valid,
          'held': [
            for (var i = 0; i <= JournalWatermark.maxHeld; i++) '\$held-$i',
          ],
        },
      ]) {
        final store = MemoryStore()..data[JournalWatermark.storageKey] = broken;
        expect(
          await replica(store).journalWatermark(room),
          isNull,
          reason: jsonEncode(broken),
        );
      }
    });

    test('is never durable before the results it covers', () async {
      final store = MemoryStore();
      final r = replica(store);
      final applying = r.acceptResult(
        result('fixture-result', 'reminder:fixture', 'reminder.result', {
          'revision': 1,
          'state': 'done',
        }),
      );
      final saving = r.saveJournalWatermark(
        JournalWatermark(roomId: room, eventId: r'$after', originServerTs: t0),
      );
      await Future.wait([applying, saving]);
      expect(store.writes, [
        'replica:reminder:fixture',
        PersonalReplica.seenKeyOf('fixture-result'),
        JournalWatermark.storageKey,
      ]);
    });

    test('a failed result commit keeps the previous watermark', () async {
      final store = MemoryStore();
      final r = replica(store);
      final previous = JournalWatermark(
        roomId: room,
        eventId: r'$before',
        originServerTs: t0,
      );
      await r.saveJournalWatermark(previous);
      store.failNextKey = 'replica:reminder:fixture';
      await expectLater(
        r.acceptResult(
          result('fixture-result', 'reminder:fixture', 'reminder.result', {
            'revision': 1,
            'state': 'done',
          }),
        ),
        throwsStateError,
      );
      // The client advances only after every acceptResult succeeded.
      expect((await r.journalWatermark(room))?.sameAs(previous), isTrue);
      expect(store.seen('fixture-result'), isFalse);
    });

    test('advances over settled events from the journal start', () {
      final next = JournalWatermark.advance(
        roomId: room,
        previous: null,
        newer: [at(r'$create', 0), at(r'$a', 1), at(r'$b', 2)],
      );
      expect(next?.eventId, r'$b');
      expect(next?.originServerTs, t0.add(const Duration(minutes: 2)));
      expect(next?.held, isEmpty);
      expect(
        JournalWatermark.advance(roomId: room, previous: null, newer: []),
        isNull,
      );
    });

    test('held events are kept by id and the position moves past them', () {
      final first = JournalWatermark.advance(
        roomId: room,
        previous: null,
        newer: [
          at(r'$a', 0),
          at(r'$utd', 1, JournalSettlement.held),
          at(r'$b', 2),
          at(r'$untrusted', 3, JournalSettlement.held),
        ],
      )!;
      expect(first.eventId, r'$untrusted');
      expect(first.held, [r'$utd', r'$untrusted']);
      final second = JournalWatermark.advance(
        roomId: room,
        previous: first,
        newer: [at(r'$c', 4)],
        resolved: {r'$utd'},
      )!;
      expect(second.eventId, r'$c');
      expect(second.held, [r'$untrusted']);
      final unchanged = JournalWatermark.advance(
        roomId: room,
        previous: second,
        newer: [],
      );
      expect(unchanged?.sameAs(second), isTrue);
    });

    test('stops at a local echo and at the held limit', () {
      final echo = JournalWatermark.advance(
        roomId: room,
        previous: null,
        newer: [
          at(r'$a', 0),
          at(r'$sending', 1, JournalSettlement.barrier),
          at(r'$b', 2),
        ],
      );
      expect(echo?.eventId, r'$a');
      final txn = JournalWatermark.advance(
        roomId: room,
        previous: null,
        newer: [at(r'$a', 0), at('txn-1', 1), at(r'$b', 2)],
      );
      expect(txn?.eventId, r'$a');
      final limited = JournalWatermark.advance(
        roomId: room,
        previous: null,
        maxHeld: 2,
        newer: [
          at(r'$a', 0),
          at(r'$h1', 1, JournalSettlement.held),
          at(r'$b', 2),
          at(r'$h2', 3, JournalSettlement.held),
          at(r'$c', 4),
          at(r'$h3', 5, JournalSettlement.held),
          at(r'$d', 6),
        ],
      )!;
      expect(limited.eventId, r'$c', reason: 'A third unsettled event waits');
      expect(limited.held, [r'$h1', r'$h2']);
    });

    test('a watermark of another journal room is rejected', () {
      expect(
        () => JournalWatermark.advance(
          roomId: room,
          previous: JournalWatermark(
            roomId: '!other',
            eventId: r'$x',
            originServerTs: t0,
          ),
          newer: [],
        ),
        throwsArgumentError,
      );
    });
  });
}
