// SPDX-License-Identifier: AGPL-3.0-or-later

/// Conversation reminders as the Reminders page shows them.
///
/// The worker keeps the authoritative reminder jobs (`reminder.create`,
/// `reminder.cancel`, acknowledged by `reminder.result`). Commands are staged
/// in the durable private-sync outbox first, and until the worker answers a
/// new reminder exists only as a pending operation. [ReminderList] merges
/// both, so a reminder appears the moment it is saved ("Saving…") and a
/// deleted one disappears at once, instead of the list staying empty until
/// the worker acknowledges.
///
/// The worker has no update command: rescheduling creates the new reminder
/// first and only then cancels the old one, so a failure leaves a duplicate
/// rather than losing the reminder.
library;

import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart' show PersonalOperation;
import 'package:uuid/uuid.dart';

enum ReminderStatus {
  /// Staged locally, the worker has not acknowledged it yet.
  saving,

  /// Accepted by the worker, fires at its time.
  scheduled,

  /// "Only if no reply": the worker is waiting to read the chat history.
  checking,

  /// Fired.
  done,

  /// "Only if no reply" and a reply arrived first.
  skipped,

  /// The worker refused to save it.
  notSaved,
}

@immutable
class ReminderEntry {
  final String id;

  /// The `ConversationRef` JSON the reminder was created for.
  final Map<String, dynamic> conversation;
  final DateTime? dueAt;
  final bool untilReply;
  final String? anchorEventId;
  final ReminderStatus status;
  final int revision;

  /// Fired although the worker could not read the chat to check for a
  /// reply (`replyCheck: skipped`, worker reminder grace).
  final bool replyCheckSkipped;

  /// A command for this reminder waits in the outbox; the worker refuses a
  /// second one, so editing waits.
  final bool busy;

  const ReminderEntry({
    required this.id,
    required this.conversation,
    required this.dueAt,
    required this.untilReply,
    required this.status,
    this.anchorEventId,
    this.revision = 0,
    this.busy = false,
    this.replyCheckSkipped = false,
  });

  String? get roomId {
    final room = conversation['roomId'];
    return room is String ? room : null;
  }

  bool get upcoming => const {
    ReminderStatus.saving,
    ReminderStatus.scheduled,
    ReminderStatus.checking,
    ReminderStatus.notSaved,
  }.contains(status);

  /// Can be rescheduled or deleted now.
  bool get editable =>
      !busy &&
      (status == ReminderStatus.scheduled || status == ReminderStatus.checking);
}

@immutable
class ReminderList {
  /// Soonest first.
  final List<ReminderEntry> upcoming;

  /// Most recent first, at most [pastLimit] from the last [pastWindow].
  final List<ReminderEntry> past;

  const ReminderList({this.upcoming = const [], this.past = const []});

  static const pastWindow = Duration(days: 14);
  static const pastLimit = 10;

  bool get isEmpty => upcoming.isEmpty && past.isEmpty;

  static ReminderList from({
    required Map<String, Map<String, dynamic>> reminders,
    required Iterable<PersonalOperation> pending,
    required DateTime now,
  }) {
    final busy = <String>{};
    final cancelling = <String>{};
    final creating = <String, PersonalOperation>{};
    for (final op in pending) {
      if (!op.kind.startsWith('reminder.')) continue;
      busy.add(op.entityId);
      if (op.kind == 'reminder.cancel') cancelling.add(op.entityId);
      if (op.kind == 'reminder.create') creating[op.entityId] = op;
    }
    final upcoming = <ReminderEntry>[];
    final past = <ReminderEntry>[];
    void add(ReminderEntry entry) {
      if (entry.upcoming) {
        // A refused reminder whose time has passed is no longer actionable.
        if (entry.status == ReminderStatus.notSaved &&
            (entry.dueAt == null || entry.dueAt!.isBefore(now))) {
          return;
        }
        upcoming.add(entry);
      } else {
        final due = entry.dueAt;
        if (due != null && now.difference(due) <= pastWindow) past.add(entry);
      }
    }

    for (final MapEntry(key: id, value: job) in reminders.entries) {
      // Deleted optimistically: hidden while the cancel waits for the worker.
      if (cancelling.contains(id)) continue;
      final status = _status(job);
      if (status == null) continue;
      add(
        _entry(
          id,
          job,
          status: status,
          busy: busy.contains(id),
          revision: job['revision'] is int ? job['revision'] as int : 0,
        ),
      );
    }
    for (final MapEntry(key: id, value: op) in creating.entries) {
      if (reminders.containsKey(id) || cancelling.contains(id)) continue;
      add(_entry(id, op.payload, status: ReminderStatus.saving, busy: true));
    }
    int soonest(ReminderEntry a, ReminderEntry b) =>
        (a.dueAt ?? DateTime(9999)).compareTo(b.dueAt ?? DateTime(9999));
    upcoming.sort(soonest);
    past.sort((a, b) => soonest(b, a));
    return ReminderList(
      upcoming: List.unmodifiable(upcoming),
      past: List.unmodifiable(past.take(pastLimit)),
    );
  }

  /// Null hides the reminder (cancelled by the user).
  static ReminderStatus? _status(Map<String, dynamic> job) {
    var state = job['state'];
    if (state == 'conflict') {
      // A refused command reports the state the job actually has; without
      // one the create itself was refused.
      state = job['actualState'];
      if (state == null) return ReminderStatus.notSaved;
    }
    return switch (state) {
      'queued' => ReminderStatus.scheduled,
      'waitingKeys' || 'waitingSync' => ReminderStatus.checking,
      'done' => ReminderStatus.done,
      'cancelled' =>
        job['errorCode'] == 'replied' ? ReminderStatus.skipped : null,
      _ => ReminderStatus.saving,
    };
  }

  static ReminderEntry _entry(
    String id,
    Map<String, dynamic> data, {
    required ReminderStatus status,
    bool busy = false,
    int revision = 0,
  }) {
    final conversation = data['conversation'];
    final due = data['dueAt'];
    final anchor = data['anchorEventId'];
    return ReminderEntry(
      id: id,
      conversation: conversation is Map
          ? Map<String, dynamic>.from(conversation)
          : const {},
      dueAt: due is String ? DateTime.tryParse(due)?.toLocal() : null,
      untilReply: data['untilReply'] == true,
      anchorEventId: anchor is String ? anchor : null,
      status: status,
      revision: revision,
      busy: busy,
      replyCheckSkipped:
          status == ReminderStatus.done && data['replyCheck'] == 'skipped',
    );
  }
}

/// Earliest accepted reminder time: a reminder must lie in the future when
/// the worker sees it.
bool reminderTimeValid(DateTime at, DateTime now) =>
    at.isAfter(now.add(const Duration(seconds: 30)));

/// One-tap times, Slack/Gmail style. "This evening" only while it is still
/// at least an hour away.
List<({String label, DateTime at})> reminderPresets(DateTime now) {
  final minute = DateTime(now.year, now.month, now.day, now.hour, now.minute);
  final evening = DateTime(now.year, now.month, now.day, 18);
  final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
  final daysToMonday = (DateTime.monday - now.weekday + 7) % 7;
  final monday = DateTime(
    now.year,
    now.month,
    now.day + (daysToMonday == 0 ? 7 : daysToMonday),
    9,
  );
  return [
    (label: 'In 1 hour', at: minute.add(const Duration(hours: 1))),
    (label: 'In 3 hours', at: minute.add(const Duration(hours: 3))),
    if (evening.difference(now) >= const Duration(hours: 1))
      (label: 'This evening', at: evening),
    (label: 'Tomorrow morning', at: tomorrow),
    (label: 'Next week', at: monday),
  ];
}

/// "Today", "Tomorrow", "Yesterday", otherwise the medium date (the short
/// date with the year when the year differs).
String reminderDay(
  DateTime at,
  DateTime now,
  MaterialLocalizations localizations,
) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  // Rounded: a daylight-saving day is 23 or 25 hours long.
  final days = (day.difference(today).inHours / 24).round();
  return switch (days) {
    0 => 'Today',
    1 => 'Tomorrow',
    -1 => 'Yesterday',
    _ =>
      at.year == now.year
          ? localizations.formatMediumDate(at)
          : localizations.formatShortDate(at),
  };
}

/// "Today · 18:00", "Tomorrow · 09:00", "Fri, Oct 24 · 09:00".
String reminderWhen(
  DateTime at,
  DateTime now,
  MaterialLocalizations localizations, {
  bool use24h = true,
}) {
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(at),
    alwaysUse24HourFormat: use24h,
  );
  return '${reminderDay(at, now, localizations)} · $time';
}

/// Stages a private-sync command; [PersonalClient.command] in the app.
typedef ReminderCommand =
    Future<Object?> Function(
      String kind,
      String entityId,
      Map<String, dynamic> payload, {
      int? baseRevision,
    });

/// Stages a new reminder; returns its id.
Future<String> createReminder(
  ReminderCommand command, {
  required Map<String, dynamic> conversation,
  required DateTime dueAt,
  required bool untilReply,
  String? anchorEventId,
}) async {
  final id = const Uuid().v4();
  await command('reminder.create', id, {
    'id': id,
    'conversation': conversation,
    'dueAt': dueAt.toUtc().toIso8601String(),
    'untilReply': untilReply,
    'anchorEventId': ?anchorEventId,
  });
  return id;
}

Future<void> cancelReminder(ReminderCommand command, ReminderEntry entry) =>
    command('reminder.cancel', entry.id, {
      'id': entry.id,
    }, baseRevision: entry.revision);

/// New time or reply rule for [entry]: creates the replacement first, then
/// cancels the original (see the library comment).
Future<String> rescheduleReminder(
  ReminderCommand command,
  ReminderEntry entry, {
  required DateTime dueAt,
  required bool untilReply,
}) async {
  final id = await createReminder(
    command,
    conversation: entry.conversation,
    dueAt: dueAt,
    untilReply: untilReply,
    anchorEventId: entry.anchorEventId,
  );
  if (entry.editable) await cancelReminder(command, entry);
  return id;
}
