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

  test('a push that started the app is recorded cold with its start-up '
      'time, once; later pushes are warm (BP-10)', () async {
    PushStartupTiming.debugReset();
    addTearDown(PushStartupTiming.debugReset);
    final at = DateTime.utc(2026, 10, 23, 7);
    PushStartupTiming.mainStarted();
    PushStartupTiming.detachedReady(now: at);
    await PushDiagnostics.record(
      PushKind.countOnly,
      PushOutcome.cleared,
      now: at.add(const Duration(seconds: 2)),
    );
    await PushDiagnostics.record(
      PushKind.message,
      PushOutcome.shown,
      now: at.add(const Duration(seconds: 3)),
    );
    // A ready that nobody claims in time is not attributed to a later push.
    PushStartupTiming.detachedReady(now: at);
    await PushDiagnostics.record(
      PushKind.message,
      PushOutcome.shown,
      now: at.add(const Duration(minutes: 5)),
    );
    final snapshot = await PushDiagnostics.read();
    expect(snapshot.recent.map((e) => e.cold), [false, false, true]);
    expect(snapshot.recent.last.startupMs, isNonNegative);
    expect(snapshot.coldStarts.length, 1);
    expect(snapshot.medianColdStartupMs, snapshot.recent.last.startupMs);
    expect(snapshot.counters['start.cold'], 1);
    expect(PushDiagnostics.describe(snapshot), contains('Cold starts: 1 of 3'));
    final parsed = PushDiagnosticsEntry.fromJson(snapshot.recent.last.toJson());
    expect(parsed?.startupMs, snapshot.recent.last.startupMs);
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

  test(
    'reset clears counters and outcomes but keeps the setup steps',
    () async {
      await PushDiagnostics.record(
        PushKind.reminder,
        PushOutcome.reminderShown,
      );
      await PushDiagnostics.setup(PushSetupStep.pusher, ok: true);
      await PushDiagnostics.reset();
      var snapshot = await PushDiagnostics.read();
      expect(snapshot.counters, isEmpty);
      expect(snapshot.recent, isEmpty);
      expect(snapshot.last, isNull);
      expect(snapshot.setup[PushSetupStep.pusher]?.ok, isTrue);
      await PushDiagnostics.clear();
      snapshot = await PushDiagnostics.read();
      expect(snapshot.setup, isEmpty);
    },
  );

  test(
    'setup steps keep the latest attempt with a content-free reason',
    () async {
      final at = DateTime.utc(2026, 10, 21, 8);
      await PushDiagnostics.setup(
        PushSetupStep.token,
        ok: false,
        detail: 'firebase_not_configured',
        now: at,
      );
      await PushDiagnostics.setup(
        PushSetupStep.gateway,
        ok: false,
        detail: 'http_503',
        now: at,
      );
      // Anything that is not a fixed lowercase word is dropped.
      await PushDiagnostics.setup(
        PushSetupStep.pusher,
        ok: false,
        detail: 'M_FORBIDDEN @user:server',
        now: at,
      );
      final snapshot = await PushDiagnostics.read();
      expect(
        snapshot.setup[PushSetupStep.token]!.detail,
        'firebase_not_configured',
      );
      expect(snapshot.setup[PushSetupStep.token]!.at, at);
      expect(snapshot.setup[PushSetupStep.gateway]!.detail, 'http_503');
      expect(snapshot.setup[PushSetupStep.pusher]!.ok, isFalse);
      expect(snapshot.setup[PushSetupStep.pusher]!.detail, isNull);
      final raw = (await SharedPreferences.getInstance()).getString(
        PushDiagnostics.storageKey,
      )!;
      expect(raw, isNot(contains('@user')));
      final text = PushDiagnostics.describe(snapshot);
      expect(text, contains('Setup token: failed (firebase_not_configured)'));
      expect(text, contains('Setup gateway: failed (http_503)'));
      await PushDiagnostics.setup(PushSetupStep.token, ok: true, now: at);
      expect(
        PushDiagnostics.describe(await PushDiagnostics.read()),
        contains('Setup token: ok at'),
      );
    },
  );

  test('setup reasons have readable labels', () {
    expect(
      pushSetupDetailLabel('firebase_not_configured'),
      contains('google-services.json'),
    );
    expect(pushSetupDetailLabel('http_503'), 'The gateway answered HTTP 503');
    expect(
      pushSetupDetailLabel('matrix_m_forbidden'),
      'The homeserver refused (M_FORBIDDEN)',
    );
    expect(pushSetupDetailLabel('forbidden'), contains('authorize'));
    expect(pushSetupDetailLabel('something_new'), 'Failed');
    expect(pushSetupDetailLabel(null), 'Failed');
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
