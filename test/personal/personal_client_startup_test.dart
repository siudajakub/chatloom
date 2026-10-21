// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:personal_core/personal_core.dart';

class _Client implements Client {
  @override
  String? userID = '@synthetic:example.org';
  Future<void> Function() accountLoad = () async {};
  @override
  Future<void> get accountDataLoading => accountLoad();
  @override
  final Map<String, BasicEvent> accountData = {};
  @override
  final List<Room> rooms = [];
  @override
  final Map<String, DeviceKeysList> userDeviceKeys = {};
  @override
  final onSync = CachedStreamController<SyncUpdate>();
  @override
  final onTimelineEvent = CachedStreamController<Event>();
  @override
  Future<dynamic>? get userDeviceKeysLoading => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  final prefixes = <String>[];
  int writes = 0;
  int closes = 0;
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async {
    prefixes.add(prefix);
    return {
      for (final entry in records.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }

  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    writes++;
    records[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    writes++;
    records.remove(key);
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

class _Timeline implements Timeline {
  @override
  final List<Event> events = [];
  @override
  bool get canRequestHistory => false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelSubscriptions) return null;
    return super.noSuchMethod(invocation);
  }
}

class _Journal implements Room {
  @override
  String get id => '!synthetic-journal:example.org';
  bool valid = true;
  bool trusted = true;
  int publishes = 0;
  int timelineReads = 0;
  int participantReads = 0;
  int activeParticipantReads = 0;
  int maxParticipantReads = 0;
  Future<void>? participantGate;
  bool rejectPublish = false;
  bool omitPublishAck = false;
  final publishedTransactions = <String>[];
  final publishedWithRetry = <bool>[];
  final publishedWithLocalEcho = <bool>[];
  @override
  final onSessionKeyReceived = CachedStreamController<String>();

  Future<List<User>> _participants() async {
    participantReads++;
    activeParticipantReads++;
    if (activeParticipantReads > maxParticipantReads) {
      maxParticipantReads = activeParticipantReads;
    }
    try {
      await participantGate;
      return trusted
          ? []
          : [User('@untrusted:example.org', room: this, membership: 'join')];
    } finally {
      activeParticipantReads--;
    }
  }

  @override
  bool get encrypted => valid;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #getState:
        return StrippedStateEvent(
          type: personalRoomMarker,
          senderId: '@synthetic:example.org',
          content: {'schema': personalSchemaVersion},
        );
      case #requestParticipants:
        return _participants();
      case #getParticipants:
        return trusted
            ? <User>[]
            : [User('@untrusted:example.org', room: this, membership: 'join')];
      case #setPushRuleState:
        return Future<void>.value();
      case #getTimeline:
        timelineReads++;
        return Future<Timeline>.value(_Timeline());
      case #sendEvent:
        publishes++;
        publishedTransactions.add(invocation.namedArguments[#txid] as String);
        publishedWithRetry.add(
          invocation.namedArguments[#retryOnTransportFailure] as bool? ?? true,
        );
        publishedWithLocalEcho.add(
          invocation.namedArguments[#displayPendingEvent] as bool? ?? true,
        );
        if (rejectPublish) {
          return Future<String>.error(const SocketException('synthetic'));
        }
        return Future<String?>.value(omitPublishAck ? null : r'$synthetic');
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'opening multiple surfaces reuses the active journal timeline',
    () async {
      final client = _Client();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _Store(),
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal();
      personal.journal = journal;
      await personal.load();
      var changes = 0;
      personal.addListener(() => changes++);
      final participants = journal.participantReads;
      await Future.wait(List.generate(4, (_) => personal.load()));
      await personal.load();
      expect(personal.ready, isTrue);
      expect(journal.timelineReads, 1);
      expect(changes, 0);
      expect(
        journal.participantReads,
        participants,
        reason: 'Reusing a live journal needs no participants request',
      );
      await personal.retry();
      expect(
        journal.timelineReads,
        2,
        reason: 'Explicit retry still reconstructs history',
      );
    },
  );

  test(
    'reused load still validates membership before returning ready',
    () async {
      final client = _Client();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _Store(),
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal();
      personal.journal = journal;
      await personal.load();
      journal.trusted = false;
      await personal.load();
      expect(personal.ready, isFalse);
      expect(personal.syncFailure, PrivateSyncFailure.membershipUntrusted);
      expect(journal.timelineReads, 1);
      expect(journal.publishes, 0);
    },
  );

  test('sync bursts keep one membership validation in flight', () async {
    final client = _Client();
    final personal = PersonalClient.forTesting(
      client,
      openStore: () async => _Store(),
    );
    addTearDown(personal.dispose);
    addTearDown(client.onSync.close);
    final journal = _Journal();
    personal.journal = journal;
    await personal.load();
    final before = journal.participantReads;
    final gate = Completer<void>();
    journal.participantGate = gate.future;
    for (var i = 0; i < 100; i++) {
      client.onSync.add(SyncUpdate(nextBatch: 'burst-$i'));
    }
    await Future<void>.delayed(Duration.zero);
    expect(journal.activeParticipantReads, 1);
    expect(journal.maxParticipantReads, 1);
    gate.complete();
    journal.participantGate = null;
    await Future<void>.delayed(Duration.zero);
    expect(journal.activeParticipantReads, 0);
    expect(journal.participantReads - before, lessThanOrEqualTo(2));
    expect(personal.ready, isTrue);
  });

  test(
    'Matrix ACK prevents pending-command resend on unrelated sync',
    () async {
      final client = _Client();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _Store(),
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal();
      personal.journal = journal;
      await personal.load();
      final op = await personal.command('worker.pairing', 'worker', {});
      await personal.stagePending();
      expect(personal.pending, contains(op.opId));
      expect(journal.publishes, 1);
      for (var i = 0; i < 5; i++) {
        client.onSync.add(SyncUpdate(nextBatch: 'idle-$i'));
        await Future<void>.delayed(Duration.zero);
      }
      await personal.stagePending();
      expect(journal.publishes, 1);
      expect(journal.publishedWithRetry, [false]);
      expect(journal.publishedWithLocalEcho, [false]);
      expect(personal.pending, contains(op.opId));
    },
  );

  test('coalescing retains journal activity behind unrelated syncs', () async {
    final client = _Client();
    final personal = PersonalClient.forTesting(
      client,
      openStore: () async => _Store(),
    );
    addTearDown(personal.dispose);
    addTearDown(client.onSync.close);
    final journal = _Journal();
    personal.journal = journal;
    await personal.load();
    var changes = 0;
    personal.addListener(() => changes++);
    final passes = personal.debugReplayPasses;
    final gate = Completer<void>();
    journal.participantGate = gate.future;
    client.onSync.add(SyncUpdate(nextBatch: 'active'));
    await Future<void>.delayed(Duration.zero);
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'journal',
        rooms: RoomsUpdate(join: {journal.id: JoinedRoomUpdate()}),
      ),
    );
    for (var i = 0; i < 10; i++) {
      client.onSync.add(SyncUpdate(nextBatch: 'unrelated-$i'));
    }
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    journal.participantGate = null;
    await Future<void>.delayed(Duration.zero);
    expect(
      personal.debugReplayPasses - passes,
      1,
      reason: 'The queued journal update must replay once',
    );
    expect(changes, 0, reason: 'An unchanged journal does not wake listeners');
    expect(journal.maxParticipantReads, 1);
    expect(personal.ready, isTrue);
  });

  test(
    'unconfirmed journal publication retries with the original txid',
    () async {
      final client = _Client();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _Store(),
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal();
      personal.journal = journal;
      await personal.load();
      journal.rejectPublish = true;
      final op = await personal.command('worker.pairing', 'worker', {});
      await expectLater(personal.stagePending(), throwsStateError);
      expect(personal.ready, isFalse);
      expect(personal.pending, contains(op.opId));
      journal.rejectPublish = false;
      await personal.retry();
      expect(journal.publishedTransactions, [op.opId, op.opId]);
      expect(personal.ready, isTrue);
    },
  );

  test('missing Matrix ACK leaves publication eligible for retry', () async {
    final client = _Client();
    final personal = PersonalClient.forTesting(
      client,
      openStore: () async => _Store(),
    );
    addTearDown(personal.dispose);
    addTearDown(client.onSync.close);
    final journal = _Journal();
    personal.journal = journal;
    await personal.load();
    journal.omitPublishAck = true;
    final op = await personal.command('worker.pairing', 'worker', {});
    await expectLater(personal.stagePending(), throwsStateError);
    expect(personal.pending, contains(op.opId));
    expect(personal.syncFailure, PrivateSyncFailure.timeout);
    journal.omitPublishAck = false;
    await personal.retry();
    expect(journal.publishedTransactions, [op.opId, op.opId]);
    expect(personal.ready, isTrue);
  });

  test(
    'local hydration reads metadata namespaces without loading outboxes',
    () async {
      final client = _Client();
      final store = _Store();
      final prefix = 'account:${client.userID}:';
      store.records['${prefix}replica:draft:synthetic'] = {
        'localValue': {'text': 'synthetic draft'},
        'commands': <String, dynamic>{},
      };
      store.records['${prefix}seen:synthetic'] = {'seen': true};
      store.records['${prefix}outbox:immediate:synthetic'] = {
        'state': 'unknown',
        'text': 'synthetic pending message',
      };
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => store,
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      await personal.loadLocal();
      expect(personal.values['draft:synthetic']?['text'], 'synthetic draft');
      expect(store.prefixes, isNot(contains(prefix)));
      expect(
        store.prefixes.any((p) => '${prefix}seen:synthetic'.startsWith(p)),
        isFalse,
      );
      expect(
        store.prefixes.any(
          (p) => '${prefix}outbox:immediate:synthetic'.startsWith(p),
        ),
        isFalse,
      );
      expect(
        store.records['${prefix}outbox:immediate:synthetic']?['state'],
        'unknown',
      );
      expect(store.writes, 0);
    },
  );

  test(
    'empty sync avoids replay notifications but still rejects unsafe membership',
    () async {
      final client = _Client();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _Store(),
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal();
      personal.journal = journal;
      await personal.load();
      expect(personal.ready, isTrue);
      var changes = 0;
      personal.addListener(() => changes++);
      client.onSync.add(SyncUpdate(nextBatch: 'empty'));
      await Future<void>.delayed(Duration.zero);
      expect(changes, 0);
      journal.trusted = false;
      client.onSync.add(SyncUpdate(nextBatch: 'unsafe'));
      await Future<void>.delayed(Duration.zero);
      expect(personal.syncFailure, PrivateSyncFailure.membershipUntrusted);
      expect(journal.publishes, 0);
    },
  );

  test(
    'transient storage failure retries without deleting existing records',
    () async {
      final client = _Client();
      final store = _Store();
      var opens = 0;
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async {
          if (++opens == 1) {
            throw const StorageFailure(StorageFailureCode.keyUnavailable);
          }
          return store;
        },
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      await personal.load();
      expect(personal.syncFailure, PrivateSyncFailure.storageUnavailable);
      expect(personal.ready, isFalse);
      await personal.retry();
      expect(opens, 2);
      expect(personal.syncFailure, PrivateSyncFailure.journalMissing);
      expect(store.writes, 0);
    },
  );

  test(
    'network failure preserves hydrated draft/conflict and journal retry is safe',
    () async {
      final client = _Client();
      final store = _Store();
      store.records['account:${client.userID}:replica:draft:synthetic'] = {
        'localValue': {'text': 'synthetic draft'},
        'conflict': {'state': 'synthetic conflict'},
        'commands': <String, dynamic>{},
      };
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => store,
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      client.accountLoad = () async =>
          throw const SocketException('synthetic endpoint');
      await personal.load();
      expect(personal.syncFailure, PrivateSyncFailure.offline);
      expect(personal.values['draft:synthetic']?['text'], 'synthetic draft');
      expect(personal.conflicts, contains('draft:synthetic'));
      expect(store.writes, 0);
      client.accountLoad = () async {};
      personal.journal = _Journal();
      await personal.retry();
      expect(personal.ready, isTrue);
      expect(personal.problem, isNull);
      expect(personal.values['draft:synthetic']?['text'], 'synthetic draft');
      expect(store.writes, 0);
    },
  );

  test(
    'journal type and membership block dispatch until explicit safe retry',
    () async {
      final client = _Client();
      final store = _Store();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => store,
      );
      addTearDown(personal.dispose);
      addTearDown(client.onSync.close);
      final journal = _Journal()..valid = false;
      personal.journal = journal;
      await personal.load();
      expect(personal.syncFailure, PrivateSyncFailure.journalInvalid);
      expect(journal.timelineReads, 0);
      journal.valid = true;
      journal.trusted = false;
      await personal.retry();
      expect(personal.syncFailure, PrivateSyncFailure.membershipUntrusted);
      expect(journal.timelineReads, 0);
      expect(journal.publishes, 0);
      journal.trusted = true;
      await personal.retry();
      expect(personal.ready, isTrue);
      expect(journal.publishes, 0);
    },
  );

  for (final switchAccount in [false, true]) {
    test(
      'late store completion cannot revive disposed/switched account: $switchAccount',
      () async {
        final client = _Client();
        final store = _Store();
        final gate = Completer<PersonalStore>();
        final personal = PersonalClient.forTesting(
          client,
          openStore: () => gate.future,
        );
        addTearDown(client.onSync.close);
        final loading = personal.loadLocal();
        final assertion = expectLater(loading, throwsStateError);
        if (switchAccount) {
          client.userID = '@another:example.org';
        } else {
          personal.dispose();
        }
        gate.complete(store);
        await assertion;
        expect(personal.ready, isFalse);
        expect(store.closes, 1);
        expect(store.writes, 0);
        if (switchAccount) personal.dispose();
      },
    );
  }
}
