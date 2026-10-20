// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

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
enum PushKind { message, countOnly, reminder, test }

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
};

/// Classifies an FCM data map without reading any value except the fixed
/// wake marker and whether an event id is present.
///
/// [test] is set only in-process by the diagnostics page; remote data can
/// never mark a push as a test (which would bypass the "already read" and
/// "chat open" checks).
PushKind pushKindOf(Map<String, Object?> data, {bool test = false}) {
  if (data['personal_wake'] == 'reminder') return PushKind.reminder;
  if (test) return PushKind.test;
  final event = data['event_id'];
  return event is String && event.isNotEmpty
      ? PushKind.message
      : PushKind.countOnly;
}

class PushDiagnosticsEntry {
  final DateTime at;
  final PushKind kind;
  final PushOutcome outcome;
  final String? errorType;
  final int? elapsedMs;

  const PushDiagnosticsEntry({
    required this.at,
    required this.kind,
    required this.outcome,
    this.errorType,
    this.elapsedMs,
  });

  Map<String, Object?> toJson() => {
    'at': at.toUtc().millisecondsSinceEpoch,
    'kind': kind.name,
    'outcome': outcome.name,
    if (errorType != null) 'error': errorType,
    if (elapsedMs != null) 'ms': elapsedMs,
  };

  static PushDiagnosticsEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final kind = PushKind.values.where((k) => k.name == json['kind']);
    final outcome = PushOutcome.values.where((o) => o.name == json['outcome']);
    if (at is! int || kind.isEmpty || outcome.isEmpty) return null;
    final error = json['error'];
    final ms = json['ms'];
    return PushDiagnosticsEntry(
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      kind: kind.first,
      outcome: outcome.first,
      errorType: error is String ? error : null,
      elapsedMs: ms is int ? ms : null,
    );
  }
}

class PushDiagnosticsSnapshot {
  final DateTime? lastReceivedAt;
  final PushKind? lastKind;
  final PushDiagnosticsEntry? last;
  final Map<String, int> counters;
  final List<PushDiagnosticsEntry> recent;

  const PushDiagnosticsSnapshot({
    this.lastReceivedAt,
    this.lastKind,
    this.last,
    this.counters = const {},
    this.recent = const [],
  });

  static const empty = PushDiagnosticsSnapshot();

  int count(PushOutcome outcome) => counters[outcome.name] ?? 0;
  int received(PushKind kind) => counters['received.${kind.name}'] ?? 0;
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
  }) => _update(store, (state) {
    final entry = PushDiagnosticsEntry(
      at: (now ?? DateTime.now()).toUtc(),
      kind: kind,
      outcome: outcome,
      errorType: error == null ? null : errorType(error),
      elapsedMs: elapsed?.inMilliseconds,
    );
    _bump(state, outcome.name);
    state['last'] = entry.toJson();
    final recent = [
      entry.toJson(),
      ...(state['recent'] is List ? state['recent'] as List : const []),
    ];
    state['recent'] = recent.take(maxRecent).toList();
  });

  static Future<PushDiagnosticsSnapshot> read({
    Future<SharedPreferences> Function()? store,
  }) async {
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
      return PushDiagnosticsSnapshot(
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

  static Future<void> reset({Future<SharedPreferences> Function()? store}) =>
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
          '${entry.elapsedMs == null ? '' : ' ${entry.elapsedMs}ms'}',
        );
      }
    }
    return buffer.toString();
  }
}
