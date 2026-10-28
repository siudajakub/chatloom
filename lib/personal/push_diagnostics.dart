// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a single push wake turned into. Names are stable: they are stored and
/// shown on the diagnostics page.
enum PushOutcome {
  received,
  shown,
  shownFallback,
  seen,
  own,
  pushRules,
  activeRoom,
  muted,
  mentionsOnly,
  ignored,
  journal,
  control,
  cleared,
  reminderShown,
  reminderNone,
  noClient,
  storageUnavailable,
  fetchFailed,
  timeout,
  error,
}

/// The kind of push wake, derived only from the content-free FCM data map.
/// [resync]: FCM dropped queued pushes (`onDeletedMessages`), forwarded by
/// the app itself.
enum PushKind { message, countOnly, reminder, test, resync }

/// The steps that must all succeed before the homeserver can reach this
/// phone, in order: an FCM token, the private gateway's registration of that
/// token, and the Matrix pusher on the account that points at the gateway.
enum PushSetupStep { token, gateway, pusher }

/// The latest attempt of one [PushSetupStep]. [detail] is a fixed word such
/// as `forbidden`, `network` or `http_503`, never a value or message.
class PushSetupRecord {
  final DateTime at;
  final bool ok;
  final String? detail;
  const PushSetupRecord({required this.at, required this.ok, this.detail});

  Map<String, Object?> toJson() => {
    'at': at.toUtc().millisecondsSinceEpoch,
    'ok': ok,
    if (detail != null) 'detail': detail,
  };

  static PushSetupRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final ok = json['ok'];
    if (at is! int || ok is! bool) return null;
    final detail = json['detail'];
    return PushSetupRecord(
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      ok: ok,
      detail: detail is String && PushDiagnostics.validDetail(detail)
          ? detail
          : null,
    );
  }
}

/// English explanation of a setup [detail] for the diagnostics page.
String pushSetupDetailLabel(String? detail) {
  if (detail == null) return 'Failed';
  final status = RegExp(r'^http_(\d{3})$').firstMatch(detail)?.group(1);
  if (status != null) return 'The gateway answered HTTP $status';
  if (detail.startsWith('matrix_')) {
    return 'The homeserver refused (${detail.substring(7).toUpperCase()})';
  }
  return switch (detail) {
    'firebase_not_configured' =>
      'This build has no Firebase configuration (google-services.json)',
    'token_failed' => 'Google Play services did not issue a token',
    'token_unavailable' => 'No token yet',
    'forbidden' => 'The gateway did not authorize this account',
    'gateway_unavailable' => 'The gateway is temporarily unavailable',
    'bad_response' => 'The gateway sent an unexpected reply',
    'network' => 'No connection',
    'timeout' => 'Timed out',
    'posted' => 'Pusher saved on the account',
    'already_set' => 'Pusher was already up to date',
    'registered' => 'Registered',
    'platform_error' => 'The phone reported an error',
    _ => 'Failed',
  };
}

String pushOutcomeLabel(PushOutcome outcome) => switch (outcome) {
  PushOutcome.received => 'Received',
  PushOutcome.shown => 'Notification shown',
  PushOutcome.shownFallback =>
    'Generic notification shown (message unavailable)',
  PushOutcome.seen => 'Already read on another device',
  PushOutcome.own => 'Own message, no alert',
  PushOutcome.pushRules => 'Silenced by account notification rules',
  PushOutcome.activeRoom => 'Chat was open on screen',
  PushOutcome.muted => 'Chat is muted in ChatLoom',
  PushOutcome.mentionsOnly => 'Mentions only, not mentioned',
  PushOutcome.ignored => 'Chat is ignored',
  PushOutcome.journal => 'Private journal update',
  PushOutcome.control => 'Internal bridge control event',
  PushOutcome.cleared => 'Read-state update',
  PushOutcome.reminderShown => 'Reminder shown',
  PushOutcome.reminderNone => 'No due reminder',
  PushOutcome.noClient => 'No signed-in account matched',
  PushOutcome.storageUnavailable => 'Private storage unavailable',
  PushOutcome.fetchFailed => 'Message could not be loaded',
  PushOutcome.timeout => 'Timed out',
  PushOutcome.error => 'Failed',
};

String pushKindLabel(PushKind kind) => switch (kind) {
  PushKind.message => 'Message',
  PushKind.countOnly => 'Unread count',
  PushKind.reminder => 'Reminder',
  PushKind.test => 'Test',
  PushKind.resync => 'Missed pushes',
};

/// `personal_wake` value `FcmPushService.onDeletedMessages` sends.
const resyncWake = 'resync';

/// Classifies an FCM data map without reading any value except the fixed
/// wake marker and whether an event id is present.
///
/// [test] is set only in-process by the diagnostics page; remote data can
/// never mark a push as a test (which would bypass the "already read" and
/// "chat open" checks).
PushKind pushKindOf(Map<String, Object?> data, {bool test = false}) {
  if (data['personal_wake'] == 'reminder') return PushKind.reminder;
  if (data['personal_wake'] == resyncWake) return PushKind.resync;
  if (test) return PushKind.test;
  final event = data['event_id'];
  return event is String && event.isNotEmpty
      ? PushKind.message
      : PushKind.countOnly;
}

/// How long the process the push started took to get ready (BP-10): from
/// `main` to `BackgroundPush.ready` on the detached (background-fetch)
/// start. The next push recorded within [claimWindow] is marked cold with
/// this number; a push handled by an app that was already running is warm.
abstract final class PushStartupTiming {
  static final Stopwatch _sinceMain = Stopwatch();
  static int? _coldMs;
  static DateTime? _readyAt;

  /// A cold start's push is recorded within this time after ready.
  static const claimWindow = Duration(minutes: 1);

  /// First thing in `main`.
  static void mainStarted() => _sinceMain
    ..reset()
    ..start();

  /// The detached start is ready to handle the push that woke it.
  static void detachedReady({DateTime? now}) {
    if (!_sinceMain.isRunning) return;
    _coldMs = _sinceMain.elapsedMilliseconds;
    _readyAt = now ?? DateTime.now();
  }

  /// The pending cold start, once; null for a warm push.
  static int? takeCold({DateTime? now}) {
    final ms = _coldMs;
    final readyAt = _readyAt;
    _coldMs = null;
    _readyAt = null;
    if (ms == null || readyAt == null) return null;
    final age = (now ?? DateTime.now()).difference(readyAt);
    return age.isNegative || age > claimWindow ? null : ms;
  }

  @visibleForTesting
  static void debugReset() {
    _sinceMain
      ..stop()
      ..reset();
    _coldMs = null;
    _readyAt = null;
  }
}

class PushDiagnosticsEntry {
  final DateTime at;
  final PushKind kind;
  final PushOutcome outcome;
  final String? errorType;
  final int? elapsedMs;

  /// Milliseconds from process start to ready when this push started the
  /// app (cold); null when the app was already running (warm).
  final int? startupMs;

  const PushDiagnosticsEntry({
    required this.at,
    required this.kind,
    required this.outcome,
    this.errorType,
    this.elapsedMs,
    this.startupMs,
  });

  bool get cold => startupMs != null;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().millisecondsSinceEpoch,
    'kind': kind.name,
    'outcome': outcome.name,
    if (errorType != null) 'error': errorType,
    if (elapsedMs != null) 'ms': elapsedMs,
    if (startupMs != null) 'coldMs': startupMs,
  };

  static PushDiagnosticsEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final kind = PushKind.values.where((k) => k.name == json['kind']);
    final outcome = PushOutcome.values.where((o) => o.name == json['outcome']);
    if (at is! int || kind.isEmpty || outcome.isEmpty) return null;
    final error = json['error'];
    final ms = json['ms'];
    final coldMs = json['coldMs'];
    return PushDiagnosticsEntry(
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      kind: kind.first,
      outcome: outcome.first,
      errorType: error is String ? error : null,
      elapsedMs: ms is int ? ms : null,
      startupMs: coldMs is int && coldMs >= 0 ? coldMs : null,
    );
  }
}

class PushDiagnosticsSnapshot {
  final DateTime? lastReceivedAt;
  final PushKind? lastKind;
  final PushDiagnosticsEntry? last;
  final Map<String, int> counters;
  final List<PushDiagnosticsEntry> recent;
  final Map<PushSetupStep, PushSetupRecord> setup;

  const PushDiagnosticsSnapshot({
    this.lastReceivedAt,
    this.lastKind,
    this.last,
    this.counters = const {},
    this.recent = const [],
    this.setup = const {},
  });

  static const empty = PushDiagnosticsSnapshot();

  int count(PushOutcome outcome) => counters[outcome.name] ?? 0;
  int received(PushKind kind) => counters['received.${kind.name}'] ?? 0;

  /// Recent pushes that started the app.
  Iterable<PushDiagnosticsEntry> get coldStarts =>
      recent.where((entry) => entry.cold);

  /// Median start-up time of the recent cold starts, or null.
  int? get medianColdStartupMs {
    final values = [for (final entry in coldStarts) entry.startupMs!]..sort();
    if (values.isEmpty) return null;
    final middle = values.length ~/ 2;
    return values.length.isOdd
        ? values[middle]
        : ((values[middle - 1] + values[middle]) / 2).round();
  }
}

/// Failure-tolerant, content-free record of push handling on this device.
///
/// Stores only timestamps, enum names, an exception runtime type and elapsed
/// milliseconds. Never account, room or event identifiers, names or text.
/// Every method swallows its own errors: diagnostics must never affect
/// whether a notification is shown.
abstract final class PushDiagnostics {
  static const storageKey = 'personal_push_diag_v1';
  static const maxRecent = 20;
  static Future<void> _queue = Future<void>.value();

  /// Exception class name only (never its message), bounded and sanitized.
  static String errorType(Object error) {
    final name = error.runtimeType.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9_<>]'),
      '',
    );
    return name.isEmpty
        ? 'Error'
        : name.length > 48
        ? name.substring(0, 48)
        : name;
  }

  static Future<void> received(
    PushKind kind, {
    Future<SharedPreferences> Function()? store,
    DateTime? now,
  }) => _update(store, (state) {
    final at = (now ?? DateTime.now()).toUtc();
    state['lastReceivedAt'] = at.millisecondsSinceEpoch;
    state['lastKind'] = kind.name;
    _bump(state, 'received.${kind.name}');
    _bump(state, PushOutcome.received.name);
  });

  static Future<void> record(
    PushKind kind,
    PushOutcome outcome, {
    Object? error,
    Duration? elapsed,
    Future<SharedPreferences> Function()? store,
    DateTime? now,
  }) {
    final cold = PushStartupTiming.takeCold(now: now);
    return _update(store, (state) {
      final entry = PushDiagnosticsEntry(
        at: (now ?? DateTime.now()).toUtc(),
        kind: kind,
        outcome: outcome,
        errorType: error == null ? null : errorType(error),
        elapsedMs: elapsed?.inMilliseconds,
        startupMs: cold,
      );
      _bump(state, outcome.name);
      if (cold != null) _bump(state, 'start.cold');
      state['last'] = entry.toJson();
      final recent = [
        entry.toJson(),
        ...(state['recent'] is List ? state['recent'] as List : const []),
      ];
      state['recent'] = recent.take(maxRecent).toList();
    });
  }

  /// Remembers the outcome of the latest attempt of a setup [step]. Survives
  /// restarts so the page can tell which step failed in an earlier process.
  static Future<void> setup(
    PushSetupStep step, {
    required bool ok,
    String? detail,
    Future<SharedPreferences> Function()? store,
    DateTime? now,
  }) => _update(store, (state) {
    final steps = state['setup'] is Map
        ? Map<String, Object?>.from(state['setup'] as Map)
        : <String, Object?>{};
    steps[step.name] = PushSetupRecord(
      at: (now ?? DateTime.now()).toUtc(),
      ok: ok,
      detail: detail != null && validDetail(detail) ? detail : null,
    ).toJson();
    state['setup'] = steps;
  });

  /// Setup details are fixed lowercase words; anything else is dropped.
  static bool validDetail(String detail) =>
      RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(detail);

  static Future<PushDiagnosticsSnapshot> read({
    Future<SharedPreferences> Function()? store,
  }) async {
    // Writes queued by this isolate land first (they never throw).
    await _queue;
    try {
      final prefs = await (store ?? SharedPreferences.getInstance)().timeout(
        const Duration(seconds: 2),
      );
      await prefs.reload().timeout(const Duration(seconds: 2));
      return parse(prefs.getString(storageKey));
    } catch (_) {
      return PushDiagnosticsSnapshot.empty;
    }
  }

  static PushDiagnosticsSnapshot parse(String? raw) {
    if (raw == null) return PushDiagnosticsSnapshot.empty;
    try {
      final state = jsonDecode(raw);
      if (state is! Map) return PushDiagnosticsSnapshot.empty;
      final received = state['lastReceivedAt'];
      final kind = PushKind.values.where((k) => k.name == state['lastKind']);
      final counters = <String, int>{};
      final rawCounters = state['counters'];
      if (rawCounters is Map) {
        for (final entry in rawCounters.entries) {
          if (entry.key is String && entry.value is int) {
            counters[entry.key as String] = entry.value as int;
          }
        }
      }
      final recent = state['recent'] is List
          ? (state['recent'] as List)
                .map(PushDiagnosticsEntry.fromJson)
                .whereType<PushDiagnosticsEntry>()
                .toList()
          : <PushDiagnosticsEntry>[];
      final setup = <PushSetupStep, PushSetupRecord>{};
      final rawSetup = state['setup'];
      if (rawSetup is Map) {
        for (final step in PushSetupStep.values) {
          final record = PushSetupRecord.fromJson(rawSetup[step.name]);
          if (record != null) setup[step] = record;
        }
      }
      return PushDiagnosticsSnapshot(
        setup: setup,
        lastReceivedAt: received is int
            ? DateTime.fromMillisecondsSinceEpoch(received, isUtc: true)
            : null,
        lastKind: kind.isEmpty ? null : kind.first,
        last: PushDiagnosticsEntry.fromJson(state['last']),
        counters: counters,
        recent: recent,
      );
    } catch (_) {
      return PushDiagnosticsSnapshot.empty;
    }
  }

  /// Clears counters and outcomes; the setup steps describe the current
  /// registration, not history, so they stay.
  static Future<void> reset({Future<SharedPreferences> Function()? store}) =>
      _update(store, (state) => state.removeWhere((key, _) => key != 'setup'));

  /// Forgets everything, including the setup steps (tests, sign-out).
  static Future<void> clear({Future<SharedPreferences> Function()? store}) =>
      _update(store, (state) => state.clear());

  static void _bump(Map<String, Object?> state, String name) {
    final counters = state['counters'] is Map
        ? Map<String, Object?>.from(state['counters'] as Map)
        : <String, Object?>{};
    final value = counters[name];
    counters[name] = (value is int ? value : 0) + 1;
    state['counters'] = counters;
  }

  /// Serialized read-modify-write. Reloads first because the background push
  /// isolate and the UI isolate keep separate SharedPreferences caches.
  static Future<void> _update(
    Future<SharedPreferences> Function()? store,
    void Function(Map<String, Object?> state) change,
  ) {
    final next = _queue.then((_) async {
      try {
        final prefs = await (store ?? SharedPreferences.getInstance)().timeout(
          const Duration(seconds: 2),
        );
        await prefs.reload().timeout(const Duration(seconds: 2));
        Map<String, Object?> state;
        try {
          final decoded = jsonDecode(prefs.getString(storageKey) ?? '{}');
          state = decoded is Map
              ? Map<String, Object?>.from(decoded)
              : <String, Object?>{};
        } catch (_) {
          state = <String, Object?>{};
        }
        change(state);
        await prefs
            .setString(storageKey, jsonEncode(state))
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Diagnostics are best effort and never block or fail push handling.
      }
    });
    _queue = next;
    return next;
  }

  /// Plain-text report for "Copy diagnostics". Contains no identifiers or
  /// message content: only yes/no checks, enum outcomes, counts and times.
  static String describe(
    PushDiagnosticsSnapshot snapshot, {
    Map<String, String> checks = const {},
    DateTime? now,
  }) {
    final buffer = StringBuffer('ChatLoom notification diagnostics\n');
    buffer.writeln(
      'Generated: ${(now ?? DateTime.now()).toUtc().toIso8601String()}',
    );
    for (final check in checks.entries) {
      buffer.writeln('${check.key}: ${check.value}');
    }
    for (final step in PushSetupStep.values) {
      final record = snapshot.setup[step];
      if (record == null) {
        buffer.writeln('Setup ${step.name}: not attempted');
        continue;
      }
      final detail = record.detail == null ? '' : ' (${record.detail})';
      buffer.writeln(
        'Setup ${step.name}: ${record.ok ? 'ok' : 'failed'}$detail'
        ' at ${record.at.toIso8601String()}',
      );
    }
    buffer.writeln(
      'Last push received: ${snapshot.lastReceivedAt?.toIso8601String() ?? 'never'}',
    );
    if (snapshot.lastKind != null) {
      buffer.writeln('Last push kind: ${snapshot.lastKind!.name}');
    }
    final last = snapshot.last;
    if (last != null) {
      buffer.writeln(
        'Last outcome: ${last.outcome.name}'
        '${last.errorType == null ? '' : ' (${last.errorType})'}'
        '${last.elapsedMs == null ? '' : ' in ${last.elapsedMs} ms'}',
      );
    }
    if (snapshot.counters.isNotEmpty) {
      buffer.writeln('Counters:');
      final keys = snapshot.counters.keys.toList()..sort();
      for (final key in keys) {
        buffer.writeln('  $key: ${snapshot.counters[key]}');
      }
    }
    if (snapshot.recent.isNotEmpty) {
      buffer.writeln('Recent:');
      for (final entry in snapshot.recent) {
        buffer.writeln(
          '  ${entry.at.toIso8601String()} ${entry.kind.name} '
          '${entry.outcome.name}'
          '${entry.errorType == null ? '' : ' ${entry.errorType}'}'
          '${entry.elapsedMs == null ? '' : ' ${entry.elapsedMs}ms'}'
          '${entry.startupMs == null ? '' : ' cold ${entry.startupMs}ms'}',
        );
      }
      final median = snapshot.medianColdStartupMs;
      buffer.writeln(
        'Cold starts: ${snapshot.coldStarts.length} of '
        '${snapshot.recent.length}'
        '${median == null ? '' : ', median $median ms'}',
      );
    }
    return buffer.toString();
  }
}
