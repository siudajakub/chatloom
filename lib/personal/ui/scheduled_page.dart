// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings › Scheduled messages (UI-04): the Send later queue in the
/// Reminders page's language. Sections "Needs attention", "Upcoming" and
/// "Recent"; each row names the chat, previews the message, says when
/// ("Tomorrow · 09:00") and its state in words ("Waiting for encryption
/// keys"), never the worker's state names or an ISO time. Row ⋯ is a
/// glass menu (Send now, Edit, Cancel); Edit is the Send later sheet's
/// time picker; Cancel asks once (it cannot be undone); a message that was
/// not sent can be scheduled again.
library;

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/reminder_list.dart';
import 'package:chatloom/personal/ui/due_time_picker.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart' show RelationshipTypes;
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

enum ScheduledGroup { attention, upcoming, recent }

/// What a scheduled job looks like to the user.
@immutable
class ScheduledStatus {
  final ScheduledGroup group;

  /// The state in words; null when the time alone says it ("queued").
  final String? note;
  final IconData icon;
  final bool danger;
  const ScheduledStatus(
    this.group,
    this.note,
    this.icon, {
    this.danger = false,
  });
}

/// Maps the worker's job state to a section, words and an icon. [pending]:
/// a change to this job still waits for the worker's acknowledgement.
ScheduledStatus scheduledStatus(
  Map<String, dynamic> job, {
  required bool pending,
  required DateTime now,
}) {
  final state = job['state'];
  final due = DateTime.tryParse(job['dueAt'] as String? ?? '')?.toLocal();
  final attempted = job['attempted'] == true;
  if (pending && state != 'done' && state != 'cancelled') {
    return const ScheduledStatus(
      ScheduledGroup.upcoming,
      'Saving…',
      Icons.schedule_outlined,
    );
  }
  return switch (state) {
    'waitingSync' => const ScheduledStatus(
      ScheduledGroup.upcoming,
      'Saving…',
      Icons.schedule_outlined,
    ),
    'queued' when attempted || (due != null && !due.isAfter(now)) =>
      const ScheduledStatus(
        ScheduledGroup.upcoming,
        'Sending…',
        Icons.send_outlined,
      ),
    'queued' => const ScheduledStatus(
      ScheduledGroup.upcoming,
      null,
      Icons.schedule_outlined,
    ),
    'processing' => const ScheduledStatus(
      ScheduledGroup.upcoming,
      'Sending…',
      Icons.send_outlined,
    ),
    'paused' => const ScheduledStatus(
      ScheduledGroup.attention,
      'Paused',
      Icons.pause_circle_outline,
    ),
    'waitingKeys' => const ScheduledStatus(
      ScheduledGroup.attention,
      'Waiting for encryption keys',
      Icons.key_outlined,
    ),
    'done' => const ScheduledStatus(
      ScheduledGroup.recent,
      'Sent',
      Icons.check_circle_outline,
    ),
    'cancelled' => const ScheduledStatus(
      ScheduledGroup.recent,
      'Cancelled',
      Icons.block_outlined,
    ),
    'failed' => const ScheduledStatus(
      ScheduledGroup.attention,
      'Not sent. Tap to schedule it again',
      Icons.error_outline,
      danger: true,
    ),
    'conflict' => const ScheduledStatus(
      ScheduledGroup.attention,
      'Changed on another device',
      Icons.sync_problem_outlined,
      danger: true,
    ),
    _ => const ScheduledStatus(
      ScheduledGroup.attention,
      'Status unknown. Check private sync',
      Icons.help_outline,
    ),
  };
}

/// One line of the message: the text, or the attachment's name.
String scheduledPreview(Map<String, dynamic> job) {
  final content = job['content'];
  final body = content is Map && content['body'] is String
      ? (content['body'] as String).replaceAll(RegExp(r'\s+'), ' ').trim()
      : '';
  final type = content is Map ? content['msgtype'] : null;
  final text = switch (type) {
    'm.image' => 'Photo · $body',
    'm.video' => 'Video · $body',
    'm.audio' => 'Audio · $body',
    'm.file' => 'File · $body',
    _ => body.isEmpty ? 'Message' : body,
  };
  return text.length > 80 ? '${text.substring(0, 79)}…' : text;
}

/// "Telegram · Reply" for the row.
String scheduledSourceLabel(Map<String, dynamic> job) {
  final target = job['target'];
  final conversation = target is Map ? target['conversation'] : null;
  final network = conversation is Map ? conversation['network'] : null;
  final content = job['content'];
  final relation = content is Map ? content['m.relates_to'] : null;
  return [
    if (network is String && network.isNotEmpty && network != 'unknown')
      notionNetworkLabel(network),
    if (relation is Map && relation['rel_type'] == RelationshipTypes.thread)
      'Thread'
    else if (relation is Map && relation['m.in_reply_to'] is Map)
      'Reply',
  ].join(' · ');
}

class ScheduledMessagesSection extends StatelessWidget {
  final PersonalClient personal;
  final Future<void> Function(Future<void> Function()) run;
  final DateTime Function() clock;
  const ScheduledMessagesSection({
    super.key,
    required this.personal,
    required this.run,
    this.clock = DateTime.now,
  });

  bool _pending(String id) =>
      personal.pending.values.any((op) => op.entityId == id);

  /// Send now / Cancel: queued, paused or waiting for keys, never tried.
  bool _actionable(String id, Map<String, dynamic> job) =>
      personal.ready &&
      {'queued', 'paused', 'waitingKeys'}.contains(job['state']) &&
      job['attempted'] != true &&
      !_pending(id);

  /// Edit: the worker accepts an update while queued or paused.
  bool _editable(String id, Map<String, dynamic> job) =>
      _actionable(id, job) && {'queued', 'paused'}.contains(job['state']);

  bool _again(String id, Map<String, dynamic> job) =>
      personal.ready && job['state'] == 'failed' && !_pending(id);

  String _chatName(Map<String, dynamic> job) {
    try {
      final target = job['target'];
      final conversation = target is Map ? target['conversation'] : null;
      final roomId = conversation is Map ? conversation['roomId'] : null;
      final room = roomId is String
          ? personal.client.getRoomById(roomId)
          : null;
      if (room != null) return InboxProjection(personal).displayName(room);
    } catch (_) {}
    return 'Conversation';
  }

  @override
  Widget build(BuildContext context) {
    final now = clock();
    final rows = <ScheduledGroup, List<MapEntry<String, Map<String, dynamic>>>>{
      for (final group in ScheduledGroup.values) group: [],
    };
    for (final entry in personal.schedules.entries) {
      final status = scheduledStatus(
        entry.value,
        pending: _pending(entry.key),
        now: now,
      );
      rows[status.group]!.add(entry);
    }
    DateTime due(MapEntry<String, Map<String, dynamic>> e) =>
        DateTime.tryParse(e.value['dueAt'] as String? ?? '') ?? now;
    rows[ScheduledGroup.attention]!.sort((a, b) => due(a).compareTo(due(b)));
    rows[ScheduledGroup.upcoming]!.sort((a, b) => due(a).compareTo(due(b)));
    rows[ScheduledGroup.recent]!.sort((a, b) => due(b).compareTo(due(a)));
    final recent = rows[ScheduledGroup.recent]!.take(20);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (personal.schedules.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: NotionSpace.xl),
            child: NotionEmptyState(
              icon: Icons.schedule_outlined,
              title: 'No scheduled messages',
              message:
                  'Write a message in a chat, then hold Send or open the chat’s ⋯ menu and choose Send later.',
            ),
          ),
        if (rows[ScheduledGroup.attention]!.isNotEmpty) ...[
          const NotionSettingsSection('Needs attention'),
          for (final e in rows[ScheduledGroup.attention]!)
            _row(context, e.key, e.value, now),
        ],
        if (rows[ScheduledGroup.upcoming]!.isNotEmpty) ...[
          const NotionSettingsSection('Upcoming'),
          for (final e in rows[ScheduledGroup.upcoming]!)
            _row(context, e.key, e.value, now),
        ],
        if (recent.isNotEmpty) ...[
          const NotionSettingsSection('Recent'),
          for (final e in recent) _row(context, e.key, e.value, now),
        ],
      ],
    );
  }

  Widget _row(
    BuildContext context,
    String id,
    Map<String, dynamic> job,
    DateTime now,
  ) {
    final status = scheduledStatus(job, pending: _pending(id), now: now);
    final at = DateTime.tryParse(job['dueAt'] as String? ?? '')?.toLocal();
    final when = at == null
        ? 'No time'
        : reminderWhen(
            at,
            now,
            MaterialLocalizations.of(context),
            use24h: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    final source = scheduledSourceLabel(job);
    final detail = [when, ?status.note, if (source.isNotEmpty) source];
    final actionable = _actionable(id, job);
    final editable = _editable(id, job);
    final again = _again(id, job);
    return NotionListRow(
      key: ValueKey('scheduled-$id'),
      leading: Icon(
        status.icon,
        color: status.danger ? context.notion.colors.danger : null,
      ),
      title: _chatName(job),
      subtitle: '${scheduledPreview(job)}\n${detail.join(' · ')}',
      onTap: editable
          ? () => _edit(context, id, job)
          : again
          ? () => _scheduleAgain(context, job)
          : null,
      trailing: actionable || again
          ? NotionMenuButton<String>(
              key: ValueKey('scheduled-menu-$id'),
              icon: Icons.more_horiz,
              label: 'Scheduled message options',
              keyPrefix: 'scheduled-menu',
              alignEnd: true,
              entries: () => [
                if (actionable) ...[
                  const NotionMenuEntry(
                    value: 'sendNow',
                    label: 'Send now',
                    icon: Icons.send_outlined,
                  ),
                  NotionMenuEntry(
                    value: 'edit',
                    label: 'Edit',
                    icon: Icons.edit_outlined,
                    enabled: editable,
                  ),
                  const NotionMenuEntry.divider(),
                  const NotionMenuEntry(
                    value: 'cancel',
                    label: 'Cancel message',
                    icon: Icons.delete_outline,
                    destructive: true,
                  ),
                ] else
                  const NotionMenuEntry(
                    value: 'again',
                    label: 'Schedule again',
                    icon: Icons.schedule_send_outlined,
                  ),
              ],
              onSelected: (action) => switch (action) {
                'sendNow' => _command(id, job, 'sendNow'),
                'edit' => _edit(context, id, job),
                'cancel' => _cancel(context, id, job),
                _ => _scheduleAgain(context, job),
              },
            )
          : null,
    );
  }

  bool _current(PersonalClient owner) =>
      identical(owner, personal) && owner.ready;

  Future<void> _command(String id, Map<String, dynamic> job, String kind) =>
      run(
        () => personal.command('schedule.$kind', id, {
          'id': id,
        }, baseRevision: job['revision'] as int? ?? 0),
      );

  Future<void> _cancel(
    BuildContext context,
    String id,
    Map<String, dynamic> job,
  ) async {
    final confirmed = await showNotionConfirmDialog(
      context: context,
      title: 'Cancel this message?',
      message: 'It won’t be sent. This can’t be undone.',
      confirmLabel: 'Cancel message',
      cancelLabel: 'Keep',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await _command(id, job, 'cancel');
  }

  Future<void> _edit(
    BuildContext context,
    String id,
    Map<String, dynamic> job,
  ) async {
    final owner = personal;
    final content = Map<String, dynamic>.from(job['content'] as Map);
    final text = {'m.text', 'm.notice'}.contains(content['msgtype'])
        ? content['body'] as String? ?? ''
        : null;
    final at = DateTime.tryParse(job['dueAt'] as String? ?? '')?.toLocal();
    final result = await showScheduledEditor(
      context,
      chatName: _chatName(job),
      text: text,
      at: at,
      clock: clock,
    );
    if (result == null || !context.mounted || !_current(owner)) return;
    if (result.text != null) content['body'] = result.text;
    final updated = ScheduledSend.fromJson({
      ...job,
      'dueAt': result.at.toUtc().toIso8601String(),
      'content': content,
    });
    await run(
      () => owner.command(
        'schedule.update',
        id,
        updated.toJson().cast<String, dynamic>(),
        baseRevision: job['revision'] as int? ?? 0,
      ),
    );
  }

  /// A message that was not sent: the same content, a new time, a new job.
  Future<void> _scheduleAgain(
    BuildContext context,
    Map<String, dynamic> job,
  ) async {
    final owner = personal;
    final result = await showScheduledEditor(
      context,
      chatName: _chatName(job),
      clock: clock,
      title: 'Schedule again',
      saveLabel: 'Schedule again',
    );
    if (result == null || !context.mounted || !_current(owner)) return;
    final id = const Uuid().v4();
    final again = ScheduledSend(
      id: id,
      target: SendTarget.fromJson(
        Map<String, dynamic>.from(job['target'] as Map),
      ),
      dueAt: result.at,
      transactionId: 'schedule-$id',
      content: Map<String, dynamic>.from(job['content'] as Map),
    );
    await run(() => owner.schedule(again));
  }
}

/// The edit sheet: the message text (text messages only) and the Send later
/// time picker. Returns null when dismissed.
Future<({String? text, DateTime at})?> showScheduledEditor(
  BuildContext context, {
  required String chatName,
  String? text,
  DateTime? at,
  DateTime Function() clock = DateTime.now,
  String title = 'Edit scheduled message',
  String saveLabel = 'Save',
}) => showNotionSheet<({String? text, DateTime at})>(
  context: context,
  title: title,
  builder: (_) => _ScheduledEditor(
    chatName: chatName,
    text: text,
    at: at,
    clock: clock,
    saveLabel: saveLabel,
  ),
);

class _ScheduledEditor extends StatefulWidget {
  final String chatName;
  final String? text;
  final DateTime? at;
  final DateTime Function() clock;
  final String saveLabel;
  const _ScheduledEditor({
    required this.chatName,
    required this.text,
    required this.at,
    required this.clock,
    required this.saveLabel,
  });

  @override
  State<_ScheduledEditor> createState() => _ScheduledEditorState();
}

class _ScheduledEditorState extends State<_ScheduledEditor> {
  late final _presets = reminderPresets(widget.clock());
  late final TextEditingController? _text = widget.text == null
      ? null
      : TextEditingController(text: widget.text);
  late DateTime _at;
  String? _preset;

  @override
  void initState() {
    super.initState();
    final at = widget.at;
    if (at != null && at.isAfter(widget.clock())) {
      _at = at;
    } else {
      final initial = _presets.firstWhere(
        (p) => p.label == 'Tomorrow morning',
        orElse: () => _presets.first,
      );
      _at = initial.at;
      _preset = initial.label;
    }
  }

  @override
  void dispose() {
    _text?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final valid =
        DueTimePicker.valid(_at, widget.clock()) &&
        (text == null || text.text.trim().isNotEmpty);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.chatName,
            style: context.notion.typography.footnoteMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: NotionSpace.xs),
          if (text != null) ...[
            NotionTextField(
              key: const ValueKey('scheduled-edit-text'),
              controller: text,
              hint: 'Message',
              minLines: 1,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: NotionSpace.md),
          ],
          DueTimePicker(
            at: _at,
            preset: _preset,
            presets: _presets,
            clock: widget.clock,
            keyPrefix: 'scheduled-edit',
            onChanged: (at, preset) => setState(() {
              _at = at;
              _preset = preset;
            }),
          ),
          const SizedBox(height: NotionSpace.md),
          NotionButton.primary(
            key: const ValueKey('scheduled-edit-save'),
            label: widget.saveLabel,
            expand: true,
            onPressed: valid
                ? () => Navigator.of(
                    context,
                  ).pop((text: text?.text.trim(), at: _at))
                : null,
          ),
        ],
      ),
    );
  }
}
