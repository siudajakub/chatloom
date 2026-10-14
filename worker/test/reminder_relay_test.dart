// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/reminder_relay.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Map<String, dynamic> dueResult() => Map<String, dynamic>.from(
  PersonalOperation(
    opId: 'fixture-due-result',
    kind: 'reminder.result',
    entityId: 'fixture-reminder',
    createdAt: DateTime.utc(2026, 10, 4),
    payload: {
      'kind': 'reminder',
      'state': 'done',
      'due': true,
      'conversation': {'roomId': '!private:example.invalid'},
    },
  ).toJson(),
);

class RecordingSink implements ReminderWakeHintSink {
  bool uncertain = false;
  int accepted = 0;
  final seen = <String>{};
  final bodies = <Map<String, Object?>>[];
  @override
  Future<void> publish(ReminderWakeHint hint) async {
    bodies.add(hint.toJson());
    if (seen.add(hint.hintId)) accepted++;
    if (uncertain) throw const WorkerFailure('reminder_relay_deferred');
  }
}

void main() {
  late WorkerStore store;
  setUp(() => store = WorkerStore(sqlite3.openInMemory()));
  tearDown(() => store.close());
  test('relay Retry-After honored without expiring pending hint', () async {
    acknowledgePublishedReminderResult(store, dueResult());
    var calls = 0;
    var now = DateTime.utc(2026, 10, 4);
    final sink = HttpReminderWakeHintSink(
      url: Uri.parse('http://127.0.0.1:8088/internal/reminder'),
      token: 'fixture-token',
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 503, headers: {'retry-after': '300'});
      }),
    );
    final delivery = ReminderHintDelivery(store, sink, clock: () => now);
    await delivery.flush();
    now = now.add(const Duration(seconds: 31));
    await delivery.flush();
    expect(calls, 1);
    expect(store.reminderHints, hasLength(1));
    now = now.add(const Duration(seconds: 270));
    await delivery.flush();
    expect(calls, 2);
    expect(store.reminderHints, hasLength(1));
  });
  test(
    'journal acknowledgement and hint enqueue atomic, hint contains no source IDs',
    () {
      final result = dueResult();
      store.enqueue(result['opId'] as String, result);
      expect(store.reminderHints, isEmpty);
      expect(store.outbox, hasLength(1));
      acknowledgePublishedReminderResult(store, result);
      expect(store.outbox, isEmpty);
      expect(store.reminderHints, hasLength(1));
      final hint = store.reminderHints.single;
      expect(hint.keys.toSet(), {'hintId', 'emittedAt'});
      expect(hint['hintId'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(jsonEncode(hint), isNot(contains('private')));
      acknowledgePublishedReminderResult(store, result);
      expect(store.reminderHints, hasLength(1));
    },
  );
  test('only done due reminder results produce wake hints', () {
    final result = dueResult();
    expect(reminderHintForPublishedResult(result), isNotNull);
    for (final kind in [
      'transcript.result',
      'metadata.result',
      'worker.heartbeat',
      'worker.pairing.result',
    ]) {
      expect(reminderHintForPublishedResult({...result, 'kind': kind}), isNull);
    }
    for (final state in ['queued', 'cancelled', 'conflict']) {
      expect(
        reminderHintForPublishedResult({
          ...result,
          'payload': {'kind': 'reminder', 'state': state, 'due': true},
        }),
        isNull,
      );
    }
  });
  test(
    'missing relay setup leaves hints pending and does not claim delivery',
    () async {
      acknowledgePublishedReminderResult(store, dueResult());
      final delivery = ReminderHintDelivery(store, null);
      await delivery.flush();
      expect(delivery.configured, isFalse);
      expect(store.reminderHints, hasLength(1));
    },
  );
  test(
    'accepted but uncertain relay response retries identical hint after restart',
    () async {
      acknowledgePublishedReminderResult(store, dueResult());
      final sink = RecordingSink()..uncertain = true;
      await ReminderHintDelivery(store, sink).flush();
      expect(store.reminderHints, hasLength(1));
      expect(sink.accepted, 1);
      sink.uncertain = false;
      await ReminderHintDelivery(store, sink).flush();
      expect(store.reminderHints, isEmpty);
      expect(sink.accepted, 1);
      expect(sink.bodies, hasLength(2));
      expect(sink.bodies.first, sink.bodies.last);
    },
  );
  test(
    'HTTP503/no devices retains durable hint with bounded backoff',
    () async {
      acknowledgePublishedReminderResult(store, dueResult());
      var calls = 0;
      var now = DateTime.utc(2026, 10, 4);
      final sink = HttpReminderWakeHintSink(
        url: Uri.parse('http://127.0.0.1:8088/internal/reminder'),
        token: 'fixture-relay-token',
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(
            request.headers['Authorization'],
            'Bearer fixture-relay-token',
          );
          expect((jsonDecode(request.body) as Map).keys.toSet(), {
            'hintId',
            'emittedAt',
          });
          return http.Response('{"error":"no_devices"}', 503);
        }),
      );
      final delivery = ReminderHintDelivery(store, sink, clock: () => now);
      await delivery.flush();
      await delivery.flush();
      expect(calls, 1);
      expect(store.reminderHints, hasLength(1));
      now = now.add(const Duration(seconds: 31));
      await delivery.flush();
      expect(calls, 2);
      expect(store.reminderHints, hasLength(1));
    },
  );
  test(
    'HTTP timeout retains hint, 2xx acknowledges only after retry',
    () async {
      acknowledgePublishedReminderResult(store, dueResult());
      final timeoutSink = HttpReminderWakeHintSink(
        url: Uri.parse('http://127.0.0.1:8088/internal/reminder'),
        token: 'fixture-token',
        timeout: const Duration(milliseconds: 5),
        clientFactory: () => MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response('{}', 200);
        }),
      );
      await ReminderHintDelivery(store, timeoutSink).flush();
      expect(store.reminderHints, hasLength(1));
      final accepted = HttpReminderWakeHintSink(
        url: Uri.parse('http://127.0.0.1:8088/internal/reminder'),
        token: 'fixture-token',
        clientFactory: () => MockClient((_) async => http.Response('{}', 200)),
      );
      await ReminderHintDelivery(store, accepted).flush();
      expect(store.reminderHints, isEmpty);
    },
  );
  test(
    'relay URL prohibits external host, redirects, credentials and query',
    () {
      for (final uri in [
        'https://127.0.0.1:8088/internal/reminder',
        'http://example.invalid:8088/internal/reminder',
        'http://localhost:8088/internal/reminder',
        'http://127.0.0.1:8088/other',
        'http://token@127.0.0.1:8088/internal/reminder',
        'http://127.0.0.1:8088/internal/reminder?token=value',
      ]) {
        expect(
          () => HttpReminderWakeHintSink(url: Uri.parse(uri), token: 'fixture'),
          throwsA(isA<WorkerFailure>()),
        );
      }
    },
  );
}
