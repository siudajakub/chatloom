// SPDX-License-Identifier: AGPL-3.0-or-later
// Key recovery stages for undecryptable messages (fictional ids, fake SDK).
import 'dart:async';

import 'package:fluffychat/personal/encryption/undecryptable_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart' show DecryptException;
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBackend implements KeyRecoveryBackend {
  bool encryption = true;
  bool backup = true;
  bool verified = true;
  bool backupHasKey = false;
  final sessions = <String>{};
  final backupRequests = <String>[];
  final deviceRequests = <String>[];
  final keys = StreamController<String>.broadcast();
  Completer<void>? deviceGate;

  @override
  bool get available => encryption;

  @override
  Future<bool> backupConnected() async => backup;

  @override
  bool get sessionVerified => verified;

  @override
  bool hasSession(String roomId, String sessionId) =>
      sessions.contains('$roomId|$sessionId');

  @override
  Future<void> requestFromBackup(
    Room room,
    String sessionId,
    String? key,
  ) async {
    backupRequests.add(sessionId);
    if (backupHasKey) sessions.add('${room.id}|$sessionId');
  }

  @override
  Future<void> requestFromDevices(
    Room room,
    String sessionId,
    String? key,
  ) async {
    deviceRequests.add(sessionId);
    await deviceGate?.future;
  }

  @override
  Stream<String> sessionKeysReceived(Room room) => keys.stream;
}

late Client _client;
late Room _room;

Event _locked(
  String id, {
  String? session = 'session-a',
  bool requestable = true,
  DateTime? at,
  bool redacted = false,
}) => Event(
  content: {
    'algorithm': AlgorithmTypes.megolmV1AesSha2,
    'ciphertext': 'opaque',
    'sender_key': 'curve-key',
    'session_id': ?session,
    'msgtype': MessageTypes.BadEncrypted,
    'body': DecryptException.unknownSession,
    if (requestable) 'can_request_session': true,
  },
  type: EventTypes.Encrypted,
  eventId: '\$$id',
  senderId: '@sender:example.invalid',
  originServerTs: at ?? DateTime.utc(2026),
  room: _room,
  unsigned: redacted
      ? {
          'redacted_because': {
            'type': EventTypes.Redaction,
            'event_id': r'$redaction',
            'sender': '@sender:example.invalid',
            'origin_server_ts': 0,
            'content': <String, Object?>{},
          },
        }
      : null,
);

/// Lets the tracker's async flow run to its next waiting point.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeBackend backend;
  late UndecryptableMessages tracker;

  setUp(() {
    _client = Client('undecryptable test', database: _UnusedDatabase());
    _room = Room(id: '!room:example.invalid', client: _client);
    backend = _FakeBackend();
    tracker = UndecryptableMessages(
      backend,
      deviceAnswerTimeout: const Duration(milliseconds: 30),
    );
  });

  tearDown(() async {
    tracker.dispose();
    await backend.keys.close();
  });

  test('a key fresh from backup stops before asking other devices', () async {
    backend.backupHasKey = true;
    final event = _locked('a');
    final stages = <KeyRecoveryStage?>[];
    tracker.watch(event).addListener(() => stages.add(tracker.stageOf(event)));
    tracker.ensureRequested(event);
    await _settle();
    expect(stages, [KeyRecoveryStage.backup, KeyRecoveryStage.keyReceived]);
    expect(backend.backupRequests, ['session-a']);
    expect(backend.deviceRequests, isEmpty);
  });

  test('backup miss asks own devices, then fails after the timeout', () async {
    final event = _locked('a');
    tracker.ensureRequested(event);
    await _settle();
    expect(tracker.stageOf(event), KeyRecoveryStage.devices);
    expect(backend.deviceRequests, ['session-a']);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(tracker.stageOf(event), KeyRecoveryStage.failed);
  });

  test('without key backup the devices are asked directly', () async {
    backend.backup = false;
    final event = _locked('a');
    tracker.ensureRequested(event);
    await _settle();
    expect(backend.backupRequests, isEmpty);
    expect(tracker.stageOf(event), KeyRecoveryStage.devices);
  });

  test('an unverified session is told to verify instead of asking', () async {
    backend.verified = false;
    final event = _locked('a');
    tracker.ensureRequested(event);
    await _settle();
    expect(tracker.stageOf(event), KeyRecoveryStage.verifySession);
    expect(backend.deviceRequests, isEmpty);
  });

  test('a key arriving from a device marks it received', () async {
    backend.deviceGate = Completer<void>();
    final event = _locked('a');
    tracker.ensureRequested(event);
    await _settle();
    expect(tracker.stageOf(event), KeyRecoveryStage.devices);
    backend.keys.add('session-a');
    await _settle();
    expect(tracker.stageOf(event), KeyRecoveryStage.keyReceived);
    backend.deviceGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // The device timeout no longer applies once a key arrived.
    expect(tracker.stageOf(event), KeyRecoveryStage.keyReceived);
    tracker.keyDidNotApply(event);
    expect(tracker.stageOf(event), KeyRecoveryStage.failed);
  });

  test('not requestable or no session id is permanent', () async {
    final corrupted = _locked('a', session: null, requestable: false);
    tracker.ensureRequested(corrupted);
    expect(tracker.stageOf(corrupted), KeyRecoveryStage.permanent);
    backend.encryption = false;
    final noEncryption = _locked('b', session: 'session-b');
    tracker.ensureRequested(noEncryption);
    expect(tracker.stageOf(noEncryption), KeyRecoveryStage.permanent);
    expect(backend.backupRequests, isEmpty);
  });

  test('automatic request runs once per session; retry runs again', () async {
    final first = _locked('a');
    final sameSession = _locked('b');
    tracker.ensureRequested(first);
    tracker.ensureRequested(sameSession);
    await _settle();
    expect(backend.backupRequests, hasLength(1));
    // In flight: retry is ignored.
    tracker.retry(first);
    await _settle();
    expect(backend.backupRequests, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(tracker.stageOf(sameSession), KeyRecoveryStage.failed);
    tracker.ensureRequested(first);
    await _settle();
    expect(backend.backupRequests, hasLength(1));
    tracker.retry(sameSession);
    await _settle();
    expect(backend.backupRequests, hasLength(2));
    expect(backend.deviceRequests, hasLength(2));
  });

  test('retryAll asks each session once and skips readable events', () async {
    backend.backup = false;
    final events = [
      _locked('a'),
      _locked('b'),
      _locked('c', session: 'session-c'),
      Event(
        content: {'msgtype': MessageTypes.Text, 'body': 'readable'},
        type: EventTypes.Message,
        eventId: r'$readable',
        senderId: '@sender:example.invalid',
        originServerTs: DateTime.utc(2026),
        room: _room,
      ),
    ];
    expect(tracker.retryAll(events), 2);
    await _settle();
    expect(backend.deviceRequests..sort(), ['session-a', 'session-c']);
  });

  test('settled count ignores fresh and redacted events', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final events = [
      _locked('old', at: now.subtract(const Duration(minutes: 5))),
      _locked('fresh', at: now.subtract(const Duration(seconds: 2))),
      _locked(
        'gone',
        at: now.subtract(const Duration(minutes: 5)),
        redacted: true,
      ),
    ];
    expect(UndecryptableMessages.settledCount(events, now: now), 1);
    expect(isUndecryptable(events[2]), isFalse);
  });
}
