// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/storage/personal_store.dart';
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

  PersonalClient._(this.client);
  PersonalStore? _store;
  PersonalReplica? _replica;
  Future<void>? _localLoading;
  Future<void>? _attaching;
  Future<void>? _draining;
  bool _disposed = false;
  bool _journalReady = false;
  Future<void>? _loading;
  Timeline? _timeline;
  StreamSubscription? _sync;
  bool _replaying = false;
  Future<void>? _replayCompletion;
  bool _replayAgain = false;
  Room? journal;
  String? problem;
  DateTime? heartbeatAt;
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
    for (final id in List<String>.from(pending.keys)) {
      if (!ready || _disposed) return;
      final op = await _replica!.markPublishing(id);
      if (op == null) continue;
      try {
        await _publish(op);
      } catch (_) {
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

  String get _prefix => 'account:${client.userID}:';
  bool get ready =>
      !_disposed &&
      _journalReady &&
      _store != null &&
      journal != null &&
      problem == null;
  bool get workerOnline =>
      heartbeatAt != null &&
      DateTime.now().difference(heartbeatAt!) < const Duration(minutes: 3);
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
    if (_disposed) throw StateError('Private client is closed');
    final loading = _localLoading ??= _openLocal();
    try {
      await loading;
    } catch (_) {
      // A transient storage failure must not poison every later draft/send.
      if (identical(_localLoading, loading)) _localLoading = null;
      rethrow;
    }
    if (_disposed) throw StateError('Private client is closed');
  }

  Future<void> _openLocal() async {
    if (client.userID == null) {
      throw StateError('A signed-in account is required');
    }
    _store ??= await PersonalStore.open();
    final store = _store!;
    final replica = PersonalReplica(
      read: (key) => store.get('$_prefix$key'),
      write: (key, value) => store.put('$_prefix$key', value),
      newOperationId: () => const Uuid().v4(),
      clock: DateTime.now,
      onChanged: notifyListeners,
    );
    final records = await store.readPrefix(_prefix);
    final local = {
      for (final entry in records.entries)
        entry.key.substring(_prefix.length): entry.value,
    };
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
    _replica = replica;
    notifyListeners();
  }

  void _findJournal() {
    final pointer = client.accountData[personalRoomMarker]?.content['roomId'];
    journal ??= pointer is String ? client.getRoomById(pointer) : null;
    journal ??= client.rooms.where(PersonalPrivacy.isJournal).firstOrNull;
  }

  void _installSync() {
    _sync ??= client.onSync.stream.listen((_) {
      unawaited(_onSync());
    });
  }

  Future<void> _onSync() async {
    if (_disposed || _replica == null) return;
    try {
      _findJournal();
      if (journal == null) return;
      if (_timeline == null || problem != null) {
        await _attach();
      } else {
        await _replay();
      }
      if (ready) await stagePending();
    } catch (_) {
      problem = 'Private sync is paused. Check your connection and try again.';
      notifyListeners();
    }
  }

  Future<void> load() => _loading ??= _load();
  Future<void> retry() async {
    if (_replica == null) {
      _loading = null;
      _localLoading = null;
    }
    await _ensureLocal();
    _installSync();
    await client.accountDataLoading?.timeout(const Duration(seconds: 15));
    _findJournal();
    if (journal != null) await _attach();
  }

  Future<void> _load() async {
    try {
      await _ensureLocal();
      _installSync();
      try {
        await client.accountDataLoading?.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        return;
      }
      final pointer = client.accountData[personalRoomMarker]?.content['roomId'];
      journal = pointer is String ? client.getRoomById(pointer) : null;
      journal ??= client.rooms.where(PersonalPrivacy.isJournal).firstOrNull;
      if (journal != null) await _attach();
    } catch (_) {
      problem =
          'Could not open encrypted private storage. Your data is preserved.';
    }
    notifyListeners();
  }

  Future<void> connect() async {
    if (_replica == null && _localLoading != null) {
      _loading = null;
      _localLoading = null;
    }
    await _ensureLocal();
    _installSync();
    await client.accountDataLoading?.timeout(const Duration(seconds: 15));
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
      await client.waitForRoomInSync(id, join: true);
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
    final room = journal;
    if (room == null || !room.encrypted || !PersonalPrivacy.isJournal(room)) {
      throw StateError('Invalid encrypted journal');
    }
    final members = await room.requestParticipants();
    if (members.any(
      (m) =>
          (m.membership == Membership.join ||
              m.membership == Membership.invite) &&
          m.id != client.userID,
    )) {
      problem = 'Private sync paused: the private room membership changed.';
      notifyListeners();
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
    _journalReady = false;
    await _validate();
    await journal!.setPushRuleState(PushRuleState.dontNotify);
    _timeline?.cancelSubscriptions();
    _timeline = await journal!.getTimeline(
      onUpdate: () => unawaited(_replay()),
    );
    // Reconstruct durable history before replaying unsent commands.
    var pages = 0;
    while (_timeline!.canRequestHistory) {
      final before = _timeline!.events.map((event) => event.eventId).toSet();
      await _timeline!.requestHistory(historyCount: 100);
      final after = _timeline!.events.map((event) => event.eventId).toSet();
      if (after.length == before.length &&
          after.containsAll(before) &&
          _timeline!.canRequestHistory) {
        throw StateError('Journal history pagination stalled');
      }
      if (++pages > 10000) {
        throw StateError('Journal history exceeds safe pagination limit');
      }
    }
    problem = null;
    await _replay();
    _journalReady = problem == null;
    if (ready) await stagePending();
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
      do {
        _replayAgain = false;
        final events = List<Event>.from(_timeline!.events)
          ..sort((a, b) {
            final c = a.originServerTs.compareTo(b.originServerTs);
            return c != 0 ? c : a.eventId.compareTo(b.eventId);
          });
        for (final event in events) {
          if (event.type != personalEventType ||
              event.redacted ||
              !_trusted(event)) {
            continue;
          }
          PersonalOperation op;
          try {
            op = PersonalOperation.fromJson(event.content);
          } catch (_) {
            continue;
          }
          if (!op.kind.endsWith('.result') && op.kind != 'worker.heartbeat') {
            continue;
          }
          if (op.kind == 'worker.heartbeat') {
            heartbeatAt = event.originServerTs;
            continue;
          }
          await _replica!.acceptResult(op);
        }
      } while (_replayAgain && !_disposed);
    } catch (_) {
      problem =
          'Check the connection, encryption keys and private room before syncing.';
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
    await journal!.sendEvent(
      op.toJson().cast<String, dynamic>(),
      type: personalEventType,
      txid: op.opId,
    );
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
      get: (key) => store.get('${_prefix}outbox:$key'),
      put: (key, value) => store.put('${_prefix}outbox:$key', value),
      delete: (key) => store.delete('${_prefix}outbox:$key'),
      sendToTransport: (payload, txid) async {
        final sourceRoom = client.getRoomById(payload['roomId'] as String);
        if (sourceRoom == null) {
          throw const ImmediateTransportRejected('sourceUnavailable');
        }
        final replyId = payload['replyId'] as String?;
        final sourceReply = replyId == null
            ? null
            : await sourceRoom.getEventById(replyId);
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
    _instances.remove(client);
    _sync?.cancel();
    _timeline?.cancelSubscriptions();
    _store?.close();
    _changes.close();
    super.dispose();
  }
}
