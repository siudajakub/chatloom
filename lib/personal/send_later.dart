// SPDX-License-Identifier: AGPL-3.0-or-later

/// Send later: one sheet for the time (the Remind me picker), then the
/// typed text or an attachment is scheduled. Shared by ordinary and merged
/// chats, from the conversation menu and from a long press on Send.
library;

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart'
    show schedulePersonalAttachment;
import 'package:chatloom/personal/reminder_list.dart';
import 'package:chatloom/personal/scheduled_composer.dart';
import 'package:chatloom/personal/ui/due_time_picker.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

export 'package:chatloom/personal/scheduled_composer.dart'
    show SendLaterProblem;

/// What the Send later sheet returns.
@immutable
class SendLaterChoice {
  final DateTime at;

  /// Schedule an attachment (chosen next) instead of the typed text.
  final bool attachment;
  const SendLaterChoice(this.at, {this.attachment = false});
}

Future<SendLaterChoice?> showSendLaterSheet(
  BuildContext context, {
  required String chatName,
  required String text,
  String? contextLabel,
  DateTime Function()? clock,
}) => showNotionSheet<SendLaterChoice>(
  context: context,
  title: 'Send later',
  builder: (context) => SendLaterEditor(
    chatName: chatName,
    text: text,
    contextLabel: contextLabel,
    clock: clock ?? DateTime.now,
  ),
);

class SendLaterEditor extends StatefulWidget {
  final String chatName;
  final String text;
  final String? contextLabel;
  final DateTime Function() clock;
  const SendLaterEditor({
    super.key,
    required this.chatName,
    required this.text,
    this.contextLabel,
    this.clock = DateTime.now,
  });

  @override
  State<SendLaterEditor> createState() => _SendLaterEditorState();
}

class _SendLaterEditorState extends State<SendLaterEditor> {
  late final _presets = reminderPresets(widget.clock());
  late DateTime _at;
  String? _preset;

  bool get _hasText => widget.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // "Tomorrow morning" is the usual Send later time; fall back to the
    // first one-tap time when the list is short.
    final initial = _presets.firstWhere(
      (p) => p.label == 'Tomorrow morning',
      orElse: () => _presets.first,
    );
    _at = initial.at;
    _preset = initial.label;
  }

  void _done({bool attachment = false}) =>
      Navigator.of(context).pop(SendLaterChoice(_at, attachment: attachment));

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final valid = DueTimePicker.valid(_at, widget.clock());
    final label = widget.contextLabel;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label == null ? widget.chatName : '${widget.chatName} · $label',
            style: tokens.typography.footnoteMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: NotionSpace.xs),
          Text(
            _hasText
                ? widget.text.trim()
                : 'Write a message first, or schedule an attachment.',
            key: const ValueKey('send-later-preview'),
            style: _hasText ? NotionType.body : tokens.typography.footnoteMuted,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: NotionSpace.md),
          DueTimePicker(
            at: _at,
            preset: _preset,
            presets: _presets,
            clock: widget.clock,
            keyPrefix: 'send-later',
            onChanged: (at, preset) => setState(() {
              _at = at;
              _preset = preset;
            }),
          ),
          const SizedBox(height: NotionSpace.md),
          NotionButton.primary(
            label: 'Schedule message',
            expand: true,
            onPressed: valid && _hasText ? _done : null,
          ),
          const SizedBox(height: NotionSpace.xs),
          NotionButton(
            label: 'Schedule an attachment',
            variant: NotionButtonVariant.ghost,
            icon: Icons.attachment_outlined,
            expand: true,
            onPressed: valid ? () => _done(attachment: true) : null,
          ),
        ],
      ),
    );
  }
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

/// Runs Send later for one frozen source. [freeze] captures the source,
/// reply and thread before anything asynchronous (it may refuse, e.g. while
/// editing). [onTextScheduled] empties the composer once the text job is
/// stored, if the draft is still the scheduled text.
///
/// Every outcome is one short message: "Scheduled · Tomorrow · 09:00" with
/// View, or the specific problem (no private sync → Open, a past time, an
/// attachment that is too large, a changed source). Nothing is sent now.
Future<void> runSendLater(
  BuildContext context, {
  required PersonalClient personal,
  required FrozenScheduledComposer Function() freeze,
  required String text,
  required String chatName,
  required Future<void> Function() onTextScheduled,
  DateTime Function() clock = DateTime.now,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final localizations = MaterialLocalizations.of(context);
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  try {
    final frozen = freeze();
    // The sheet opens at once; private sync is checked when it is needed.
    final choice = await showSendLaterSheet(
      context,
      chatName: chatName,
      text: text,
      contextLabel: frozen.contextLabel,
      clock: clock,
    );
    if (choice == null || !context.mounted) return;
    await personal.load();
    if (!context.mounted) return;
    if (!personal.ready) {
      throw SendLaterProblem(
        'Send later needs private sync. Your draft is kept.',
        needsSync: true,
      );
    }
    frozen.validateCurrent();
    if (!DueTimePicker.valid(choice.at, clock())) {
      throw SendLaterProblem('That time has passed. Choose a new time.');
    }
    if (choice.attachment) {
      final scheduled = await schedulePersonalAttachment(
        context,
        personal,
        frozen.target,
        composeContext: frozen,
        dueAt: choice.at,
      );
      if (!scheduled) return;
    } else {
      if (text.trim().isEmpty) {
        throw SendLaterProblem('Write a message before scheduling it.');
      }
      final id = const Uuid().v4();
      await personal.schedule(
        ScheduledSend(
          id: id,
          target: frozen.target,
          dueAt: choice.at,
          content: frozen.content({'msgtype': 'm.text', 'body': text}),
          transactionId: 'schedule-$id',
        ),
      );
      await onTextScheduled();
    }
    _say(
      messenger,
      'Scheduled · ${reminderWhen(choice.at, clock(), localizations, use24h: use24h)}',
      action: router == null
          ? null
          : SnackBarAction(
              label: 'View',
              onPressed: () => router.push('/rooms/settings/scheduled'),
            ),
    );
  } on SendLaterProblem catch (problem) {
    _say(
      messenger,
      problem.message,
      action: problem.needsSync && router != null
          ? SnackBarAction(
              label: 'Open',
              onPressed: () => router.push('/rooms/settings/sync'),
            )
          : null,
    );
  } catch (_) {
    _say(messenger, 'Couldn’t schedule this message. Your draft is kept.');
  }
}
