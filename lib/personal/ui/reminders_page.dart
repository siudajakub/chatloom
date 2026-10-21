// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings → Reminders, and the "Remind me" editor used from a chat.
///
/// One editor for creating and editing: one-tap times (Slack/Gmail style),
/// a date and a time row for anything else, inline validation instead of a
/// generic error after the fact, and a plain reminder by default ("only if
/// no reply" is opt-in, because a reply silently cancels the reminder).
library;

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/reminder_list.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// What the editor returns: a new time and rule, or a delete request.
@immutable
class ReminderEditorResult {
  final DateTime? dueAt;
  final bool untilReply;
  final bool archive;
  final bool delete;
  const ReminderEditorResult({
    required DateTime this.dueAt,
    required this.untilReply,
    this.archive = false,
  }) : delete = false;
  const ReminderEditorResult.delete()
    : dueAt = null,
      untilReply = false,
      archive = false,
      delete = true;
}

/// Opens the reminder editor as a sheet.
Future<ReminderEditorResult?> showReminderEditor(
  BuildContext context, {
  required String chatName,
  ReminderEntry? editing,
  bool offerArchive = false,
  DateTime Function()? clock,
}) => showNotionSheet<ReminderEditorResult>(
  context: context,
  title: editing == null ? 'Remind me' : 'Edit reminder',
  builder: (context) => ReminderEditor(
    chatName: chatName,
    editing: editing,
    offerArchive: offerArchive,
    clock: clock ?? DateTime.now,
  ),
);

class ReminderEditor extends StatefulWidget {
  final String chatName;
  final ReminderEntry? editing;
  final bool offerArchive;
  final DateTime Function() clock;
  const ReminderEditor({
    super.key,
    required this.chatName,
    this.editing,
    this.offerArchive = false,
    this.clock = DateTime.now,
  });

  @override
  State<ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<ReminderEditor> {
  late final DateTime _opened = widget.clock();
  late final _presets = reminderPresets(_opened);
  late DateTime _at;
  String? _preset;
  late bool _untilReply = widget.editing?.untilReply ?? false;
  bool _archive = false;

  @override
  void initState() {
    super.initState();
    final due = widget.editing?.dueAt;
    if (due != null && reminderTimeValid(due, _opened)) {
      _at = due;
    } else {
      _at = _presets.first.at;
      _preset = _presets.first.label;
    }
  }

  bool get _valid => reminderTimeValid(_at, widget.clock());

  Future<void> _pickDate() async {
    final now = widget.clock();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDate: _at.isBefore(today) ? today : _at,
    );
    if (date == null || !mounted) return;
    setState(() {
      _at = DateTime(date.year, date.month, date.day, _at.hour, _at.minute);
      _preset = null;
    });
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (time == null || !mounted) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, time.hour, time.minute);
      _preset = null;
    });
  }

  Future<void> _custom() async {
    await _pickDate();
    if (mounted) await _pickTime();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final now = widget.clock();
    final valid = _valid;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.chatName,
            style: tokens.typography.footnoteMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: NotionSpace.md),
          Wrap(
            spacing: NotionSpace.xs,
            runSpacing: NotionSpace.xs,
            children: [
              for (final preset in _presets)
                NotionGlassPill(
                  key: ValueKey('reminder-preset-${preset.label}'),
                  label: preset.label,
                  selected: _preset == preset.label,
                  onPressed: () => setState(() {
                    _at = preset.at;
                    _preset = preset.label;
                  }),
                ),
              NotionGlassPill(
                key: const ValueKey('reminder-preset-custom'),
                icon: Icons.edit_calendar_outlined,
                label: 'Pick date & time',
                selected: _preset == null,
                onPressed: _custom,
              ),
            ],
          ),
          const SizedBox(height: NotionSpace.sm),
          NotionPropertyRow(
            key: const ValueKey('reminder-date'),
            label: 'Date',
            value: Text(
              reminderDay(_at, now, localizations),
              style: NotionType.body,
            ),
            onTap: _pickDate,
          ),
          NotionPropertyRow(
            key: const ValueKey('reminder-time'),
            label: 'Time',
            value: Text(
              localizations.formatTimeOfDay(
                TimeOfDay.fromDateTime(_at),
                alwaysUse24HourFormat: use24h,
              ),
              style: NotionType.body,
            ),
            onTap: _pickTime,
          ),
          NotionSizeReveal(
            visible: !valid,
            child: Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: NotionSpace.xs),
                child: Text(
                  'Choose a time in the future.',
                  style: NotionType.footnote.copyWith(
                    color: tokens.colors.danger,
                  ),
                ),
              ),
            ),
          ),
          NotionSettingsToggle(
            title: 'Only if they don’t reply',
            subtitle: _untilReply
                ? 'Skipped when a new message arrives in this chat first.'
                : 'Off: you are reminded at this time in any case.',
            value: _untilReply,
            onChanged: (value) => setState(() => _untilReply = value),
          ),
          if (widget.offerArchive && widget.editing == null)
            NotionSettingsToggle(
              title: 'Archive until then',
              subtitle: 'The chat returns to the inbox with the reminder.',
              value: _archive,
              onChanged: (value) => setState(() => _archive = value),
            ),
          const SizedBox(height: NotionSpace.md),
          NotionButton.primary(
            label: 'Save reminder',
            expand: true,
            onPressed: valid
                ? () => Navigator.of(context).pop(
                    ReminderEditorResult(
                      dueAt: _at,
                      untilReply: _untilReply,
                      archive: _archive,
                    ),
                  )
                : null,
          ),
          if (widget.editing != null) ...[
            const SizedBox(height: NotionSpace.xs),
            NotionButton(
              label: 'Delete reminder',
              variant: NotionButtonVariant.ghost,
              icon: Icons.delete_outline,
              expand: true,
              onPressed: () => Navigator.of(
                context,
              ).pop(const ReminderEditorResult.delete()),
            ),
          ],
        ],
      ),
    );
  }
}

/// Chat name for a reminder, respecting private nicknames.
String reminderChatName(PersonalClient personal, ReminderEntry entry) {
  try {
    final roomId = entry.roomId;
    final room = roomId == null ? null : personal.client.getRoomById(roomId);
    if (room != null) return InboxProjection(personal).displayName(room);
  } catch (_) {}
  return 'Conversation';
}

String _failure(Object error) {
  final text = error.toString();
  if (text.contains('acknowledgement')) {
    return 'This reminder is still saving. Try again in a moment.';
  }
  if (text.contains('not connected')) {
    return 'Reminders need private sync. Connect it in Advanced.';
  }
  return 'The reminder could not be saved. Check private sync and try again.';
}

void _say(
  ScaffoldMessengerState? messenger,
  String text, {
  SnackBarAction? action,
}) {
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

class RemindersPage extends StatefulWidget {
  final PersonalClient personal;

  /// Tests pin the time; the list itself needs no ticking clock because it
  /// shows absolute times.
  final DateTime Function() clock;
  const RemindersPage({
    super.key,
    required this.personal,
    this.clock = DateTime.now,
  });

  @override
  State<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends State<RemindersPage> {
  PersonalClient get personal => widget.personal;

  @override
  void initState() {
    super.initState();
    PersonalPageLoad.request(context, personal);
  }

  bool get _current =>
      mounted && identical(Matrix.of(context).client, personal.client);

  /// Runs [action]; a failure is explained in a snackbar. Undo may run after
  /// the page closed, so the messenger can be captured beforehand.
  Future<void> _run(
    Future<void> Function() action, [
    ScaffoldMessengerState? messenger,
  ]) async {
    messenger ??= mounted ? ScaffoldMessenger.maybeOf(context) : null;
    try {
      await action();
    } catch (error) {
      _say(messenger, _failure(error));
    }
  }

  Future<void> _edit(ReminderEntry entry) async {
    final result = await showReminderEditor(
      context,
      chatName: reminderChatName(personal, entry),
      editing: entry,
      clock: widget.clock,
    );
    if (result == null || !mounted || !_current) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (result.delete) {
      await _run(() async {
        await cancelReminder(personal.command, entry);
        final due = entry.dueAt;
        _say(
          messenger,
          'Reminder deleted',
          // Undo sets the same reminder again (the worker has no restore).
          action: due == null || !reminderTimeValid(due, widget.clock())
              ? null
              : SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _run(
                    () => createReminder(
                      personal.command,
                      conversation: entry.conversation,
                      dueAt: due,
                      untilReply: entry.untilReply,
                      anchorEventId: entry.anchorEventId,
                    ),
                    messenger,
                  ),
                ),
        );
      });
      return;
    }
    await _run(
      () => rescheduleReminder(
        personal.command,
        entry,
        dueAt: result.dueAt!,
        untilReply: result.untilReply,
      ),
    );
  }

  /// A fired, skipped or refused reminder: set it again for a new time.
  Future<void> _again(ReminderEntry entry) async {
    final result = await showReminderEditor(
      context,
      chatName: reminderChatName(personal, entry),
      clock: widget.clock,
    );
    if (result == null || result.delete || !_current) return;
    await _run(
      () => createReminder(
        personal.command,
        conversation: entry.conversation,
        dueAt: result.dueAt!,
        untilReply: result.untilReply,
        anchorEventId: entry.anchorEventId,
      ),
    );
  }

  Future<void> _add() async {
    final room = await showNotionSheet<Room>(
      context: context,
      title: 'Choose a chat',
      builder: (_) => _ChatPicker(personal: personal),
    );
    if (room == null || !_current || !mounted) return;
    final result = await showReminderEditor(
      context,
      chatName: InboxProjection(personal).displayName(room),
      clock: widget.clock,
    );
    if (result == null || result.delete || !_current) return;
    final anchor = room.lastEvent?.eventId;
    await _run(
      () => createReminder(
        personal.command,
        conversation: personal.ref(room).toJson(),
        dueAt: result.dueAt!,
        untilReply: result.untilReply,
        anchorEventId: _validAnchor(anchor),
      ),
    );
  }

  Widget _row(ReminderEntry entry, DateTime now) {
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final due = entry.dueAt;
    final when = due == null
        ? 'No time'
        : reminderWhen(due, now, localizations, use24h: use24h);
    final note = switch (entry.status) {
      ReminderStatus.saving => 'Saving…',
      ReminderStatus.scheduled => entry.untilReply ? 'Only if no reply' : null,
      ReminderStatus.checking =>
        due != null && due.isBefore(now)
            ? 'Waiting to check for replies'
            : 'Only if no reply',
      ReminderStatus.done =>
        entry.replyCheckSkipped ? 'Done · couldn’t check for replies' : 'Done',
      ReminderStatus.skipped => 'Skipped, they replied',
      ReminderStatus.notSaved => 'Not saved. Tap to set it again',
    };
    final icon = switch (entry.status) {
      ReminderStatus.done => Icons.check_circle_outline,
      ReminderStatus.skipped => Icons.reply_outlined,
      ReminderStatus.notSaved => Icons.error_outline,
      _ => Icons.alarm_outlined,
    };
    final onTap = !personal.ready
        ? null
        : entry.editable
        ? () => _edit(entry)
        : entry.busy
        ? null
        : entry.upcoming && entry.status != ReminderStatus.notSaved
        ? null
        : () => _again(entry);
    return NotionListRow(
      key: ValueKey('reminder-${entry.id}'),
      leading: Icon(
        icon,
        color: entry.status == ReminderStatus.notSaved
            ? context.notion.colors.danger
            : null,
      ),
      title: reminderChatName(personal, entry),
      subtitle: note == null ? when : '$when · $note',
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) {
      final now = widget.clock();
      final list = ReminderList.from(
        reminders: personal.reminders,
        pending: personal.pending.values,
        now: now,
      );
      return NotionSettingsScaffold(
        title: 'Reminders',
        actions: [
          NotionIconButton(
            icon: Icons.add,
            label: 'New reminder',
            onPressed: personal.ready ? _add : null,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionSizeReveal(
              visible: !personal.ready,
              child: NotionListRow(
                leading: const Icon(Icons.lock_outline),
                title: 'Private sync is unavailable',
                subtitle: kIsWeb
                    ? 'Private encrypted storage requires the native app.'
                    : personal.problem ??
                          'Reminders are kept in private sync. Connect it to use them.',
                onTap: () => context.push('/rooms/settings/sync'),
              ),
            ),
            if (list.isEmpty)
              NotionEmptyState(
                icon: Icons.alarm_outlined,
                title: 'No reminders',
                message:
                    'Bring a chat back at the right time. Use Remind me in a chat’s menu, or add one here.',
                action: NotionButton.primary(
                  label: 'New reminder',
                  icon: Icons.add,
                  onPressed: personal.ready ? _add : null,
                ),
              ),
            if (list.upcoming.isNotEmpty) ...[
              const NotionSettingsSection('Upcoming'),
              for (final entry in list.upcoming) _row(entry, now),
            ],
            if (list.past.isNotEmpty) ...[
              const NotionSettingsSection('Recent'),
              for (final entry in list.past) _row(entry, now),
            ],
          ],
        ),
      );
    },
  );
}

String? _validAnchor(String? anchor) =>
    anchor != null && anchor.startsWith(r'$') && anchor.length <= 255
    ? anchor
    : null;

/// Joined chats, most recent first, with a search field.
class _ChatPicker extends StatefulWidget {
  final PersonalClient personal;
  const _ChatPicker({required this.personal});
  @override
  State<_ChatPicker> createState() => _ChatPickerState();
}

class _ChatPickerState extends State<_ChatPicker> {
  late final List<({Room room, String name, String network})> _chats;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final projection = InboxProjection(widget.personal);
    final rooms =
        widget.personal.client.rooms
            .where((r) => r.membership == Membership.join && !r.isSpace)
            .toList()
          ..sort(
            (a, b) =>
                b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
          );
    _chats = [
      for (final room in rooms)
        (
          room: room,
          name: projection.displayName(room),
          network: notionNetworkLabel(PersonalClient.networkOf(room)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? _chats
        : _chats.where((c) => c.name.toLowerCase().contains(query)).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionTextField(
          hint: 'Search chats',
          prefixIcon: Icons.search,
          autofocus: false,
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: NotionSpace.xs),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .55,
          ),
          child: matches.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(NotionSpace.md),
                  child: Text('No chats found'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: matches.length,
                  itemBuilder: (context, i) => NotionListRow(
                    title: matches[i].name,
                    subtitle: matches[i].network,
                    onTap: () => Navigator.of(context).pop(matches[i].room),
                  ),
                ),
        ),
      ],
    );
  }
}

/// "Remind me" from a conversation (ordinary chat or a merged chat's chosen
/// source). The reminder is anchored to the latest message, which the
/// notification shows.
Future<void> requestConversationReminder(
  BuildContext context,
  PersonalClient p,
  Room room, {
  required bool Function() isCurrent,
}) async {
  final anchorEventId = _validAnchor(room.lastEvent?.eventId);
  final account = p.client.userID;
  final generation = PersonalPrivacy.surfaceGeneration;
  bool current() =>
      context.mounted &&
      isCurrent() &&
      account != null &&
      p.client.userID == account &&
      identical(p.client.getRoomById(room.id), room) &&
      room.membership == Membership.join &&
      PersonalPrivacy.surfaceUnlocked &&
      PersonalPrivacy.surfaceGeneration == generation;
  await p.load();
  if (!context.mounted || !current()) return;
  final result = await showReminderEditor(
    context,
    chatName: InboxProjection(p).displayName(room),
    offerArchive: true,
  );
  if (result == null || result.delete || !current()) return;
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final localizations = MaterialLocalizations.of(context);
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  final due = result.dueAt!;
  if (!reminderTimeValid(due, DateTime.now())) {
    _say(messenger, 'Choose a time in the future.');
    return;
  }
  await createReminder(
    p.command,
    conversation: p.ref(room).toJson(),
    dueAt: due,
    untilReply: result.untilReply,
    anchorEventId: anchorEventId,
  );
  _say(
    messenger,
    'Reminder set · ${reminderWhen(due, DateTime.now(), localizations, use24h: use24h)}',
  );
  if (!current()) return;
  if (result.archive) {
    final projection = InboxProjection(p);
    final metadata = projection.metadataFor(room).setArchived(true);
    final group = projection.groupFor(room);
    final sources = group == null
        ? [room]
        : group.members
              .map((member) => p.client.getRoomById(member.roomId))
              .whereType<Room>();
    await p.put(projection.metadataKey(room), {
      ...metadata.toJson(),
      'archivedAt': DateTime.now().toUtc().toIso8601String(),
      'archiveSources': {
        for (final source in sources) source.id: source.lastEvent?.eventId,
      },
    });
  }
}
