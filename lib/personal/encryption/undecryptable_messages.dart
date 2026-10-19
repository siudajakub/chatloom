// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/encryption.dart' show KeyManager;
import 'package:matrix/matrix.dart';

import 'key_recovery_stage.dart';

export 'key_recovery_stage.dart';

/// An event the timeline still shows as encrypted: decryption failed or has
/// not happened yet. Redacted events are never "waiting".
bool isUndecryptable(Event event) =>
    event.type == EventTypes.Encrypted && !event.redacted;

/// The SDK operations [UndecryptableMessages] needs. All of them are public
/// `KeyManager` calls; nothing here changes how keys are stored or shared.
abstract interface class KeyRecoveryBackend {
  bool get available;
  Future<bool> backupConnected();
  bool get sessionVerified;
  bool hasSession(String roomId, String sessionId);
  Future<void> requestFromBackup(Room room, String sessionId, String? key);
  Future<void> requestFromDevices(Room room, String sessionId, String? key);
  Stream<String> sessionKeysReceived(Room room);
}

class MatrixKeyRecoveryBackend implements KeyRecoveryBackend {
  MatrixKeyRecoveryBackend(this.client);
  final Client client;

  KeyManager? get _keys => client.encryption?.keyManager;

  @override
  bool get available => client.encryptionEnabled && _keys != null;

  @override
  Future<bool> backupConnected() async {
    final keys = _keys;
    if (keys == null || !keys.enabled) return false;
    return keys.isCached();
  }

  @override
  bool get sessionVerified => !client.isUnknownSession;

  @override
  bool hasSession(String roomId, String sessionId) =>
      _keys?.getInboundGroupSession(roomId, sessionId)?.isValid ?? false;

  // `request` is the same call `Event.requestKey` makes, split into its two
  // halves so the bubble can say which one is running.
  @override
  Future<void> requestFromBackup(Room room, String sessionId, String? key) =>
      _keys?.request(room, sessionId, key, onlineKeyBackupOnly: true) ??
      Future<void>.value();

  @override
  Future<void> requestFromDevices(Room room, String sessionId, String? key) =>
      _keys?.request(room, sessionId, key, tryOnlineBackup: false) ??
      Future<void>.value();

  @override
  Stream<String> sessionKeysReceived(Room room) =>
      room.onSessionKeyReceived.stream;
}

/// Per-client tracker of key requests for undecryptable messages, keyed by
/// room and megolm session (every message of one session shares a state).
///
/// Each session is asked automatically once per app run, when its bubble
/// first appears: key backup first (if this device is connected to it),
/// then this account's other devices. "Try again" runs the same flow again.
final class UndecryptableMessages extends ChangeNotifier {
  UndecryptableMessages(
    this.backend, {
    this.deviceAnswerTimeout = const Duration(seconds: 30),
  });

  static final _byClient = Expando<UndecryptableMessages>(
    'undecryptable messages',
  );

  static UndecryptableMessages of(Client client) => _byClient[client] ??=
      UndecryptableMessages(MatrixKeyRecoveryBackend(client));

  /// A message younger than this may still be waiting for a key that is on
  /// its way, so the header does not mention it yet.
  static const settleAfter = Duration(seconds: 10);

  final KeyRecoveryBackend backend;

  /// How long the bubble says "Asked your other devices" before offering
  /// "Try again". A device that answers later still unlocks the message.
  final Duration deviceAnswerTimeout;

  final _stages = <String, ValueNotifier<KeyRecoveryStage?>>{};
  final _runs = <String, int>{};
  final _timers = <String, Timer>{};
  final _rooms = <String, StreamSubscription<String>>{};
  bool _disposed = false;

  static String? _session(Event event) =>
      event.content.tryGet<String>('session_id');

  static String _key(Event event) {
    final session = _session(event);
    // Without a session id there is nothing to request; key by event so the
    // bubble still has a stable (permanent) state.
    return session == null
        ? '${event.room.id}|event|${event.eventId}'
        : '${event.room.id}|$session';
  }

  /// True when asking for the key can help: the SDK kept the encrypted
  /// payload (`can_request_session`) or has not tried to decrypt yet.
  static bool requestable(Event event) =>
      isUndecryptable(event) &&
      _session(event) != null &&
      (event.messageType != MessageTypes.BadEncrypted ||
          event.content['can_request_session'] == true);

  ValueNotifier<KeyRecoveryStage?> _notifier(String key) =>
      _stages[key] ??= ValueNotifier<KeyRecoveryStage?>(null);

  /// Live stage of [event]'s key; `null` until the first request starts.
  ValueListenable<KeyRecoveryStage?> watch(Event event) =>
      _notifier(_key(event));

  KeyRecoveryStage? stageOf(Event event) => _stages[_key(event)]?.value;

  /// Starts the automatic request for [event]'s session, once per app run.
  void ensureRequested(Event event) {
    if (_disposed || !isUndecryptable(event)) return;
    final key = _key(event);
    if (_runs.containsKey(key)) return;
    _start(event, key);
  }

  /// "Try again": runs the whole flow again unless one is still running.
  void retry(Event event) {
    if (_disposed || !isUndecryptable(event)) return;
    final key = _key(event);
    final stage = _stages[key]?.value;
    if (_runs.containsKey(key) && stage == null) return;
    if (stage != null && stage.inFlight) return;
    _start(event, key);
  }

  /// Retries every undecryptable event in [events], once per session.
  /// Returns how many sessions were asked again.
  int retryAll(Iterable<Event> events) {
    final seen = <String>{};
    for (final event in events) {
      if (!isUndecryptable(event) || !seen.add(_key(event))) continue;
      retry(event);
    }
    return seen.length;
  }

  /// [retryAll] for events that may come from several accounts (merged
  /// chats): each event is asked through its own client's tracker.
  static int retryEach(Iterable<Event> events) {
    final byClient = <Client, List<Event>>{};
    for (final event in events) {
      (byClient[event.room.client] ??= []).add(event);
    }
    var asked = 0;
    for (final entry in byClient.entries) {
      asked += UndecryptableMessages.of(entry.key).retryAll(entry.value);
    }
    return asked;
  }

  /// Called by a bubble that is still on screen a while after its key
  /// arrived: that key does not open this message.
  void keyDidNotApply(Event event) {
    final key = _key(event);
    if (_stages[key]?.value == KeyRecoveryStage.keyReceived) {
      _set(key, KeyRecoveryStage.failed);
    }
  }

  /// Undecryptable events old enough for the chat header to mention them.
  static int settledCount(Iterable<Event> events, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(settleAfter);
    return events
        .where((e) => isUndecryptable(e) && e.originServerTs.isBefore(cutoff))
        .length;
  }

  void _start(Event event, String key) {
    final run = (_runs[key] ?? 0) + 1;
    _runs[key] = run;
    _timers.remove(key)?.cancel();
    if (!backend.available || !requestable(event)) {
      _set(key, KeyRecoveryStage.permanent);
      return;
    }
    final room = event.room;
    _listen(room);
    unawaited(
      _run(
        key,
        run,
        room,
        _session(event)!,
        event.content.tryGet<String>('sender_key'),
      ),
    );
  }

  Future<void> _run(
    String key,
    int run,
    Room room,
    String sessionId,
    String? senderKey,
  ) async {
    bool current() => !_disposed && _runs[key] == run;
    try {
      final hadSession = backend.hasSession(room.id, sessionId);
      if (await backend.backupConnected()) {
        if (!current()) return;
        _set(key, KeyRecoveryStage.backup);
        await backend.requestFromBackup(room, sessionId, senderKey);
        if (!current()) return;
        // As in the SDK: a session fresh from backup will open the message;
        // a session we already had did not, so peers may know better.
        if (!hadSession && backend.hasSession(room.id, sessionId)) {
          _set(key, KeyRecoveryStage.keyReceived);
          return;
        }
      }
      if (!current()) return;
      if (!backend.sessionVerified) {
        _set(key, KeyRecoveryStage.verifySession);
        return;
      }
      _set(key, KeyRecoveryStage.devices);
      await backend.requestFromDevices(room, sessionId, senderKey);
      if (!current()) return;
      _timers[key] = Timer(deviceAnswerTimeout, () {
        _timers.remove(key);
        if (current() && _stages[key]?.value == KeyRecoveryStage.devices) {
          _set(key, KeyRecoveryStage.failed);
        }
      });
    } catch (error) {
      // Room and session ids stay out of logs.
      Logs().w('[Personal] Key request failed: ${error.runtimeType}');
      if (current()) _set(key, KeyRecoveryStage.failed);
    }
  }

  void _listen(Room room) {
    if (_rooms.containsKey(room.id)) return;
    _rooms[room.id] = backend.sessionKeysReceived(room).listen((sessionId) {
      final key = '${room.id}|$sessionId';
      final stage = _stages[key]?.value;
      if (stage == KeyRecoveryStage.backup ||
          stage == KeyRecoveryStage.devices) {
        _timers.remove(key)?.cancel();
        _set(key, KeyRecoveryStage.keyReceived);
      }
    });
  }

  void _set(String key, KeyRecoveryStage stage) {
    if (_disposed) return;
    final notifier = _notifier(key);
    if (notifier.value == stage) return;
    notifier.value = stage;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    for (final subscription in _rooms.values) {
      unawaited(subscription.cancel());
    }
    for (final notifier in _stages.values) {
      notifier.dispose();
    }
    super.dispose();
  }
}
