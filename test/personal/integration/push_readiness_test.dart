// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import '../../../lib/personal/push_registration.dart';
import '../../../lib/personal/worker_readiness.dart';

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

Future<void> main() async {
  for (final length in [32, 42, 43, 128, 129]) {
    check(
      validGatewayNonce('a' * length) == (length >= 43 && length <= 128),
      'Nonce boundary $length',
    );
  }
  for (final value in [
    null,
    '',
    '${'a' * 43}\n',
    '${'a' * 42}=',
    'a' * 42 + ' ',
    'a' * 42 + '/',
  ]) {
    check(!validGatewayNonce(value), 'Nonce invalid character accepted');
  }
  check(validGatewayNonce('_-' * 32), 'Base64url characters refused');
  final state = PushRegistration();
  check(state.observe('synthetic-first'), 'Initial token missing');
  final oldRevision = state.revision;
  check(
    !state.observe('synthetic-first') && state.revision == oldRevision,
    'Duplicate callback changed generation',
  );
  check(!state.observe(''), 'Empty callback replaced token');
  var accountCurrent = true;
  final prepare = Completer<void>();
  var posts = 0, finishes = 0;
  final stale = registerCurrentPush(
    current: () =>
        state.current(oldRevision, 'synthetic-first', accountCurrent),
    prepare: () => prepare.future,
    post: () async {
      posts++;
    },
    finish: () async {
      finishes++;
    },
  );
  state.observe('synthetic-second');
  prepare.complete();
  check(
    !await stale && posts == 0 && finishes == 0,
    'Rotated token registered after await',
  );
  check(state.rotated, 'Rotation status lost');
  final revision = state.revision;
  final post = Completer<void>();
  final switched = registerCurrentPush(
    current: () => state.current(revision, 'synthetic-second', accountCurrent),
    prepare: () async {},
    post: () {
      posts++;
      return post.future;
    },
    finish: () async {
      finishes++;
    },
  );
  await Future<void>.delayed(Duration.zero);
  accountCurrent = false;
  post.complete();
  check(
    !await switched && finishes == 0,
    'Account switch allowed old follow-up',
  );
  accountCurrent = true;
  check(
    await registerCurrentPush(
      current: () => true,
      prepare: () async {},
      post: () async {
        posts++;
      },
      finish: () async {
        finishes++;
      },
    ),
    'Current registration failed',
  );
  var threw = false;
  final before = posts;
  try {
    await registerCurrentPush(
      current: () => true,
      prepare: () async {
        throw StateError('synthetic failure');
      },
      post: () async {
        posts++;
      },
      finish: () async {
        finishes++;
      },
    );
  } catch (_) {
    threw = true;
  }
  check(threw && posts == before, 'Registration failure became success');
  state.beginUpdate();
  state.observe('synthetic-config-rotation');
  final duringUpdate = state.revision;
  check(
    !await registerCurrentPush(
      current: () =>
          state.current(duringUpdate, 'synthetic-config-rotation', true),
      prepare: () async {},
      post: () async {
        posts++;
      },
      finish: () async {
        finishes++;
      },
    ),
    'Config write allowed registration with old nonce',
  );
  state.endUpdate();
  check(
    !state.current(duringUpdate, 'synthetic-config-rotation', true),
    'Config completion retained stale revision',
  );
  check(
    state.current(state.revision, 'synthetic-config-rotation', true),
    'Config completion did not allow retry',
  );
  final restarted = PushRegistration()..observe('synthetic-second');
  check(
    restarted.phase == PushRegistrationPhase.gatewayRequired,
    'Restart falsely confirmed backend',
  );
  for (final phase in PushRegistrationPhase.values) {
    state.phase = phase;
    check(!state.description.contains('synthetic-'), 'Token leaked to status');
  }
  final at = DateTime.utc(2026, 10, 15);
  final old = WorkerReadiness.fromPayload({'healthy': true}, at);
  check(old.describe(at).contains('unknown'), 'Old heartbeat implied ready');
  final worker = WorkerReadiness.fromPayload({
    'healthy': true,
    'verified': true,
    'transcription': 'blocked_codec_sandbox',
    'reminderPush': 'not_configured',
    'pending': 2,
    'pendingReminderHints': 3,
    'unexpected': 'synthetic secret',
  }, at);
  final description = worker.describe(at);
  check(
    description.contains('blocked') &&
        description.contains('not configured') &&
        description.contains('Pending tasks: 2') &&
        description.contains('hints: 3'),
    'Readiness fields lost',
  );
  check(
    !description.contains('synthetic secret'),
    'Unknown heartbeat field retained',
  );
  check(
    !worker.freshAt(at.subtract(const Duration(seconds: 1))),
    'Future heartbeat accepted',
  );
  check(
    worker.freshAt(at.add(const Duration(seconds: 179))) &&
        !worker.freshAt(at.add(const Duration(minutes: 3))),
    'Heartbeat freshness boundary',
  );
  check(
    worker.describe(at.add(const Duration(minutes: 3))).contains('unknown'),
    'Stale status remained ready',
  );
  final invalid = WorkerReadiness.fromPayload({
    'healthy': 'true',
    'verified': 1,
    'transcription': 'synthetic secret',
    'reminderPush': 'ready',
    'pending': -1,
    'pendingReminderHints': '3',
  }, at);
  check(
    invalid.healthy == null &&
        invalid.verified == null &&
        invalid.transcription == null &&
        invalid.reminderPush == null &&
        invalid.pending == null &&
        invalid.pendingReminderHints == null,
    'Malformed fields accepted',
  );
  print(
    'PASS push/readiness: nonce boundaries, token revision, duplicate/empty callbacks, restart, account switch, failures, allowlist and freshness',
  );
}
