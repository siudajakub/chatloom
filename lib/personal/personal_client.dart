// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/journal_replay_batch.dart';
import 'package:chatloom/personal/journal_trust.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

class PersonalClient extends ChangeNotifier {
  static final _instances = <Client, PersonalClient>{};
  static PersonalClient of(Client client) =>
      _instances.putIfAbsent(client, () => PersonalClient._(client));

  /// Tests: makes [of] return [personal] for [client] (until disposed).
  @visibleForTesting
  static void debugUse(Client client, PersonalClient personal) =>
      _instances[client] = personal;
  final Client client;
  final _changes = StreamController<int>.broadcast();
  int _changeVersion = 0;
  Stream<int> get changes => _changes.stream;
  @override
  void notifyListeners() {
    if (!_disposed && !_changes.isClosed) {
      _notifiedState = _observableState();
      _changes.add(++_changeVersion);
      super.notifyListeners();
    }
  }

  // Everything listeners render. Inbox, chats and settings rebuild on every
  // notification, so journal activity which changes none of it stays silent.
  Object? _notifiedState;
  int _replicaRevision = 0;
  int _alertRevision = 0;
  Object _observableState() => (
    _replicaRevision,
    _alertRevision,
    ready,
    problem,
    syncFailure,
    diagnostic?.code,
    diagnostic?.phase,
    workerReadiness,
    journal?.id,
  );

  void _notifyIfChanged() {
    if (!_disposed && _observableState() != _notifiedState) notifyListeners();
  }

  void _replicaChanged() {
    _replicaRevision++;
    // Results applied by one replay pass produce one notification at its end.
    if (!_replaying) notifyListeners();
  }

  PersonalClient._(this.client) : _openStore = PersonalStore.open {
    _watchDelivery();
  }
  @visibleForTesting
  PersonalClient.forTesting(
    this.client, {
    required Future<PersonalStore> Function() openStore,
  }) : _openStore = openStore {
    _watchDelivery();
  }

  /// Final send outcomes (SDK local echo sent/error, bridge send-status
  /// reports) go to [reportDeliveryOutcome] once each.
  StreamSubscription<Event>? _deliveryWatch;
  void _watchDelivery() {
    _deliveryWatch = client.onTimelineEvent.stream.listen((event) {
      final failed = deliveryOutcomeOf(
        event,
        ownUserId: client.userID,
        now: DateTime.now(),
      );
      if (failed != null) reportDeliveryOutcome(event.room, failed: failed);
    });
  }

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
    _notifyIfChanged();
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
  // Journal resume point: every event at or before it is applied or held.
  JournalWatermark? _watermark;
  // Held events outside the loaded timeline, re-read by id on attach.
  final _heldEvents = <String, Event>{};
  // Held ids the server no longer has: a full replay could not apply them.
  final _unavailableHeld = <String>{};
  bool _rescanJournal = true;
  // Newest trusted due reminder result per entity; alerts are claimed once.
  final _dueReminders = <String, Event>{};
  final _claimedReminders = <String>{};
  @visibleForTesting
  int debugReplayPasses = 0;
  String? _journalTrustFingerprint;
  // Trust snapshot of the latest replay pass (verified devices + sessions).
  MegolmTrustSnapshot? _trust;
  // Room keys arriving for held events outside the timeline (L2).
  StreamSubscription<String>? _sessionKeys;
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
    await _reissueUnconfirmed();
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
      unawaited(stagePending().catchError((Object _) => _notifyIfChanged()));
    }
  }

  // ── Unconfirmed changes and conflicts (2026-10-20) ──────────────────────
  // The worker answers a journal command within seconds. A command it has
  // not answered although it kept publishing heartbeats for
  // [unconfirmedAfter] since was most likely never readable for it (for
  // example sent before its device existed, in a session it could only get
  // from key backup, which it does not trust). A resend with the same id
  // returns the old event, so such a change is re-issued under a fresh id.

  /// How long a running worker may leave a published command unanswered.
  static const unconfirmedAfter = Duration(minutes: 5);

  /// When [op] was first published, or null if it was not yet.
  DateTime? publishedAt(PersonalOperation op) {
    final replica = _replica;
    if (replica == null || !replica.isAttempted(op.opId)) return null;
    // Records from before publication times were kept use creation time.
    return replica.attemptedAt(op.opId) ?? op.createdAt.toUtc();
  }

  /// True when [op] was published and the worker, demonstrably running
  /// (a fresh heartbeat newer than the publication by [unconfirmedAfter]),
  /// still has not answered it.
  bool isUnconfirmed(PersonalOperation op, {DateTime? now}) {
    final since = publishedAt(op);
    final heartbeat = workerReadiness;
    return since != null &&
        heartbeat != null &&
        heartbeat.freshAt(now ?? DateTime.now()) &&
        heartbeat.receivedAt.isAfter(since.add(unconfirmedAfter));
  }

  /// How often the change behind [op] was re-issued automatically.
  int reissueCount(PersonalOperation op) =>
      _replica?.reissueCount(op.opId) ?? 0;

  Future<void> _reissueUnconfirmed() async {
    final replica = _replica;
    if (replica == null) return;
    final now = DateTime.now();
    for (final op in List.of(pending.values)) {
      if (!ready || _disposed) return;
      if (!isUnconfirmed(op, now: now)) continue;
      // Only metadata changes and the pairing request; paid or sending jobs
      // are resent only on request ([resendPending]).
      await replica.reissue(op.opId, automatic: true);
    }
  }

  /// Sends an unconfirmed command again under a fresh id (see
  /// [PersonalReplica.reissue]); the worker's revision check keeps a job
  /// that did run from running twice.
  Future<void> resendPending(String opId) async {
    await _ensureLocal();
    if (!ready) throw StateError('Private encrypted sync is not connected');
    await _replica!.reissue(opId);
    _dispatch();
  }

  /// One-tap resolution of a metadata conflict: keep this device's version
  /// (written again over the other one) or use the other version (adopted
  /// locally; nothing is published). See [PersonalReplica.resolveConflict].
  Future<void> resolveConflict(String entity, {required bool keepLocal}) async {
    await _ensureLocal();
    if (keepLocal && !ready) {
      throw StateError('Private encrypted sync is not connected');
    }
    await _replica!.resolveConflict(entity, keepLocal: keepLocal);
    _dispatch();
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
      onChanged: _replicaChanged,
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
    // Conflicts recorded by older versions although both sides are equal
    // (echoes of this device's own writes) need no choice: settle them.
    await replica.settleObsoleteConflicts();
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
      if (replayRequested || _journalTrustFingerprint != _trustFingerprint()) {
        await _replay();
      }
      if (ready) await stagePending();
    } catch (error) {
      _setFailure(error, PersonalFailurePhase.journalReplay);
    }
  }

  /// Cheap for an already-live journal: no participants request, replay or
  /// notification. Every sync still validates membership and replays journal
  /// activity, and each publication validates again.
  Future<void> load() {
    _checkActive();
    if (_loading == null && _liveAndUnchanged()) return Future<void>.value();
    return _startLoad(const Duration(seconds: 3));
  }

  Future<void> retry() =>
      _startLoad(const Duration(seconds: 15), refreshHistory: true);

  bool _liveAndUnchanged() {
    final room = journal;
    if (!ready || _timeline == null || _attaching != null || room == null) {
      return false;
    }
    try {
      // Local state only; anything unexpected takes the validating path.
      return room.encrypted &&
          PersonalPrivacy.isJournal(room) &&
          !room
              .getParticipants(const [Membership.join, Membership.invite])
              .any((member) => member.id != client.userID) &&
          _journalTrustFingerprint == _trustFingerprint();
    } catch (_) {
      return false;
    }
  }

  Future<void> _startLoad(Duration timeout, {bool refreshHistory = false}) {
    _checkActive();
    return _loading ??= _load(
      timeout,
      refreshHistory: refreshHistory,
    ).whenComplete(() => _loading = null);
  }

  Future<void> _load(Duration timeout, {required bool refreshHistory}) async {
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
      if (!refreshHistory && ready && _timeline != null) {
        // Opening a UI surface must not detach an already-live timeline or
        // paginate the journal again. Keep membership and device trust checks.
        await _validate();
        _checkActive();
        if (_journalTrustFingerprint != _trustFingerprint()) await _replay();
        return;
      }
      await _attach();
    } catch (error) {
      _setFailure(error, phase);
    }
    _notifyIfChanged();
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
        name: 'ChatLoom — private sync',
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
    _notifyIfChanged();
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
    // Readiness flips after the final replay pass of a successful attach.
    _notifyIfChanged();
  }

  // Attach loads the resume point plus this margin before it: a still-fresh
  // heartbeat, and results whose journal order could differ slightly. Its
  // results are replayed again, which is idempotent.
  static const _resumeMargin = WorkerReadiness.freshFor;
  // After a full replay only the part after the resume point stays in memory.
  static const _retainedJournalEvents = 500;

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
    final saved = await _replica!.journalWatermark(room.id);
    _checkActive();
    _timeline?.cancelSubscriptions();
    var timeline = await _openJournalTimeline(room);
    _timeline = timeline;
    _watchSessionKeys(room);
    _acceptedResultEvents.clear();
    _dueReminders.clear();
    _heldEvents.clear();
    _unavailableHeld.clear();
    _rescanJournal = true;
    // Reconstruct durable history back to the last applied position (or to
    // the beginning: new or migrated store, unknown or vanished position)
    // before replaying unsent commands.
    var pages = await _pageBack(timeline, saved);
    _checkActive();
    final resumed = saved != null && _indexOf(timeline, saved.eventId) >= 0;
    _watermark = resumed ? saved : null;
    if (resumed) await _loadHeld(room, timeline, saved);
    _checkActive();
    // The first pass must see the stored device list, not an empty one.
    await client.userDeviceKeysLoading;
    _checkActive();
    _clearFailure();
    await _replay();
    _checkActive();
    final anchor = _watermark;
    if (problem == null &&
        anchor != null &&
        timeline.events.length > _retainedJournalEvents) {
      Timeline? bounded;
      try {
        bounded = await _openJournalTimeline(room);
        pages += await _pageBack(bounded, anchor);
      } catch (_) {
        // Bounding is an optimization: keep the complete timeline instead.
      }
      _checkActive();
      if (bounded != null && _indexOf(bounded, anchor.eventId) >= 0) {
        // Held events leaving memory stay reachable for trust/claim changes.
        final kept = {for (final event in bounded.events) event.eventId};
        final held = anchor.held.toSet();
        for (final event in timeline.events) {
          if (held.contains(event.eventId) && !kept.contains(event.eventId)) {
            _heldEvents[event.eventId] = event;
          }
        }
        timeline.cancelSubscriptions();
        _timeline = timeline = bounded;
        _rescanJournal = true;
        await _replay();
        _checkActive();
      } else {
        bounded?.cancelSubscriptions();
      }
    }
    _journalReady = problem == null;
    if (ready) await stagePending();
    if (measurement != null) {
      PersonalPerformanceProbe.emit('journal_attach', {
        'elapsed_ms': measurement.elapsedMilliseconds,
        'events': timeline.events.length,
        'pages': pages,
        'resumed': resumed,
        'held': _watermark?.held.length ?? 0,
      });
    }
  }

  Future<Timeline> _openJournalTimeline(Room room) async {
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
    return timeline;
  }

  static int _indexOf(Timeline timeline, String eventId) =>
      timeline.events.indexWhere((event) => event.eventId == eventId);

  /// Pages history until [anchor] and the resume margin before it are loaded,
  /// or to the beginning when there is no anchor or it is never found.
  Future<int> _pageBack(Timeline timeline, JournalWatermark? anchor) async {
    var pages = 0;
    while (timeline.canRequestHistory && !_resumable(timeline, anchor)) {
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
    return pages;
  }

  static bool _resumable(Timeline timeline, JournalWatermark? anchor) =>
      anchor != null &&
      _indexOf(timeline, anchor.eventId) >= 0 &&
      timeline.events.last.originServerTs.isBefore(
        anchor.originServerTs.subtract(_resumeMargin),
      );

  // Held ids re-read by id per attach, and how many at once: a long held list
  // must not delay readiness. Ids left unread stay held for a later attach
  // (or a key arrival); the newest half is always read, the rest sampled.
  static const _heldReadsPerAttach = 32;
  static const _heldReadConcurrency = 4;
  // A held id the server reports missing on this many attaches in a row is
  // dropped; a single miss may be a server hiccup or a not yet backfilled event.
  static const _heldMissingLimit = 3;
  static const _heldMissingKey = 'journal:heldMissing';
  static final _heldSample = math.Random();

  /// Held events outside the loaded window are re-read by id: they may have
  /// become decryptable, trusted or claimed since the watermark was stored.
  Future<void> _loadHeld(
    Room room,
    Timeline timeline,
    JournalWatermark watermark,
  ) async {
    if (watermark.held.isEmpty) return;
    final stored = await _store!.get('$_prefix$_heldMissingKey');
    _checkActive();
    final counts = stored?['counts'];
    final misses = <String, int>{
      if (counts is Map)
        for (final entry in counts.entries)
          if (entry.key is String && entry.value is int)
            entry.key as String: entry.value as int,
    };
    final before = Map.of(misses);
    final held = watermark.held.toSet();
    misses.removeWhere((id, _) => !held.contains(id));
    final loaded = {for (final event in timeline.events) event.eventId};
    final unread = [
      for (final id in watermark.held.reversed)
        if (!loaded.contains(id)) id,
    ];
    final chosen = unread.length <= _heldReadsPerAttach
        ? unread
        : [
            ...unread.take(_heldReadsPerAttach ~/ 2),
            ...(unread.skip(_heldReadsPerAttach ~/ 2).toList()
                  ..shuffle(_heldSample))
                .take(_heldReadsPerAttach - _heldReadsPerAttach ~/ 2),
          ];
    for (var i = 0; i < chosen.length; i += _heldReadConcurrency) {
      _checkActive();
      final slice = chosen.sublist(
        i,
        math.min(i + _heldReadConcurrency, chosen.length),
      );
      final reads = await Future.wait(slice.map((id) => _readHeld(room, id)));
      _checkActive();
      for (var j = 0; j < slice.length; j++) {
        final id = slice[j];
        final (event, missing) = reads[j];
        if (event != null) {
          _heldEvents[id] = event;
          misses.remove(id);
        } else if (missing) {
          final count = (misses[id] ?? 0) + 1;
          if (count >= _heldMissingLimit) {
            // The homeserver no longer has it; a full replay could not apply
            // it either.
            _unavailableHeld.add(id);
            misses.remove(id);
          } else {
            misses[id] = count;
          }
        }
      }
    }
    if (!mapEquals(before, misses)) {
      await _store!.put('$_prefix$_heldMissingKey', {'counts': misses});
      _checkActive();
    }
  }

  /// One held event by id: (event, false), (null, true) when the server
  /// reports it missing, (null, false) when offline or transient.
  Future<(Event?, bool)> _readHeld(Room room, String id) async {
    try {
      var event = await room.getEventById(id);
      if (event == null) return (null, true);
      if (event.type == EventTypes.Encrypted && client.encryptionEnabled) {
        event = await client.encryption?.decryptRoomEvent(event) ?? event;
      }
      return (event, false);
    } catch (_) {
      // Offline or transient: the id stays held and is read again later.
      return (null, false);
    }
  }

  /// Room keys for held undecrypted events outside the timeline trigger a
  /// replay, whose trust capture decrypts them (the SDK timeline already
  /// re-decrypts its own events and reports them through onUpdate).
  void _watchSessionKeys(Room room) {
    _sessionKeys?.cancel();
    _sessionKeys = room.onSessionKeyReceived.stream.listen((sessionId) {
      if (_disposed || _attaching != null) return;
      final waiting = _heldEvents.values.any(
        (event) =>
            event.type == EventTypes.Encrypted &&
            MegolmTrustSnapshot.sessionIdOf(event) == sessionId,
      );
      if (waiting) unawaited(_replay());
    });
  }

  /// Journal events whose trust matters to the client: results and worker
  /// heartbeats (commands are the worker's business).
  static bool _journalSignal(Event event) {
    if (event.type != personalEventType) return false;
    final kind = event.content['kind'];
    return kind is String &&
        (kind.endsWith('.result') || kind == 'worker.heartbeat');
  }

  String _trustFingerprint() => MegolmTrustSnapshot.fingerprintOf(client);

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
        await _replayPass();
      } while (_replayAgain && !_disposed);
    } catch (error) {
      _setFailure(error, PersonalFailurePhase.journalReplay);
    } finally {
      _replaying = false;
      _replayCompletion = null;
      completion.complete();
      _notifyIfChanged();
    }
  }

  /// Replays the events after the resume point plus the held ones. After an
  /// attach or a device-trust change it rescans every loaded event instead.
  /// The watermark advances only over events applied or settled for good.
  ///
  /// One trust snapshot per pass (verified devices at its start, sessions of
  /// its events): the batch and the settlement below see the same verdicts, so
  /// a result is never settled as applied without having been applied (M1).
  Future<void> _replayPass() async {
    debugReplayPasses++;
    final timeline = _timeline!;
    final room = journal!;
    final trust = MegolmTrustSnapshot.devices(client);
    final rescan =
        _rescanJournal || trust.fingerprint != _journalTrustFingerprint;
    _rescanJournal = false;
    _journalTrustFingerprint = trust.fingerprint;
    var anchor = _watermark;
    if (anchor != null && _indexOf(timeline, anchor.eventId) < 0) {
      // A limited sync dropped the resume point from the live timeline: page
      // back across the gap instead of skipping the events inside it.
      await _pageBack(timeline, anchor);
      _checkActive();
      if (_indexOf(timeline, anchor.eventId) < 0) anchor = _watermark = null;
    }
    // Newest first; events arriving while this pass awaits wait for the next.
    final events = List<Event>.of(timeline.events);
    final anchorIndex = anchor == null
        ? -1
        : events.indexWhere((event) => event.eventId == anchor!.eventId);
    if (anchorIndex < 0) anchor = null;
    final newer = anchor == null ? events : events.sublist(0, anchorIndex);
    final heldIds = anchor?.held ?? const <String>[];
    final held = <String, Event>{};
    if (heldIds.isNotEmpty) {
      final wanted = heldIds.toSet();
      for (final event in events) {
        if (wanted.contains(event.eventId)) held[event.eventId] = event;
      }
      for (final id in heldIds) {
        final fetched = _heldEvents[id];
        if (fetched != null) held.putIfAbsent(id, () => fetched);
      }
    }
    final replayed = rescan ? events : newer;
    await trust.capture(room, [
      ...replayed,
      ...held.values,
      ..._dueReminders.values,
    ], needsProof: _journalSignal);
    _checkActive();
    _trust = trust;
    // Undecrypted events whose room keys are present now replay decrypted.
    final redecrypted = trust.redecrypted;
    Event latest(Event event) => redecrypted[event.eventId] ?? event;
    for (final id in List.of(held.keys)) {
      held[id] = latest(held[id]!);
      if (_heldEvents.containsKey(id)) _heldEvents[id] = held[id]!;
    }
    final unique = <String>{};
    final batch = JournalReplayBatch(
      [
        ...replayed.map(latest),
        ...held.values,
      ].where((event) => unique.add(event.eventId)),
      acceptedEventIds: _acceptedResultEvents,
      trusted: trust.trusts,
    );
    // A rescan recomputes readiness, so a revoked device's heartbeat drops.
    if (rescan) workerReadiness = null;
    final heartbeat = batch.heartbeat;
    final current = workerReadiness;
    if (heartbeat != null &&
        (current == null ||
            heartbeat.$1.originServerTs.isAfter(current.receivedAt))) {
      workerReadiness = WorkerReadiness.fromPayload(
        Map<String, dynamic>.from(heartbeat.$2.payload),
        heartbeat.$1.originServerTs,
      );
    }
    for (final (event, op) in batch.results) {
      _checkActive();
      await _replica!.acceptResult(op);
      _acceptedResultEvents.add(event.eventId);
      _indexDueReminder(event, op);
    }
    // An applied due reminder stays held until its alert is claimed, so the
    // alert survives a restart between replay and presentation.
    final pendingAlerts = <String>{};
    for (final entry in List.of(_dueReminders.entries)) {
      if (reminders[entry.key]?['state'] != 'done') continue;
      if (await _reminderClaimed(entry.key)) continue;
      pendingAlerts.add(entry.value.eventId);
    }
    _checkActive();
    // Without an anchor the loaded timeline must reach the journal's start;
    // otherwise keep full replays (and no watermark) as before.
    if (anchor == null &&
        (events.isEmpty || events.last.type != EventTypes.RoomCreate)) {
      return;
    }
    if (_trustFingerprint() != trust.fingerprint) {
      // Devices changed while this pass awaited: rescan with the new set
      // before the watermark moves over anything.
      _rescanJournal = true;
      _replayAgain = true;
      return;
    }
    JournalSettlement settle(Event event) => JournalReplayBatch.settle(
      latest(event),
      userId: client.userID,
      trust: trust,
      pendingAlert: (event) => pendingAlerts.contains(event.eventId),
    );
    final resolved = <String>{
      for (final id in heldIds)
        if (_unavailableHeld.contains(id) ||
            (held[id] != null &&
                settle(held[id]!) == JournalSettlement.settled))
          id,
    };
    final next = JournalWatermark.advance(
      roomId: room.id,
      previous: anchor,
      newer: [
        for (final event in newer.reversed)
          JournalPosition(event.eventId, event.originServerTs, settle(event)),
      ],
      resolved: resolved,
    );
    if (next == null) return;
    if (!next.sameAs(anchor)) {
      // Serialized behind the commits above: never durable before them.
      await _replica!.saveJournalWatermark(next);
      _checkActive();
    }
    _watermark = next;
    _heldEvents.removeWhere((id, _) => !next.held.contains(id));
    _unavailableHeld.removeAll(resolved);
  }

  void _indexDueReminder(Event event, PersonalOperation op) {
    if (op.kind != 'reminder.result' ||
        op.payload['due'] != true ||
        op.payload['state'] != 'done') {
      return;
    }
    final previous = _dueReminders[op.entityId];
    if (previous != null && JournalReplayBatch.compare(previous, event) >= 0) {
      return;
    }
    _dueReminders[op.entityId] = event;
    // A new alert must wake listeners even when the result was already seen.
    if (!_claimedReminders.contains(op.entityId)) _alertRevision++;
  }

  Future<bool> _reminderClaimed(String entity) async {
    if (_claimedReminders.contains(entity)) return true;
    if (await _store!.get('${_prefix}reminderAlert:$entity') == null) {
      return false;
    }
    _claimedReminders.add(entity);
    return true;
  }

  /// Unclaimed alerts of due reminders, from an index kept by replay rather
  /// than a walk over the journal on every change.
  List<Event> get dueReminderEvents => [
    for (final entry in _dueReminders.entries)
      if (!_claimedReminders.contains(entry.key) &&
          !entry.value.redacted &&
          reminders[entry.key]?['state'] == 'done' &&
          (_trust?.trusts(entry.value) ?? false))
        entry.value,
  ];

  final _claimingAlerts = <String>{};
  Future<bool> claimReminderAlert(Event event) async {
    await _ensureLocal();
    final entity = event.content['entityId'];
    final key = '${_prefix}reminderAlert:$entity';
    if (!_claimingAlerts.add(key)) return false;
    try {
      if (await _store!.get(key) != null) {
        if (entity is String) _claimedReminders.add(entity);
        return false;
      }
      await _store!.put(key, {
        'shownAt': DateTime.now().toUtc().toIso8601String(),
      });
      if (entity is String) _claimedReminders.add(entity);
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
      _claimedReminders.remove(event.content['entityId']);
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

  // ── Automatic transcription (2026-10-17 wave, A-AUTOTRANS) ──────────────
  // The synced TranscriptionPolicy (journal metadata) is shared with the
  // worker. Automatic work needs BOTH that policy and the worker operator
  // switch, which the worker reports as heartbeat `autoTranscription: scan`.
  // Local bridge rooms are scanned by the worker; cloud rooms are invisible
  // to that scan, so a visible message there is requested by this device on
  // the policy's behalf. Old workers (no field) ignore `origin: auto` and
  // would run such a request as an unlimited manual job: never ask them.

  /// How long the panel shows "Transcribing…" while no job is visible.
  static const autoTranscriptPendingWindow = Duration(minutes: 3);

  /// Grace period for the worker's own scan of local bridge rooms before
  /// this device asks instead (idempotent: same entity id, conflict-safe).
  static const autoTranscriptCatchUpDelay = Duration(minutes: 2);

  Object? _policyValue;
  TranscriptionPolicy _policy = TranscriptionPolicy.defaults;
  final _autoRequested = <String>{};
  final _autoTimers = <String, Timer>{};
  Timer? _autoPendingExpiry;
  DateTime? _autoPendingExpiresAt;
  DateTime? _autoBaseline;
  Future<void>? _autoBaselineLoading;

  /// True when the worker reports its operator switch on. Only then does
  /// this device show automatic progress or send `origin: auto` requests.
  bool get autoTranscriptionAvailable =>
      workerReadiness?.autoTranscription == 'scan';

  /// A policy that was never switched on explicitly has no `enabledAt`. Its
  /// window then starts when this device first saw it together with a
  /// scanning worker (kept in the local encrypted store, never journaled, so
  /// devices do not conflict; a later device only narrows its own window).
  /// Without it, an upgrade would request every voice note of the last 24 h.
  DateTime? _autoEnabledAt(TranscriptionPolicy policy) =>
      policy.enabledAt ?? _autoBaseline;

  /// Completes once the window start for a policy without `enabledAt` is
  /// known; records it if this device never saw one.
  @visibleForTesting
  Future<void> loadAutoTranscriptionBaseline() {
    _loadAutoBaseline();
    return _autoBaselineLoading ?? Future<void>.value();
  }

  void _loadAutoBaseline() {
    if (_autoBaseline != null || _autoBaselineLoading != null || _disposed) {
      return;
    }
    final seen = DateTime.now().toUtc();
    final key = '${_prefix}autoTranscriptionBaseline';
    _autoBaselineLoading = () async {
      DateTime? baseline;
      try {
        await _ensureLocal();
        final store = _store;
        if (store != null) {
          final stored = await store.get(key);
          final since = stored?['since'];
          baseline = since is String ? DateTime.tryParse(since)?.toUtc() : null;
          if (baseline == null) {
            await store.put(key, {'since': seen.toIso8601String()});
          }
        }
      } catch (_) {
        // Storage unavailable: this session starts its window now. A later
        // start only narrows it, never widens it.
      }
      if (_disposed) return;
      _autoBaseline = baseline ?? seen;
      notifyListeners();
    }();
  }

  /// Synced policy; absent = automatic for incoming voice/round messages.
  TranscriptionPolicy get transcriptionPolicy {
    final value = values[transcriptionPolicyEntity];
    if (!identical(value, _policyValue)) {
      _policyValue = value;
      _policy = TranscriptionPolicy.fromValue(value);
    }
    return _policy;
  }

  /// Saves the policy as private journal metadata (coalesced while pending).
  Future<void> setTranscriptionPolicy(TranscriptionPolicy policy) =>
      put(transcriptionPolicyEntity, policy.toJson());

  /// The synced default transcription language (null = automatic detection).
  String? get transcriptionDefaultLanguage =>
      transcriptionPolicy.defaultLanguage;

  /// Speech media that may be sent for transcription (voice notes, other
  /// audio, rounds, videos, media files; see `transcribableMediaKind`);
  /// null for anything else, including protected media and silent loops.
  static AutoTranscriptionKind? autoTranscriptionKind(Event e) {
    if (e.redacted ||
        e.type != EventTypes.Message ||
        !e.eventId.startsWith(r'$')) {
      return null;
    }
    return transcribableMediaKind(e.content);
  }

  /// True when the worker transcribes every video and media file
  /// (heartbeat `transcriptionMedia` >= 2). Older workers only accept
  /// `m.audio` and strict rounds, and refuse videos with `not_audio`.
  bool get workerTranscribesAllMedia =>
      (workerReadiness?.transcriptionMedia ?? 0) >= 2;

  /// True when the worker treats Instagram reels as their own kind
  /// (heartbeat `transcriptionMedia` >= 3) and so honours the reel switch.
  /// A worker reporting 2 transcribes a reel automatically like any video
  /// while videos are on; on demand it transcribes reels either way.
  bool get workerSeparatesReels =>
      (workerReadiness?.transcriptionMedia ?? 0) >= 3;

  /// The kind of [e] the paired worker can transcribe, or null. Panels use
  /// it to decide whether to offer transcription at all.
  AutoTranscriptionKind? transcribableKind(Event e) {
    final kind = autoTranscriptionKind(e);
    if (kind == null || workerTranscribesAllMedia) return kind;
    return switch (kind) {
      AutoTranscriptionKind.voice || AutoTranscriptionKind.round => kind,
      AutoTranscriptionKind.audio when e.messageType == MessageTypes.Audio =>
        kind,
      _ => null,
    };
  }

  /// Why [e] is not transcribed automatically (see autoTranscriptionBlock).
  /// Extra codes: `worker_off` (worker switch off or an old worker),
  /// `disappearing` (the chat has a disappearing-message timer) and
  /// `before_enabled` while this device's window start is not known yet.
  String? autoTranscriptionBlockFor(Event e, DateTime now) {
    if (!autoTranscriptionAvailable) return 'worker_off';
    final kind = autoTranscriptionKind(e);
    // Older workers were only ever asked for voice notes and rounds.
    if (kind != null &&
        !workerTranscribesAllMedia &&
        kind != AutoTranscriptionKind.voice &&
        kind != AutoTranscriptionKind.round) {
      return 'worker_off';
    }
    final room = e.room;
    // Room state is the chat's current setting; fail closed on any value
    // other than an explicit "off".
    if (disappearingTimerLimits(
      room.getState(beeperDisappearingTimerKey)?.content,
    )) {
      return 'disappearing';
    }
    final policy = transcriptionPolicy;
    final enabledAt = _autoEnabledAt(policy);
    if (policy.auto && enabledAt == null) return 'before_enabled';
    final network = networkOf(room);
    String? group;
    for (final candidate in groups) {
      if (candidate.members.any((member) => member.roomId == room.id)) {
        group = candidate.id;
        break;
      }
    }
    final duration = e.content['info'] is Map
        ? (e.content['info'] as Map)['duration']
        : null;
    return autoTranscriptionBlock(
      policy.enabledAt == null
          ? policy.copyWith(enabledAt: () => enabledAt)
          : policy,
      AutoTranscriptionCandidate(
        kind: kind,
        network: network,
        roomId: room.id,
        outgoing: OwnSenderResolver.of(client).isOwnEvent(e),
        timestamp: e.originServerTs,
        durationMs: duration is int && duration >= 0 ? duration : null,
        chatMetadata: values['org:${room.id}'],
        personMetadata: group == null ? null : values['org:person:$group'],
        networkMetadata: values['network-policy:$network'],
      ),
      now: now,
    );
  }

  /// True while an automatic transcription for [e] is expected but no job is
  /// visible yet, so the panel shows "Transcribing…". Requires the policy,
  /// a fresh heartbeat of a worker whose operator switch is on
  /// ([autoTranscriptionAvailable]), an incoming eligible message, no job and
  /// a message younger than [autoTranscriptPendingWindow]. Also schedules
  /// the catch-up request for a visible message the worker did not pick up.
  bool autoTranscriptPending(Event e) {
    if (!ready ||
        !transcriptionPolicy.auto ||
        !workerOnline ||
        !autoTranscriptionAvailable) {
      return false;
    }
    if (transcriptionPolicy.enabledAt == null && _autoBaseline == null) {
      _loadAutoBaseline();
      return false;
    }
    final id = transcriptId(e);
    if (transcripts.containsKey(id) || _autoRequested.contains(id)) {
      return false;
    }
    final now = DateTime.now();
    if (autoTranscriptionBlockFor(e, now) != null) return false;
    final age = now.difference(e.originServerTs);
    _scheduleAutoCatchUp(
      e,
      id,
      // Give the scanning worker time to pick up local-bridge messages
      // first (and cloud rooms too when it watches its own sync); older
      // workers cannot see cloud rooms, so those are asked for right away.
      e.room.id.endsWith(':beeper.local') ||
              workerReadiness?.autoTranscriptionLive == true
          ? autoTranscriptCatchUpDelay - age
          : Duration.zero,
    );
    if (age >= autoTranscriptPendingWindow) return false;
    _armAutoPendingExpiry(e.originServerTs.add(autoTranscriptPendingWindow));
    return true;
  }

  /// Panels re-read [autoTranscriptPending] only on notification: one timer
  /// for the earliest window end keeps an expired spinner from sticking.
  void _armAutoPendingExpiry(DateTime at) {
    final armed = _autoPendingExpiresAt;
    if (_disposed || (armed != null && !at.isBefore(armed))) return;
    _autoPendingExpiry?.cancel();
    _autoPendingExpiresAt = at;
    final wait = at.difference(DateTime.now());
    _autoPendingExpiry = Timer(
      (wait.isNegative ? Duration.zero : wait) +
          const Duration(milliseconds: 50),
      () {
        _autoPendingExpiry = null;
        _autoPendingExpiresAt = null;
        notifyListeners();
      },
    );
  }

  /// Cancels pending catch-up and expiry timers (dispose and tests).
  void cancelAutoTranscriptionTimers() {
    for (final timer in _autoTimers.values) {
      timer.cancel();
    }
    _autoTimers.clear();
    _autoPendingExpiry?.cancel();
    _autoPendingExpiry = null;
    _autoPendingExpiresAt = null;
  }

  void _scheduleAutoCatchUp(Event e, String id, Duration wait) {
    if (_disposed || _autoTimers.containsKey(id)) return;
    // Never inside build: the request notifies listeners.
    _autoTimers[id] = Timer(wait.isNegative ? Duration.zero : wait, () {
      _autoTimers.remove(id);
      unawaited(_autoCatchUp(e, id));
    });
  }

  Future<void> _autoCatchUp(Event e, String id) async {
    // Re-checked when the timer fires: the switch may have gone off since.
    if (_disposed ||
        !ready ||
        !workerOnline ||
        !autoTranscriptionAvailable ||
        transcripts.containsKey(id)) {
      return;
    }
    if (autoTranscriptionBlockFor(e, DateTime.now()) != null ||
        !_autoRequested.add(id)) {
      return;
    }
    try {
      await _requestTranscript(
        e,
        language: transcriptionPolicy.defaultLanguage,
        origin: TranscriptionOrigin.auto,
      );
    } catch (_) {
      // Keep the id: an automatic request is never retried in a loop. The
      // panel falls back to its manual button.
    }
    notifyListeners();
  }

  Future<TranscriptCancellation> cancelTranscript(String id) async {
    await _ensureLocal();
    _installSync();
    final result = await _replica!.cancelTranscript(id);
    _dispatch();
    return result;
  }

  Future<void> transcribe(Event e, {String? language}) =>
      _requestTranscript(e, language: language);

  Future<void> _requestTranscript(
    Event e, {
    String? language,
    TranscriptionOrigin origin = TranscriptionOrigin.manual,
  }) async {
    final round = RoundVideoDescriptor.fromContent(e.content);
    if (e.redacted ||
        !e.eventId.startsWith(r'$') ||
        transcribableKind(e) == null ||
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
        (origin == TranscriptionOrigin.auto ||
            {
              JobState.queued,
              JobState.processing,
              JobState.waitingKeys,
              JobState.waitingSync,
            }.contains(existing.state))) {
      return;
    }
    final job = TranscriptionJob(
      id: id,
      source: source(e),
      state: JobState.waitingSync,
      language: language,
      origin: origin,
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

  /// Per source room: completes when the previous text send's local echo is
  /// in the timeline (or that send ended), so messages keep their order
  /// while each one is still sent as soon as possible.
  final _sendOrder = <String, Future<void>>{};

  /// Transaction IDs whose local echo the SDK stored and showed (bounded).
  final _echoed = <String>{};

  Future<ImmediateOutbox> _immediateOutbox() async {
    // Immediate sends need the local encrypted outbox, not the optional
    // worker journal or its potentially long history reconstruction.
    await _ensureLocal();
    final store = _store;
    if (store == null || client.deviceID == null) {
      throw StateError('Encrypted outbox unavailable');
    }
    return _immediate ??= ImmediateOutbox(
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
      sendToTransport: _sendImmediateTransport,
    );
  }

  Future<String?> _sendImmediateTransport(
    Map<String, dynamic> payload,
    String txid,
  ) async {
    final roomId = payload['roomId'] as String;
    final previous = _sendOrder[roomId];
    final queued = Completer<void>();
    _sendOrder[roomId] = queued.future;
    StreamSubscription<Event>? echo;
    try {
      if (previous != null) await previous;
      _checkActive();
      final sourceRoom = client.getRoomById(roomId);
      if (sourceRoom == null) {
        throw const ImmediateTransportRejected('sourceUnavailable');
      }
      echo = client.onTimelineEvent.stream.listen((event) {
        if (event.roomId != roomId ||
            (event.transactionId != txid && event.eventId != txid)) {
          return;
        }
        if (_echoed.length > 256) _echoed.remove(_echoed.first);
        _echoed.add(txid);
        if (!queued.isCompleted) queued.complete();
      });
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
    } finally {
      await echo?.cancel();
      if (!queued.isCompleted) queued.complete();
      if (identical(_sendOrder[roomId], queued.future)) {
        _sendOrder.remove(roomId);
      }
    }
  }

  /// Sends [text] through the encrypted outbox. [onDurable] runs once the
  /// attempt is persisted and before any network I/O: the composer clears
  /// there and the local echo shows the network result. It never runs when
  /// the outbox cannot persist; the caller then keeps the text.
  Future<ImmediateSendResult> sendImmediate(
    Room room,
    String text, {
    Event? replyTo,
    String? editEventId,
    String? threadId,
    ImmediateDurable? onDurable,
  }) async {
    final outbox = await _immediateOutbox();
    // Every press of send is a new message: the same text twice is two
    // messages, while an attempt left by an earlier process is resumed.
    return outbox.send(
      {
        'roomId': room.id,
        'text': text,
        'replyId': replyTo?.eventId,
        'editId': editEventId,
        'threadId': threadId,
      },
      fresh: true,
      onDurable: onDurable,
    );
  }

  Future<void> completeImmediate(String actionId) async =>
      _immediate?.complete(actionId);

  /// The outbox action of a text local echo (`immediate-<id>`), or null.
  static String? immediateActionOf(Event event) {
    final txid = event.transactionId ?? event.eventId;
    final match = RegExp(
      r'^immediate-([A-Za-z0-9_-]{1,128})$',
    ).firstMatch(txid);
    return match?[1];
  }

  /// Explicit retry of a failed or unconfirmed text send from its bubble:
  /// same payload, same Matrix transaction ID, so it is never duplicated.
  Future<ImmediateSendResult> retryImmediate(String actionId) async =>
      (await _immediateOutbox()).retry(actionId);

  /// Retires an unsent attempt deleted from its bubble.
  Future<void> discardImmediate(String actionId) async =>
      (await _immediateOutbox()).discard(actionId);

  /// Stored state of an attempt (unknown vs rejected), or null.
  Future<ImmediateSendResult?> immediateState(String actionId) async =>
      (await _immediateOutbox()).lookup(actionId);

  /// Whether the SDK showed a local echo for [transactionId], i.e. a failed
  /// send has its own bubble with Retry. False means the send failed before
  /// it reached the timeline and the caller must give the text back.
  bool localEchoShown(String transactionId) => _echoed.contains(transactionId);

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

  /// Saved person groups of this account, without groups that are being
  /// unmerged: a staged `metadata.delete` (awaiting the worker) or a removal
  /// that waits for an earlier change of the same group ([removeGroup]).
  /// A rejected delete clears its pending operation, so the group returns.
  List<PersonGroup> get groups {
    final all = _groupCollection.groups;
    if (_unmerging.isEmpty && pending.isEmpty) return all;
    final deleting = <String>{
      for (final op in pending.values)
        if (op.kind == 'metadata.delete' && op.entityId.startsWith('person:'))
          op.entityId,
    };
    if (_unmerging.isEmpty && deleting.isEmpty) return all;
    return List.unmodifiable(
      all.where(
        (group) =>
            !_unmerging.contains(group.id) &&
            !deleting.contains('person:${group.id}'),
      ),
    );
  }

  int get invalidGroupCount => _groupCollection.invalidCount;

  // Group ids hidden while their delete waits for an earlier acknowledgement.
  final _unmerging = <String>{};

  /// Saves [group] (new or changed members). Cancels a removal of the same
  /// group that is not staged yet, e.g. when a merge is undone. A change
  /// while an earlier one awaits acknowledgement is coalesced by the replica.
  Future<void> putGroup(PersonGroup group) async {
    if (group.members.any((member) => member.accountId != client.userID)) {
      throw ArgumentError('Invalid person group account');
    }
    final cancelled = _unmerging.remove(group.id);
    try {
      await put('person:${group.id}', group.toJson().cast<String, dynamic>());
    } finally {
      if (cancelled) notifyListeners();
    }
  }

  /// Longest wait of [removeGroup] for the acknowledgement of an earlier
  /// change of the same group (worker offline: the unmerge fails visibly).
  @visibleForTesting
  static Duration unmergeAcknowledgementWait = const Duration(seconds: 20);

  /// Unmerges the person group [id]. Its source chats, messages and private
  /// metadata (nickname, pins, rules) are kept. The group is hidden at once;
  /// when an earlier change of it still awaits the worker's acknowledgement
  /// (a merge that was just made), the delete is staged right after that
  /// acknowledgement. The wait is memory-only and bounded by
  /// [unmergeAcknowledgementWait]: without an acknowledgement the group is
  /// shown again and this throws, so the user never believes an unmerge
  /// happened that was not staged. Completes once the delete is staged or
  /// the removal was cancelled by [putGroup].
  Future<void> removeGroup(String id) async {
    final key = 'person:$id';
    if (!ready) throw StateError('Private encrypted sync is not connected');
    if (!_unmerging.add(id)) return;
    notifyListeners();
    var staged = false;
    final deadline = DateTime.now().add(unmergeAcknowledgementWait);
    try {
      while (pending.values.any((op) => op.entityId == key)) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw StateError('Unmerge awaits private sync; try again later');
        }
        try {
          await changes.first.timeout(remaining);
        } on TimeoutException {
          throw StateError('Unmerge awaits private sync; try again later');
        } on StateError {
          return; // Disposed: nothing was staged.
        }
        if (_disposed || !_unmerging.contains(id)) return;
      }
      if (!values.containsKey(key)) return;
      await delete(key);
      staged = true;
    } finally {
      // A staged delete keeps the group hidden through its pending operation.
      if (_unmerging.remove(id) && !staged) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _deliveryWatch?.cancel();
    if (identical(_instances[client], this)) _instances.remove(client);
    cancelAutoTranscriptionTimers();
    _sync?.cancel();
    _sessionKeys?.cancel();
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _store?.close();
    _store = null;
    _changes.close();
    super.dispose();
  }
}
