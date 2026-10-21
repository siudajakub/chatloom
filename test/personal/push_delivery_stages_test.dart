// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/push_delivery_stages.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.utc(2026, 10, 21, 9);
String _time(DateTime at) => at.toUtc().toIso8601String();

PushDiagnosticsSnapshot _snapshot({
  Map<PushSetupStep, PushSetupRecord> setup = const {},
  DateTime? receivedAt,
  List<PushDiagnosticsEntry> recent = const [],
}) => PushDiagnosticsSnapshot(
  setup: setup,
  lastReceivedAt: receivedAt,
  lastKind: receivedAt == null ? null : PushKind.message,
  recent: recent,
);

/// Everything working end to end.
PushStageFacts _healthy({
  PushDiagnosticsSnapshot? snapshot,
  PushGatewayProbe probe = const PushGatewayProbe(
    PushGatewayReachability.online,
    405,
  ),
}) => PushStageFacts(
  firebaseConfigured: true,
  tokenPresent: true,
  permission: true,
  messagesChannel: 'On, pops up',
  phase: PushRegistrationPhase.automaticallyConfigured,
  probe: probe,
  pusherChecked: true,
  pusherExists: true,
  pusherTokenKnown: true,
  pusherTokenMatches: true,
  pusherUrlMatches: true,
  pusherNonceMatches: true,
  snapshot:
      snapshot ??
      _snapshot(
        setup: {
          PushSetupStep.token: PushSetupRecord(at: _at, ok: true),
          PushSetupStep.gateway: PushSetupRecord(
            at: _at,
            ok: true,
            detail: 'registered',
          ),
          PushSetupStep.pusher: PushSetupRecord(
            at: _at,
            ok: true,
            detail: 'posted',
          ),
        },
        receivedAt: _at,
        recent: [
          PushDiagnosticsEntry(
            at: _at,
            kind: PushKind.message,
            outcome: PushOutcome.shown,
          ),
        ],
      ),
);

void main() {
  test('a working phone shows seven OK steps and no problem', () {
    final stages = pushDeliveryStages(_healthy(), time: _time);
    expect(stages, hasLength(7));
    expect(stages.map((stage) => stage.state).toSet(), {PushStageState.ok});
    expect(stageProblems(stages), isEmpty);
    expect(stages[3].detail, contains('gateway is online'));
  });

  test('an APK built without google-services.json stops at step 1, and the '
      'token step says why', () {
    final stages = pushDeliveryStages(
      const PushStageFacts(
        firebaseConfigured: false,
        tokenFailure: firebaseNotConfiguredDetail,
        permission: true,
        messagesChannel: 'On',
        phase: PushRegistrationPhase.firebaseUnavailable,
        pusherChecked: true,
        pusherExists: true,
        pusherUrlMatches: true,
        pusherNonceMatches: true,
      ),
      time: _time,
    );
    expect(stages[0].problem, isTrue);
    expect(stages[0].detail, contains('google-services.json'));
    expect(stages[2].problem, isTrue);
    expect(stages[2].detail, contains('step 1'));
    expect(stageProblems(stages).first, 'App build (step 1)');
    // Without a token, whether the account's pusher is this phone's is open.
    expect(stages[4].state, PushStageState.unknown);
  });

  test('a refused gateway registration and an unreachable gateway are '
      'named with their reason', () {
    final refused = pushDeliveryStages(
      _healthy(
        snapshot: _snapshot(
          setup: {
            PushSetupStep.gateway: PushSetupRecord(
              at: _at,
              ok: false,
              detail: 'http_503',
            ),
          },
        ),
        probe: const PushGatewayProbe(PushGatewayReachability.unreachable),
      ),
      time: _time,
    );
    expect(refused[3].problem, isTrue);
    expect(refused[3].detail, contains('HTTP 503'));
    expect(refused[3].detail, contains('cannot reach the gateway'));
    final notAuthorized = pushDeliveryStages(
      PushStageFacts(
        firebaseConfigured: true,
        tokenPresent: true,
        phase: PushRegistrationPhase.notAuthorized,
        snapshot: _snapshot(),
      ),
      time: _time,
    );
    expect(notAuthorized[3].problem, isTrue);
    expect(notAuthorized[3].detail, contains('did not authorize'));
  });

  test('a missing or foreign pusher is a problem with a fix', () {
    PushStage pusher(PushStageFacts facts) =>
        pushDeliveryStages(facts, time: _time)[4];
    expect(
      pusher(
        const PushStageFacts(
          tokenPresent: true,
          pusherChecked: true,
          pusherTokenKnown: true,
        ),
      ).detail,
      contains('Re-register'),
    );
    final foreign = pusher(
      const PushStageFacts(
        tokenPresent: true,
        pusherChecked: true,
        pusherExists: true,
        pusherTokenKnown: true,
        pusherUrlMatches: true,
        pusherNonceMatches: true,
      ),
    );
    expect(foreign.problem, isTrue);
    expect(foreign.detail, contains('another token'));
    final key = pusher(
      const PushStageFacts(
        tokenPresent: true,
        pusherChecked: true,
        pusherExists: true,
        pusherTokenKnown: true,
        pusherTokenMatches: true,
        pusherUrlMatches: true,
      ),
    );
    expect(key.detail, contains('gateway key'));
    expect(
      pusher(const PushStageFacts(pusherCheckFailed: true)).state,
      PushStageState.unknown,
    );
  });

  test('no push received yet is waiting; a failed last message is a '
      'problem; a silenced one is not', () {
    final waiting = pushDeliveryStages(
      _healthy(snapshot: _snapshot()),
      time: _time,
    );
    expect(waiting[5].state, PushStageState.waiting);
    expect(waiting[5].detail, contains('homeserver or Google'));
    expect(waiting[6].state, PushStageState.waiting);

    PushStage last(PushOutcome outcome) => pushDeliveryStages(
      _healthy(
        snapshot: _snapshot(
          receivedAt: _at,
          recent: [
            PushDiagnosticsEntry(
              at: _at,
              kind: PushKind.message,
              outcome: outcome,
              errorType: outcome == PushOutcome.timeout
                  ? 'TimeoutException'
                  : null,
            ),
          ],
        ),
      ),
      time: _time,
    )[6];
    expect(last(PushOutcome.timeout).problem, isTrue);
    expect(last(PushOutcome.timeout).detail, contains('TimeoutException'));
    expect(last(PushOutcome.pushRules).problem, isFalse);
    expect(last(PushOutcome.pushRules).detail, contains('on purpose'));
  });

  test('notifications blocked by Android or a silent channel fail step 2', () {
    final blocked = pushDeliveryStages(
      const PushStageFacts(permission: false),
      time: _time,
    );
    expect(blocked[1].problem, isTrue);
    final silent = pushDeliveryStages(
      const PushStageFacts(permission: true, messagesChannel: 'Silent'),
      time: _time,
    );
    expect(silent[1].detail, contains('silent'));
    for (final state in PushStageState.values) {
      expect(pushStageStateLabel(state), isNotEmpty);
    }
  });
}
