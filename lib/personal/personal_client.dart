// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/diagnostics.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/journal_replay_batch.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/performance_probe.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/storage/personal_store.dart';
import 'package:fluffychat/personal/worker_readiness.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

class PersonalClient extends ChangeNotifier {
  static final _instances = <Client, PersonalClient>{};
  static PersonalClient of(Client client) =>
      _instances.putIfAbsent(client, () => PersonalClient._(client));
  final Client client;
  final _changes = StreamController<int>.broadcast();
  int _changeVersion = 0;
  Stream<int> get changes => _changes.stream;
  @override
  void notifyListeners() {
    if (!_disposed && !_changes.isClosed) {
      _changes.add(++_changeVersion);
      super.notifyListeners();
    }
  }

  PersonalClient._(this.client) : _openStore = PersonalStore.open;
  @visibleForTesting
  PersonalClient.forTesting(
    this.client, {
    required Future<PersonalStore> Function() openStore,
  }) : _openStore = openStore;
  final Future<PersonalStore> Function() _openStore;
  String? _localAccountId;
  PrivateSyncFailure? syncFailure;
  PersonalDiagnostic? diagnostic;

  void _checkActive() {
    if (_disposed ||
        (_localAccountId != null && client.userID != _localAccountId)) {
      throw StateError('Private client is closed');
    }
  }

  void _setFailure(Object error, PersonalFailurePhase phase) {
    if (_disposed ||
        (_localAccountId != null && client.userID != _localAccountId)) {
      return;
    }
    diagnostic = PersonalDiagnostic.from(error, phase);
    syncFailure = privateSyncFailure(error, phase);
    problem = syncFailure!.message;
    _journalReady = false;
    notifyListeners();
  }

  void _clearFailure() {
    problem = null;
    syncFailure = null;
    diagnostic = null;
  }

  PersonalStore? _store;
  PersonalReplica? _replica;
  Future<void>? _localLoading;
  Future<void>? _attaching;
  Future<void>? _draining;
  // A Matrix ACK makes this journal event durable. Waiting for the worker's
  // result must not resend every pending command on each unrelated sync.
  final _publishedCommands = <String>{};
  bool _disposed = false;
  bool _journalReady = false;
  Future<void>? _loading;
  Future<void>? _connecting;
  Timeline? _timeline;
  StreamSubscription? _sync;
  Future<void>? _syncing;
  bool _syncPending = false;
  bool _syncReplayRequested = false;
  bool _replaying = false;
  Future<void>? _replayCompletion;
  bool _replayAgain = false;
  final _acceptedResultEvents = <String>{};
  String? _journalTrustFingerprint;
  Room? journal;
  String? problem;
  WorkerReadiness? workerReadiness;
  DateTime? get heartbeatAt => workerReadiness?.receivedAt;
  final _emptyValues = <String, Map<String, dynamic>>{};
  final _emptyRevisions = <String, int>{};
  final _emptyTranscripts = <String, TranscriptionJob>{};
  final _emptySchedules = <String, Map<String, dynamic>>{};
  final _emptyReminders = <String, Map<String, dynamic>>{};
  final _emptyPending = <String, PersonalOperation>{};
  final _emptyConflicts = <String, Map<String, dynamic>>{};
  Map<String, Map<String, dynamic>> get values =>
      _replica?.values ?? _emptyValues;
  Map<String, int> get revisions => _replica?.revisions ?? _emptyRevisions;
  Map<String, TranscriptionJob> get transcripts =>
      _replica?.transcripts ?? _emptyTranscripts;
  Map<String, Map<String, dynamic>> get schedules =>
      _replica?.schedules ?? _emptySchedules;
  Map<String, Map<String, dynamic>> get reminders =>
      _replica?.reminders ?? _emptyReminders;
  Map<String, PersonalOperation> get pending =>
      _replica?.pending ?? _emptyPending;
  Map<String, Map<String, dynamic>> get conflicts =>
      _replica?.conflicts ?? _emptyConflicts;
  bool isTranscriptCancellationPending(String id) =>
      _replica?.transcriptCancellations.contains(id) ?? false;
  Future<void> stagePending() async {
    if (!ready || _disposed || _replica == null) return;
    if (_draining != null) return _draining!;
    final drain = _drain();
    _draining = drain;
    var completed = false;
    try {
      await drain;
      completed = true;
    } finally {
      _draining = null;
      if (completed && ready && _replica?.hasUnattemptedCommands == true) {
        _dispatch();
      }
    }
  }

  Future<void> _drain() async {
    _publishedCommands.removeWhere((id) => !pending.containsKey(id));
    for (final id in List<String>.from(pending.keys)) {
      if (!ready || _disposed) return;
      if (_publishedCommands.contains(id)) continue;
      final op = await _replica!.markPublishing(id);
      if (op == null) continue;
      try {
        await _publish(op);
        _publishedCommands.add(id);
      } catch (error) {
        _setFailure(error, PersonalFailurePhase.journalPublish);
        throw StateError('Publication deferred');
      }
    }
  }

  void _dispatch() {
    if (ready) {
      unawaited(
        stagePending().catchError((Object _) {
          if (!_disposed) notifyListeners();
        }),
      );
    }
  }

  String get _prefix => 'account:${_localAccountId ?? client.userID}:';
  bool get ready =>
      !_disposed &&
      (_localAccountId == null || client.userID == _localAccountId) &&
      _journalReady &&
      _store != null &&
      journal != null &&
      problem == null;
  bool get workerOnline =>
      ready && (workerReadiness?.freshAt(DateTime.now()) ?? false);
  String get workerReadinessDescription => !ready
      ? 'Worker readiness is unknown until private sync is available.'
      : workerReadiness?.describe(DateTime.now()) ??
            'No authenticated worker heartbeat. Pair the worker and verify its session.';
  ConversationRef ref(Room r) => ConversationRef(
    accountId: client.userID!,
    roomId: r.id,
    network: networkOf(r),
  );
  SourceEventRef source(Event e) =>
      SourceEventRef(conversation: ref(e.room), eventId: e.eventId);
  static String networkOf(Room r) {
    for (final type in [
      'm.bridge',
      'uk.half-shot.bridge',
      'com.beeper.bridge',
    ]) {
      final state = r.states[type];
      if (state == null) continue;
      for (final e in state.values) {
        final network = e.content['protocol'];
        if (network is Map && network['id'] is String) {
          return network['id'] as String;
        }
      }
    }
    return 'unknown';
  }

  /// Hydrate local drafts and metadata without waiting for journal networking.
  Future<void> loadLocal() => _ensureLocal();

  Future<void> _ensureLocal() async {
    _checkActive();
    final loading = _localLoading ??= _openLocal();
    try {
      await loading;
    } catch (error) {
      _setFailure(error, PersonalFailurePhase.localStorage);
      // A transient storage failure must not poison every later draft/send.
      if (identical(_localLoading, loading)) _localLoading = null;
      rethrow;
    }
    _checkActive();
  }

  Future<void> _openLocal() async {
    if (client.userID == null) {
      throw StateError('A signed-in account is required');
    }
    _localAccountId ??= client.userID;
    if (_store == null) {
      final opened = await _openStore();
      try {
        _checkActive();
      } catch (_) {
        await opened.close();
        rethrow;
      }
      _store = opened;
    }
    final store = _store!;
    final replica = PersonalReplica(
      read: (key) {
        _checkActive();
        return store.get('$_prefix$key');
      },
      write: (key, value) {
        _checkActive();
        return store.put('$_prefix$key', value);
      },
      newOperationId: () => const Uuid().v4(),
      clock: DateTime.now,
      onChanged: notifyListeners,
    );
    // Seen markers and immediate media/text outboxes can grow independently
    // from private metadata. They are read by their owners on demand, rather
    // than decoded and retained again during every private-client startup.
    final local = <String, Map<String, dynamic>>{};
    for (final namespace in [
      'replica:',
      'value:',
      'transcript:',
      'schedule:',
      'reminder:',
      'pending:',
      'conflict:',
    ]) {
      _checkActive();
      final records = await store.readPrefix('$_prefix$namespace');
      _checkActive();
      for (final entry in records.entries) {
        local[entry.key.substring(_prefix.length)] = entry.value;
      }
    }
    replica.restore(local);
    final entities = <String>{};
    final oldValues = <String, Map<String, dynamic>>{};
    final oldJobs = <String, Map<String, dynamic>>{};
    final oldKinds = <String, String>{};
    final oldRevisions = <String, int>{};
    final oldPending = <String, List<PersonalOperation>>{};
    final oldConflicts = <String, Map<String, dynamic>>{};
    for (final entry in local.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key.startsWith('value:')) {
        final id = key.substring(6);
        entities.add(id);
        oldValues[id] = Map<String, dynamic>.from(value['value'] as Map);
        oldRevisions[id] = value['revision'] as int? ?? 0;
      }
      for (final kind in ['transcript', 'schedule', 'reminder']) {
        if (key.startsWith('$kind:')) {
          final id = key.substring(kind.length + 1);
          entities.add(id);
          oldJobs[id] = value;
          oldKinds[id] = kind;
          oldRevisions[id] = value['revision'] as int? ?? 0;
        }
      }
      if (key.startsWith('pending:')) {
        final op = PersonalOperation.fromJson(value);
        entities.add(op.entityId);
        (oldPending[op.entityId] ??= []).add(op);
      }
      if (key.startsWith('conflict:')) {
        final id = key.substring(9);
        entities.add(id);
        oldConflicts[id] = value;
      }
    }
    for (final entity in entities) {
      _checkActive();
      await replica.importLegacy(
        entity,
        value: oldValues[entity],
        revision: oldRevisions[entity] ?? 0,
        job: oldJobs[entity],
        jobKind: oldKinds[entity],
        pendingOperations: oldPending[entity] ?? const [],
        conflict: oldConflicts[entity],
      );
    }
    _checkActive();
    _replica = replica;
    if (syncFailure == PrivateSyncFailure.storageUnavailable) _clearFailure();
    notifyListeners();
  }

  void _findJournal() {
    final pointer = client.accountData[personalRoomMarker]?.content['roomId'];
    journal ??= pointer is String ? client.getRoomById(pointer) : null;
    journal ??= client.rooms.where(PersonalPrivacy.isJournal).firstOrNull;
  }

  void _installSync() {
    _checkActive();
    _sync ??= client.onSync.stream.listen((update) {
      unawaited(_onSync(update));
    });
  }

  Future<void> _onSync(SyncUpdate update) {
    if (_disposed || _replica == null) return Future<void>.value();
    _syncPending = true;
    final id = journal?.id;
    _syncReplayRequested |=
        id != null &&
        (update.rooms?.join?.containsKey(id) == true ||
            update.rooms?.leave?.containsKey(id) == true);
    // Stream.listen does not await async callbacks. Retain at most one active
    // pass plus a merged wake, including journal activity arriving during I/O.
    return _syncing ??= _drainSync();
  }

  Future<void> _drainSync() async {
    try {
      while (_syncPending && !_disposed) {
        _syncPending = false;
        final replayRequested = _syncReplayRequested;
        _syncReplayRequested = false;
        await _syncOnce(replayRequested: replayRequested);
      }
    } finally {
      _syncing = null;
    }
  }

  Future<void> _syncOnce({required bool replayRequested}) async {
    try {
      _checkActive();
      _findJournal();
      if (journal == null) {
        _setFailure(
          StateError('Private journal is not configured'),
          PersonalFailurePhase.journalDiscovery,
        );
        return;
      }
      if (_attaching != null) {
        await _attaching;
      } else if (_timeline == null || problem != null) {
        await _attach();
      } else {
        // Still validate membership on empty syncs; only history replay is skipped.
        await _validate();
      }
      // Also replay activity that arrived after attach's initial replay but
      // before its pending-publication await finished.
      if (replayRequested ||
          _journalTrustFingerprint != _trustFingerprint()) {
        await _replay();
      }
      if (ready) await stagePending();
    } catch (error) {
      _setFailure(error, PersonalFailurePhase.journalReplay);
    }
  }

  Future<void> load() => _startLoad(const Duration(seconds: 3));
  Future<void> retry() => _startLoad(const Duration(seconds: 15));

  Future<void> _startLoad(Duration timeout) {
    _checkActive();
    return _loading ??= _load(timeout).whenComplete(() => _loading = null);
  }

  Future<void> _load(Duration timeout) async {
    var phase = PersonalFailurePhase.localStorage;
    try {
      await _ensureLocal();
      _checkActive();
      _installSync();
      phase = PersonalFailurePhase.journalDiscovery;
      await client.accountDataLoading?.timeout(timeout);
      _checkActive();
      _findJournal();
      if (journal == null) {
        throw StateError('Private journal is not configured');
      }
      phase = PersonalFailurePhase.journalValidation;
      await _attach();
    } catch (error) {
      _setFailure(error, phase);
    }
    notifyListeners();
  }

  Future<void> connect() {
    _checkActive();
    return _connecting ??= _connect()
        .catchError((Object error) {
          _setFailure(error, PersonalFailurePhase.journalDiscovery);
          throw error;
        })
        .whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    await _ensureLocal();
    _installSync();
    await client.accountDataLoading?.timeout(const Duration(seconds: 15));
    _checkActive();
    _findJournal();
    if (_store == null) throw StateError('Encrypted storage unavailable');
    if (journal == null) {
      final id = await client.createRoom(
        name: 'Personal Chat — private sync',
        preset: CreateRoomPreset.privateChat,
        creationContent: {'m.federate': false},
        initialState: [
          StateEvent(
            type: EventTypes.Encryption,
            content: {'algorithm': 'm.megolm.v1.aes-sha2'},
          ),
          StateEvent(
            type: personalRoomMarker,
            content: {'schema': personalSchemaVersion},
          ),
        ],
      );
      _checkActive();
      await client.waitForRoomInSync(id, join: true);
      _checkActive();
      journal = client.getRoomById(id);
      await client.setAccountData(client.userID!, personalRoomMarker, {
        'roomId': id,
      });
    }
    await _attach();
    if (!_journalReady) {
      throw StateError('Journal synchronization is incomplete');
    }
    notifyListeners();
    await command('worker.pairing', 'worker', {
      'schema': personalSchemaVersion,
    });
  }

  Future<void> _validate() async {
    _checkActive();
    final room = journal;
    if (room == null || !room.encrypted || !PersonalPrivacy.isJournal(room)) {
      throw StateError('Invalid encrypted journal');
    }
    final members = await room.requestParticipants();
    _checkActive();
    if (members.any(
      (m) =>
          (m.membership == Membership.join ||
              m.membership == Membership.invite) &&
          m.id != client.userID,
    )) {
      _setFailure(
        StateError('Unsafe journal membership'),
        PersonalFailurePhase.journalValidation,
      );
      throw StateError('Unsafe journal membership');
    }
  }

  Future<void> _attach() async {
    if (_attaching != null) return _attaching!;
    final attach = _attachOnce();
    _attaching = attach;
    try {
      await attach;
    } finally {
      _attaching = null;
    }
  }

  Future<void> _attachOnce() async {
    final measurement = PersonalPerformanceProbe.enabled
        ? (Stopwatch()..start())
        : null;
    _journalReady = false;
    await _validate();
    _checkActive();
    final room = journal!;
    await room.setPushRuleState(PushRuleState.dontNotify);
    _checkActive();
    _timeline?.cancelSubscriptions();
    final timeline = await room.getTimeline(
      onUpdate: () {
        // Initial pagination is replayed once after all pages have arrived.
        if (!_disposed && _attaching == null) unawaited(_replay());
      },
    );
    try {
      _checkActive();
    } catch (_) {
      timeline.cancelSubscriptions();
      rethrow;
    }
    _timeline = timeline;
    _acceptedResultEvents.clear();
    // Reconstruct durable history before replaying unsent commands.
    var pages = 0;
    while (timeline.canRequestHistory) {
      _checkActive();
      final before = timeline.events.map((event) => event.eventId).toSet();
      await timeline.requestHistory(historyCount: 100);
      _checkActive();
      final after = timeline.events.map((event) => event.eventId).toSet();
      if (after.length == before.length &&
          after.containsAll(before) &&
          timeline.canRequestHistory) {
        throw StateError('Journal history pagination stalled');
      }
      if (++pages > 10000) {
        throw StateError('Journal history exceeds safe pagination limit');
      }
    }
    _checkActive();
    _clearFailure();
    await _replay();
    _checkActive();
    _journalReady = problem == null;
    if (ready) await stagePending();
    if (measurement != null) {
      PersonalPerformanceProbe.emit('journal_attach', {
        'elapsed_ms': measurement.elapsedMilliseconds,
        'events': timeline.events.length,
        'pages': pages,
      });
    }
  }

  bool _trusted(Event event) {
    if (event.senderId != client.userID ||
        event.originalSource?.type != EventTypes.Encrypted) {
      return false;
    }
    final key = event.originalSource?.content['sender_key'];
    return client.userDeviceKeys[client.userID]?.deviceKeys.values.any(
          (d) => d.verified && d.curve25519Key == key,
        ) ??
        false;
  }

  String _trustFingerprint() {
    final keys =
        client.userDeviceKeys[client.userID]?.deviceKeys.values
            .where((device) => device.verified)
            .map((device) => device.curve25519Key)
            .toList() ??
        [];
    keys.sort((a, b) => (a ?? '').compareTo(b ?? ''));
    return jsonEncode([client.userID, keys]);
  }

  Future<void> _replay() async {
    if (_timeline == null || _replica == null || _disposed) return;
    if (_replaying) {
      _replayAgain = true;
      final completion = _replayCompletion;
      if (completion != null) await completion;
      return;
    }
    _replaying = true;
    final completion = Completer<void>();
    _replayCompletion = completion.future;
    try {
      await _validate();
      _checkActive();
      do {
        _replayAgain = false;
        workerReadiness = null;
        _journalTrustFingerprint = _trustFingerprint();
        final batch = JournalReplayBatch(
          _timeline!.events,
          acceptedEventIds: _acceptedResultEvents,
          trusted: _trusted,
        );
        final heartbeat = batch.heartbeat;
        if (heartbeat != null) {
          workerReadiness = WorkerReadiness.fromPayload(
            Map<String, dynamic>.from(heartbeat.$2.payload),
            heartbeat.$1.originServerTs,
          );
        }
        for (final (event, op) in batch.results) {
          _checkActive();
          await _replica!.acceptResult(op);
          _acceptedResultEvents.add(event.eventId);
        }
      } while (_replayAgain && !_disposed);
    } catch (error) {
      _setFailure(error, PersonalFailurePhase.journalReplay);
    } finally {
      _replaying = false;
      _replayCompletion = null;
      completion.complete();
      notifyListeners();
    }
  }

  List<Event> get dueReminderEvents =>
      _timeline?.events.where((event) {
        if (event.type != personalEventType ||
            event.redacted ||
            !_trusted(event)) {
          return false;
        }
        final payload = event.content['payload'];
        return event.content['kind'] == 'reminder.result' &&
            payload is Map &&
            payload['due'] == true &&
            payload['state'] == 'done' &&
            reminders[event.content['entityId']]?['state'] == 'done';
      }).toList() ??
      [];

  final _claimingAlerts = <String>{};
  Future<bool> claimReminderAlert(Event event) async {
    await _ensureLocal();
    final key = '${_prefix}reminderAlert:${event.content['entityId']}';
    if (!_claimingAlerts.add(key)) return false;
    try {
      if (await _store!.get(key) != null) return false;
      await _store!.put(key, {
        'shownAt': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } finally {
      _claimingAlerts.remove(key);
    }
  }

  Future<void> presentReminder(
    Event event,
    Future<void> Function() present,
  ) async {
    if (!await claimReminderAlert(event)) return;
    try {
      await present();
    } catch (_) {
      await _store!.delete(
        '${_prefix}reminderAlert:${event.content['entityId']}',
      );
      rethrow;
    }
  }

  Future<void> _publish(PersonalOperation op) async {
    await _validate();
    _checkActive();
    final eventId = await journal!.sendEvent(
      op.toJson().cast<String, dynamic>(),
      type: personalEventType,
      txid: op.opId,
      displayPendingEvent: false,
      retryOnTransportFailure: false,
    );
    if (eventId == null || !eventId.startsWith(r'$')) {
      throw TimeoutException('Journal publication was not confirmed');
    }
  }

  Future<PersonalOperation> command(
    String kind,
    String entityId,
    Map<String, dynamic> payload, {
    int? baseRevision,
  }) async {
    await _ensureLocal();
    if (!ready) throw StateError('Private encrypted sync is not connected');
    final op = await _replica!.stageCommand(
      kind,
      entityId,
      payload,
      baseRevision: baseRevision,
    );
    _dispatch();
    return op;
  }

  Future<void> put(String key, Map<String, dynamic> value) async {
    await _ensureLocal();
    if (!ready) throw StateError('Private encrypted sync is not connected');
    await _replica!.queueMetadata(key, value);
    _dispatch();
  }

  Future<void> delete(String key) async {
    await command('metadata.delete', key, {});
  }

  String transcriptId(Event e) =>
      'transcript:${sha256.convert(utf8.encode(source(e).key))}';
  Future<TranscriptCancellation> cancelTranscript(String id) async {
    await _ensureLocal();
    _installSync();
    final result = await _replica!.cancelTranscript(id);
    _dispatch();
    return result;
  }

  Future<void> transcribe(Event e, {String? language}) async {
    final round = RoundVideoDescriptor.fromContent(e.content);
    if (e.redacted ||
        !e.eventId.startsWith(r'$') ||
        (e.messageType != MessageTypes.Audio && round == null) ||
        !RoundMediaPolicy.fromContent(e.content).canTranscribe ||
        (round != null &&
            (await TelegramRoundService.of(client).mediaState(e))?['expired'] ==
                true)) {
      throw StateError('Audio is unavailable');
    }
    await _ensureLocal();
    _installSync();
    final id = transcriptId(e);
    final existing = transcripts[id];
    if (existing != null &&
        {
          JobState.queued,
          JobState.processing,
          JobState.waitingKeys,
          JobState.waitingSync,
        }.contains(existing.state)) {
      return;
    }
    final job = TranscriptionJob(
      id: id,
      source: source(e),
      state: JobState.waitingSync,
      language: language,
    );
    await _replica!.stageCommand(
      'transcript.request',
      id,
      job.toJson().cast<String, dynamic>(),
      optimisticJob: job.toJson().cast<String, dynamic>(),
    );
    _dispatch();
  }

  ImmediateOutbox? _immediate;
  Future<ImmediateSendResult> sendImmediate(
    Room room,
    String text, {
    Event? replyTo,
    String? editEventId,
    String? threadId,
  }) async {
    // Immediate sends need the local encrypted outbox, not the optional
    // worker journal or its potentially long history reconstruction.
    await _ensureLocal();
    final store = _store;
    if (store == null || client.deviceID == null) {
      throw StateError('Encrypted outbox unavailable');
    }
    _immediate ??= ImmediateOutbox(
      deviceId: client.deviceID!,
      get: (key) {
        _checkActive();
        return store.get('${_prefix}outbox:$key');
      },
      put: (key, value) {
        _checkActive();
        return store.put('${_prefix}outbox:$key', value);
      },
      delete: (key) {
        _checkActive();
        return store.delete('${_prefix}outbox:$key');
      },
      sendToTransport: (payload, txid) async {
        _checkActive();
        final sourceRoom = client.getRoomById(payload['roomId'] as String);
        if (sourceRoom == null) {
          throw const ImmediateTransportRejected('sourceUnavailable');
        }
        final replyId = payload['replyId'] as String?;
        final sourceReply = replyId == null
            ? null
            : await sourceRoom.getEventById(replyId);
        _checkActive();
        if (replyId != null && sourceReply == null) {
          throw const ImmediateTransportRejected('replyUnavailable');
        }
        try {
          return await sourceRoom.sendTextEvent(
            payload['text'] as String,
            txid: txid,
            inReplyTo: sourceReply,
            editEventId: payload['editId'] as String?,
            threadRootEventId: payload['threadId'] as String?,
            parseCommands: false,
          );
        } on PersonalCapabilityUnavailable {
          throw const ImmediateTransportRejected('bridge_unavailable');
        } on MatrixException catch (e) {
          if ({
            'M_FORBIDDEN',
            'M_UNKNOWN_TOKEN',
            'M_UNAUTHORIZED',
            'M_BAD_JSON',
            'M_NOT_JSON',
            'M_TOO_LARGE',
          }.contains(e.errcode)) {
            throw const ImmediateTransportRejected();
          }
          rethrow;
        }
      },
    );
    return _immediate!.send({
      'roomId': room.id,
      'text': text,
      'replyId': replyTo?.eventId,
      'editId': editEventId,
      'threadId': threadId,
    });
  }

  Future<void> completeImmediate(String actionId) async =>
      _immediate?.complete(actionId);

  Future<void> savePersonalDraft(
    String key,
    SendTarget target,
    String text,
  ) async {
    if (!key.startsWith('draft:') ||
        target.conversation.accountId != client.userID) {
      throw ArgumentError('Invalid private draft target');
    }
    await _ensureLocal();
    _installSync();
    await _replica!.queueMetadata(key, {
      'text': text,
      'target': target.toJson(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    _dispatch();
  }

  Future<void> saveDraft(Room room, String text) => savePersonalDraft(
    'draft:${room.id}',
    SendTarget(conversation: ref(room)),
    text,
  );
  Future<String?> loadDraft(Room room) async {
    await _ensureLocal();
    return values['draft:${room.id}']?['text'] as String?;
  }

  Future<void> schedule(ScheduledSend job) async {
    if (job.target.conversation.accountId != client.userID) {
      throw ArgumentError('Invalid schedule account');
    }
    await _ensureLocal();
    _installSync();
    await _replica!.stageCommand(
      'schedule.create',
      job.id,
      job.toJson().cast<String, dynamic>(),
      baseRevision: job.revision,
      optimisticJob: {
        ...job.toJson(),
        'state': JobState.waitingSync.name,
      }.cast<String, dynamic>(),
    );
    _dispatch();
  }

  PersonGroupCollection get _groupCollection =>
      parsePersonGroups(values, accountId: client.userID);
  List<PersonGroup> get groups => _groupCollection.groups;
  int get invalidGroupCount => _groupCollection.invalidCount;
  @override
  void dispose() {
    _disposed = true;
    if (identical(_instances[client], this)) _instances.remove(client);
    _sync?.cancel();
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _store?.close();
    _store = null;
    _changes.close();
    super.dispose();
  }
}
