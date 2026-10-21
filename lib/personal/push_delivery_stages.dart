// SPDX-License-Identifier: AGPL-3.0-or-later

/// The path a message notification takes to this phone, as ordered steps the
/// diagnostics page can show one by one: where it stops is where it fails.
///
/// 1. the app build can use Firebase Cloud Messaging at all,
/// 2. Android lets ChatLoom show notifications,
/// 3. Firebase gave this phone a push token,
/// 4. the private gateway registered that token for this account,
/// 5. the Matrix account has a pusher pointing at the gateway with it,
/// 6. pushes actually arrive on this phone,
/// 7. the newest message push became a notification.
///
/// Everything is derived from yes/no checks, fixed failure words, outcomes
/// and times. Nothing identifies the account, a chat or a message.
library;

import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';

enum PushStageState { ok, problem, waiting, unknown }

class PushStage {
  final String title;
  final PushStageState state;
  final String detail;
  const PushStage(this.title, this.state, this.detail);

  bool get problem => state == PushStageState.problem;
}

/// The facts one look at the diagnostics page collects.
class PushStageFacts {
  /// FCM is used (Android, no UnifiedPush distributor in charge).
  final bool firebase;

  /// The default private gateway with automatic enrollment is used.
  final bool automatic;
  final bool? firebaseConfigured;
  final String? tokenFailure;
  final bool tokenPresent;
  final bool? permission;
  final String messagesChannel;
  final PushRegistrationPhase phase;
  final PushGatewayProbe? probe;
  final bool pusherChecked;
  final bool pusherCheckFailed;
  final bool pusherExists;
  final bool pusherTokenKnown;
  final bool pusherTokenMatches;
  final bool pusherUrlMatches;
  final bool pusherNonceMatches;
  final PushDiagnosticsSnapshot snapshot;

  const PushStageFacts({
    this.firebase = true,
    this.automatic = true,
    this.firebaseConfigured,
    this.tokenFailure,
    this.tokenPresent = false,
    this.permission,
    this.messagesChannel = 'Unknown',
    this.phase = PushRegistrationPhase.unknown,
    this.probe,
    this.pusherChecked = false,
    this.pusherCheckFailed = false,
    this.pusherExists = false,
    this.pusherTokenKnown = false,
    this.pusherTokenMatches = false,
    this.pusherUrlMatches = false,
    this.pusherNonceMatches = false,
    this.snapshot = PushDiagnosticsSnapshot.empty,
  });
}

const _silencedOnPurpose = {
  PushOutcome.seen,
  PushOutcome.own,
  PushOutcome.pushRules,
  PushOutcome.activeRoom,
  PushOutcome.muted,
  PushOutcome.mentionsOnly,
  PushOutcome.ignored,
  PushOutcome.control,
  PushOutcome.cleared,
};

const _failed = {
  PushOutcome.noClient,
  PushOutcome.storageUnavailable,
  PushOutcome.fetchFailed,
  PushOutcome.timeout,
  PushOutcome.error,
};

/// The seven steps for [facts]; [time] formats a moment for the reader.
List<PushStage> pushDeliveryStages(
  PushStageFacts facts, {
  required String Function(DateTime at) time,
}) {
  final setup = facts.snapshot.setup;
  final noFirebase =
      facts.firebaseConfigured == false ||
      facts.phase == PushRegistrationPhase.firebaseUnavailable;

  final build = !facts.firebase
      ? const PushStage(
          'App build',
          PushStageState.ok,
          'Uses UnifiedPush instead of Firebase.',
        )
      : noFirebase
      ? const PushStage(
          'App build',
          PushStageState.problem,
          'This build has no Firebase configuration (google-services.json), '
              'so it can never get a push token. Install an update built '
              'with it; your data stays.',
        )
      : facts.firebaseConfigured == true
      ? const PushStage(
          'App build',
          PushStageState.ok,
          'Firebase push is built in.',
        )
      : const PushStage(
          'App build',
          PushStageState.unknown,
          'Checked when the token is requested.',
        );

  final channelOff =
      facts.messagesChannel == 'Off' || facts.messagesChannel == 'Silent';
  final allowed = facts.permission == false
      ? const PushStage(
          'Notifications allowed',
          PushStageState.problem,
          'Android blocks ChatLoom notifications. Tap to allow them.',
        )
      : channelOff
      ? PushStage(
          'Notifications allowed',
          PushStageState.problem,
          'The Messages channel is ${facts.messagesChannel.toLowerCase()}. '
              'Tap to change it.',
        )
      : facts.permission == true
      ? PushStage(
          'Notifications allowed',
          PushStageState.ok,
          'Allowed. Messages channel: ${facts.messagesChannel}.',
        )
      : const PushStage(
          'Notifications allowed',
          PushStageState.unknown,
          'Not checked yet.',
        );

  final tokenRecord = setup[PushSetupStep.token];
  final PushStage token;
  if (!facts.firebase) {
    token = const PushStage(
      'Push token',
      PushStageState.ok,
      'UnifiedPush provides the endpoint.',
    );
  } else if (facts.tokenPresent) {
    token = PushStage(
      'Push token',
      PushStageState.ok,
      tokenRecord != null && tokenRecord.ok
          ? 'Received ${time(tokenRecord.at)}.'
          : 'This phone has a Firebase token.',
    );
  } else if (noFirebase) {
    token = const PushStage(
      'Push token',
      PushStageState.problem,
      'Blocked by the app build (step 1).',
    );
  } else if (facts.tokenFailure != null ||
      facts.phase == PushRegistrationPhase.tokenUnavailable) {
    token = PushStage(
      'Push token',
      PushStageState.problem,
      '${pushSetupDetailLabel(facts.tokenFailure ?? 'token_unavailable')}. '
          'Check Google Play services and the connection, then re-register.',
    );
  } else {
    token = const PushStage(
      'Push token',
      PushStageState.waiting,
      'Not requested yet in this session.',
    );
  }

  final gatewayRecord = setup[PushSetupStep.gateway];
  final probe = facts.probe;
  final reach = probe == null
      ? ''
      : switch (probe.reachability) {
          PushGatewayReachability.online => ' The gateway is online.',
          PushGatewayReachability.unexpected =>
            ' The gateway address answered HTTP ${probe.status}, not like a '
                'push gateway.',
          PushGatewayReachability.unreachable =>
            ' This phone cannot reach the gateway address now.',
        };
  final PushStage gateway;
  if (!facts.firebase || !facts.automatic) {
    gateway = const PushStage(
      'Gateway registration',
      PushStageState.unknown,
      'A manually configured gateway keeps its own registration.',
    );
  } else if (facts.phase == PushRegistrationPhase.notAuthorized) {
    gateway = PushStage(
      'Gateway registration',
      PushStageState.problem,
      'The gateway did not authorize this account.$reach',
    );
  } else if (gatewayRecord != null && !gatewayRecord.ok) {
    gateway = PushStage(
      'Gateway registration',
      PushStageState.problem,
      '${pushSetupDetailLabel(gatewayRecord.detail)} '
          '(${time(gatewayRecord.at)}).$reach',
    );
  } else if (gatewayRecord != null && gatewayRecord.ok) {
    gateway = PushStage(
      'Gateway registration',
      probe?.reachability == PushGatewayReachability.online || probe == null
          ? PushStageState.ok
          : PushStageState.problem,
      'Registered ${time(gatewayRecord.at)}.$reach',
    );
  } else if (facts.phase == PushRegistrationPhase.registering ||
      facts.phase == PushRegistrationPhase.retrying) {
    gateway = PushStage(
      'Gateway registration',
      PushStageState.waiting,
      'In progress.$reach',
    );
  } else {
    gateway = PushStage(
      'Gateway registration',
      probe?.reachability == PushGatewayReachability.online || probe == null
          ? PushStageState.waiting
          : PushStageState.problem,
      'Not registered from this phone yet.$reach',
    );
  }

  final pusherRecord = setup[PushSetupStep.pusher];
  final PushStage pusher;
  if (facts.pusherCheckFailed) {
    pusher = const PushStage(
      'Pusher on your account',
      PushStageState.unknown,
      'Could not read the account’s pushers. Check the connection.',
    );
  } else if (!facts.pusherChecked) {
    pusher = const PushStage(
      'Pusher on your account',
      PushStageState.unknown,
      'Checking…',
    );
  } else if (!facts.pusherExists) {
    pusher = PushStage(
      'Pusher on your account',
      PushStageState.problem,
      pusherRecord != null && !pusherRecord.ok
          ? 'Missing. Last attempt: ${pushSetupDetailLabel(pusherRecord.detail)} '
                '(${time(pusherRecord.at)}).'
          : 'Missing: the homeserver has nowhere to send pushes. '
                'Re-register this device.',
    );
  } else if (facts.pusherTokenKnown && !facts.pusherTokenMatches) {
    pusher = const PushStage(
      'Pusher on your account',
      PushStageState.problem,
      'It points to another token (an older install). Re-register.',
    );
  } else if (!facts.pusherUrlMatches) {
    pusher = const PushStage(
      'Pusher on your account',
      PushStageState.problem,
      'It points to another gateway address. Re-register.',
    );
  } else if (!facts.pusherNonceMatches) {
    pusher = const PushStage(
      'Pusher on your account',
      PushStageState.problem,
      'Its gateway key differs from this phone’s, so the gateway drops '
          'the pushes. Re-register.',
    );
  } else {
    pusher = PushStage(
      'Pusher on your account',
      facts.pusherTokenKnown ? PushStageState.ok : PushStageState.unknown,
      facts.pusherTokenKnown
          ? 'Present and points to this phone.'
          : 'Present; whether it carries this phone’s token is unknown '
                'without a token.',
    );
  }

  final snapshot = facts.snapshot;
  final received = snapshot.lastReceivedAt;
  final kind = snapshot.lastKind;
  final arriving = received != null
      ? PushStage(
          'Pushes reaching this phone',
          PushStageState.ok,
          'Last push ${time(received)}'
              '${kind == null ? '' : ' (${pushKindLabel(kind).toLowerCase()})'}.',
        )
      : const PushStage(
          'Pushes reaching this phone',
          PushStageState.waiting,
          'None recorded yet. If the steps above are OK and a message from '
              'someone else does not show up here, the homeserver or Google '
              'is not delivering to this phone.',
        );

  final lastMessage = snapshot.recent
      .where(
        (entry) =>
            entry.kind == PushKind.message || entry.kind == PushKind.countOnly,
      )
      .where((entry) => entry.outcome != PushOutcome.cleared)
      .firstOrNull;
  final PushStage shown;
  if (lastMessage == null) {
    shown = const PushStage(
      'Last message notification',
      PushStageState.waiting,
      'No message push handled yet.',
    );
  } else {
    final label = pushOutcomeLabel(lastMessage.outcome);
    final error = lastMessage.errorType == null
        ? ''
        : ' (${lastMessage.errorType})';
    shown = PushStage(
      'Last message notification',
      _failed.contains(lastMessage.outcome)
          ? PushStageState.problem
          : PushStageState.ok,
      '$label$error, ${time(lastMessage.at)}.'
          '${_silencedOnPurpose.contains(lastMessage.outcome) ? ' Not shown on purpose.' : ''}',
    );
  }

  return [build, allowed, token, gateway, pusher, arriving, shown];
}

/// "Title (step N)" for every failing step, in order.
List<String> stageProblems(List<PushStage> stages) => [
  for (var i = 0; i < stages.length; i++)
    if (stages[i].problem) '${stages[i].title} (step ${i + 1})',
];

String pushStageStateLabel(PushStageState state) => switch (state) {
  PushStageState.ok => 'OK',
  PushStageState.problem => 'Problem',
  PushStageState.waiting => 'Waiting',
  PushStageState.unknown => 'Unknown',
};
