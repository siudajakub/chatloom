// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _CapturedStderr implements Stdout {
  final lines = <String>[];
  @override
  void writeln([Object? object = '']) => lines.add('$object');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CaptureIO extends IOOverrides {
  final _CapturedStderr output = _CapturedStderr();
  @override
  Stdout get stderr => output;
}

class _Client implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room implements Room {
  bool fail = false;
  bool returnNull = false;
  final accepted = <String>[];
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    if (fail) throw StateError('synthetic failure');
    if (returnNull) return null;
    accepted.add(content['opId'] as String);
    return r'$synthetic-event';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Transport implements FeatureTransport {
  @override
  String get accountId => '@synthetic:example.invalid';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Transcriber implements Transcriber {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Bypass enrollment validation only; exercise the actual production flush path.
class _Journal extends WorkerJournal {
  final _Room room;
  _Journal(WorkerStore store, this.room)
    : super(
        _Client(),
        '!synthetic:example.invalid',
        {},
        store,
        WorkerEngine(store, _Transport(), _Transcriber()),
      );
  @override
  Future<Room> validate() async => room;
}

void main() {
  late WorkerStore store;
  late _Room room;
  late _Journal journal;
  late _CaptureIO capture;
  var sequence = 0;

  void enqueue({
    Map<String, dynamic> overrides = const {},
    String kind = 'worker.heartbeat',
  }) {
    final id = 'synthetic-${sequence++}';
    store.enqueue(
      id,
      PersonalOperation(
        opId: id,
        kind: kind,
        entityId: 'private-entity-sentinel',
        createdAt: DateTime.utc(2026, 11, 3),
        payload: {
          'summary': 'ready',
          'summaryVersion': 1,
          'healthy': true,
          'verified': true,
          'secret': 'private-payload-sentinel',
          'untrustedDevices': ['private-device-sentinel'],
          ...overrides,
        },
      ).toJson(),
    );
  }

  Future<void> flush() =>
      IOOverrides.runWithIOOverrides(journal.flush, capture);

  setUp(() {
    sequence = 0;
    store = WorkerStore(sqlite3.openInMemory());
    room = _Room();
    journal = _Journal(store, room);
    capture = _CaptureIO();
  });
  tearDown(() => store.close());

  test('readiness receipt requires a successful server event id', () async {
    enqueue();
    room.fail = true;
    await flush();
    expect(capture.output.lines, isEmpty);
    room.fail = false;
    room.returnNull = true;
    await flush();
    expect(capture.output.lines, isEmpty);
    room.returnNull = false;
    await flush();
    expect(room.accepted, ['synthetic-0']);
    expect(capture.output.lines, [
      'Worker heartbeat published: summary ready, version 1, healthy true, verified true',
    ]);
  });

  test(
    'receipt is allowlisted and emitted once per readiness change',
    () async {
      enqueue();
      enqueue();
      await flush();
      expect(capture.output.lines, hasLength(1));
      enqueue(overrides: {'summary': 'not_configured'});
      await flush();
      expect(capture.output.lines, hasLength(2));
      enqueue();
      await flush();
      expect(capture.output.lines, hasLength(3));
      expect(capture.output.lines.join('\n'), isNot(contains('private-')));
      expect(capture.output.lines.join('\n'), isNot(contains('synthetic-')));
    },
  );

  test(
    'unhealthy, unverified, unsupported and non-heartbeat input stays silent',
    () async {
      for (final overrides in <Map<String, dynamic>>[
        {'healthy': false},
        {'verified': false},
        {'summaryVersion': 2},
        {'summary': 'private-status-sentinel'},
      ]) {
        enqueue(overrides: overrides);
      }
      enqueue(kind: 'metadata.result');
      await flush();
      expect(room.accepted, hasLength(5));
      expect(capture.output.lines, isEmpty);
    },
  );
}
