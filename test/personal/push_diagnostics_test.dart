// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/ui/push_diagnostics_page.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PushDiagnostics.reset();
  });

  test('push kinds come only from fixed markers', () {
    expect(pushKindOf({'personal_wake': 'reminder'}), PushKind.reminder);
    // Remote data can never mark a push as a test; only the in-process flag.
    expect(
      pushKindOf({'event_id': r'$e', 'personal_test': '1'}),
      PushKind.message,
    );
    expect(pushKindOf({'event_id': r'$e'}, test: true), PushKind.test);
    final data = testFcmData(eventId: r'$e', roomId: '!r', unread: 1);
    expect(data.keys.toSet(), {'event_id', 'room_id', 'counts', 'devices'});
    expect(pushKindOf(data), PushKind.message);
    expect(
      pushKindOf({'event_id': r'$e', 'room_id': '!r', 'counts': '{}'}),
      PushKind.message,
    );
    expect(pushKindOf({'counts': '{"unread":0}'}), PushKind.countOnly);
  });

  test(
    'received and outcomes are counted and kept in a bounded ring',
    () async {
      final at = DateTime.utc(2026, 10, 17, 12);
      await PushDiagnostics.received(PushKind.message, now: at);
      for (var i = 0; i < 25; i++) {
        await PushDiagnostics.record(
          PushKind.message,
          i.isEven ? PushOutcome.shown : PushOutcome.seen,
          elapsed: Duration(milliseconds: i),
          now: at.add(Duration(seconds: i)),
        );
      }
      await PushDiagnostics.record(
        PushKind.message,
        PushOutcome.timeout,
        error: TimeoutException('secret detail @user:server !room \$event'),
      );
      final snapshot = await PushDiagnostics.read();
      expect(snapshot.lastReceivedAt, at);
      expect(snapshot.lastKind, PushKind.message);
      expect(snapshot.received(PushKind.message), 1);
      expect(snapshot.count(PushOutcome.received), 1);
      expect(snapshot.count(PushOutcome.shown), 13);
      expect(snapshot.count(PushOutcome.seen), 12);
      expect(snapshot.recent, hasLength(PushDiagnostics.maxRecent));
      expect(snapshot.last!.outcome, PushOutcome.timeout);
      expect(snapshot.last!.errorType, 'TimeoutException');
      final raw = (await SharedPreferences.getInstance()).getString(
        PushDiagnostics.storageKey,
      )!;
      for (final secret in ['secret', '@user', '!room', r'$event']) {
        expect(raw, isNot(contains(secret)));
      }
    },
  );

  test('copy text contains checks, outcomes and counts only', () async {
    await PushDiagnostics.received(PushKind.test);
    await PushDiagnostics.record(PushKind.test, PushOutcome.shown);
    final text = PushDiagnostics.describe(
      await PushDiagnostics.read(),
      checks: {'Notifications allowed': 'Yes'},
    );
    expect(text, contains('Notifications allowed: Yes'));
    expect(text, contains('Last outcome: shown'));
    expect(text, contains('received.test: 1'));
    expect(text, isNot(contains('!')));
  });

  test('reset clears everything', () async {
    await PushDiagnostics.record(PushKind.reminder, PushOutcome.reminderShown);
    await PushDiagnostics.reset();
    final snapshot = await PushDiagnostics.read();
    expect(snapshot.counters, isEmpty);
    expect(snapshot.recent, isEmpty);
    expect(snapshot.last, isNull);
  });

  test('corrupt or unavailable storage never throws', () async {
    SharedPreferences.setMockInitialValues({
      PushDiagnostics.storageKey: '{not json',
    });
    expect((await PushDiagnostics.read()).counters, isEmpty);
    await PushDiagnostics.record(PushKind.message, PushOutcome.shown);
    expect((await PushDiagnostics.read()).count(PushOutcome.shown), 1);
    Future<SharedPreferences> broken() async =>
        throw StateError('storage unavailable');
    await PushDiagnostics.record(
      PushKind.message,
      PushOutcome.error,
      store: broken,
    );
    await PushDiagnostics.received(PushKind.message, store: broken);
    expect((await PushDiagnostics.read(store: broken)).counters, isEmpty);
  });

  test('exception names are sanitized and bounded', () {
    expect(PushDiagnostics.errorType(StateError('x')), 'StateError');
    expect(
      PushDiagnostics.errorType(
        _VeryLongNamedFailureForSanitizerCheck(),
      ).length,
      lessThanOrEqualTo(48),
    );
  });

  test('every outcome and kind has an English label', () {
    for (final outcome in PushOutcome.values) {
      expect(
        pushOutcomeLabel(outcome),
        matches(RegExp(r'^[A-Z][A-Za-z ,()-]+$')),
      );
    }
    for (final kind in PushKind.values) {
      expect(pushKindLabel(kind), isNotEmpty);
    }
  });

  test('verdict names the first failing check or says healthy', () {
    expect(pushDiagnosticsVerdict(const []), 'Notifications look healthy');
    expect(
      pushDiagnosticsVerdict(const [null, null]),
      'Notifications look healthy',
    );
    expect(
      pushDiagnosticsVerdict(const [
        null,
        'Messages channel is silent',
        'No Firebase token',
      ]),
      'Problem: Messages channel is silent',
    );
  });

  test('silent or off channels are problems; others are not', () {
    expect(channelStateIsProblem('Off'), isTrue);
    expect(channelStateIsProblem('Silent'), isTrue);
    for (final state in ['On', 'On, pops up', 'Not created yet', 'Unknown']) {
      expect(channelStateIsProblem(state), isFalse, reason: state);
    }
    expect(pushDiagnosticsFixHint, 'Tap to change in system settings');
  });
}

class _VeryLongNamedFailureForSanitizerCheck implements Exception {}
