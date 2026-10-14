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
        store.failNextKey = 'seen:${acknowledged.opId}';
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
      await r.acceptResult(
        result('conflict', 'draft:fixture', 'metadata.result', {
          'state': 'conflict',
          'revision': 3,
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
      expect(store.data.containsKey('seen:ack:${command.opId}'), isFalse);
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
      final conflict = result('conflict', 'draft:fixture', 'metadata.result', {
        'state': 'conflict',
        'revision': 9,
        'existingValue': {'text': 'remote'},
        'proposedValue': {'text': 'mine'},
      });
      store.failNextKey = 'seen:conflict';
      await expectLater(r.acceptResult(conflict), throwsStateError);
      final restored = replica(store);
      expect(restored.revisions['draft:fixture'], 9);
      expect(restored.conflicts['draft:fixture']!['proposedValue'], {
        'text': 'mine',
      });
      await restored.acceptResult(conflict);
      expect(store.data.containsKey('seen:conflict'), isTrue);
      expect(
        store.writes.indexOf('replica:draft:fixture'),
        lessThan(store.writes.indexOf('seen:conflict')),
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
      expect(r.conflicts.containsKey('schedule-fixture'), isTrue);
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
}
