// SPDX-License-Identifier: AGPL-3.0-or-later
// Sheets and flows of a merged person: the choice sheets of the person page
// and the shared "Add chat…" / notifications flows that other surfaces (the
// inbox long-press menu) call as well.
import 'dart:async';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart'
    show privateNotificationLabel;
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// One option of a [showPersonChoiceSheet].
class PersonChoice<T> {
  final T value;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool selected;
  final bool destructive;
  const PersonChoice({
    required this.value,
    required this.title,
    this.subtitle,
    this.leading,
    this.selected = false,
    this.destructive = false,
  });
}

/// A sheet of [choices]; resolves to the picked value (null when dismissed).
/// [T] must not be nullable: null means dismissed.
Future<T?> showPersonChoiceSheet<T extends Object>(
  BuildContext context, {
  required String title,
  String? message,
  required List<PersonChoice<T>> choices,
}) => showNotionSheet<T>(
  context: context,
  title: title,
  builder: (context) {
    final tokens = context.notion;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: NotionSpace.xs),
              child: Text(message, style: tokens.typography.footnoteMuted),
            ),
          for (final choice in choices)
            Semantics(
              selected: choice.selected,
              child: NotionListRow(
                leading: choice.leading,
                title: choice.title,
                subtitle: choice.subtitle,
                trailing: choice.selected
                    ? Icon(
                        Icons.check,
                        size: NotionSize.iconMd,
                        color: tokens.colors.accent,
                      )
                    : const SizedBox.shrink(),
                onTap: () => Navigator.of(context).pop(choice.value),
              ),
            ),
        ],
      ),
    );
  },
);

/// A one-line text question in a Notion dialog; null when cancelled.
Future<String?> showPersonTextDialog(
  BuildContext context, {
  required String title,
  String? message,
  String initial = '',
  String? hint,
  required String confirmLabel,
}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showNotionDialog<String>(
      context: context,
      title: title,
      message: message,
      content: NotionTextField(
        controller: controller,
        hint: hint,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: (context) => [
        NotionButton.ghost(
          label: MaterialLocalizations.of(context).cancelButtonLabel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        NotionButton.primary(
          label: confirmLabel,
          onPressed: () => Navigator.of(context).pop(controller.text),
        ),
      ],
    );
  } finally {
    controller.dispose();
  }
}

String personNetworkLabel(PersonSource source) =>
    notionNetworkLabel(source.member.network);

/// The notification choices of a merged person, explained as Telegram and
/// Messenger do: one mode for the person, an override per network.
List<PersonChoice<String>> personNotificationChoices(
  PersonalNotificationMode? current, {
  required String inheritLabel,
  String? inheritSubtitle,
}) => [
  for (final mode in PersonalNotificationMode.values)
    PersonChoice(
      value: mode.name,
      title: privateNotificationLabel(mode),
      selected: current == mode,
    ),
  PersonChoice(
    value: 'inherit',
    title: inheritLabel,
    subtitle: inheritSubtitle,
    selected: current == null,
  ),
];

/// The person's own notification mode (all of its chats), in a sheet. Used
/// by the person page and the inbox long-press menu. Private: other Beeper
/// and Matrix clients are unchanged.
Future<void> showPersonNotificationsSheet(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) async {
  final projection = InboxProjection(personal);
  final current = projection
      .metadataForEntity('person:${group.id}')
      .notificationMode;
  final picked = await showPersonChoiceSheet<String>(
    context,
    title: 'Notifications',
    message:
        'For ${projection.personName(group)} on every network. Only ChatLoom changes; other Beeper and Matrix apps keep their own settings.',
    choices: personNotificationChoices(
      current,
      inheritLabel: 'Network default',
      inheritSubtitle: 'Follow each network’s notification settings',
    ),
  );
  if (picked == null || !context.mounted) return;
  final mode = preferenceEnum(PersonalNotificationMode.values, picked);
  if (mode == current) return;
  await runPersonChange(
    context,
    () => setPersonNotificationMode(personal, group, mode),
    failure: 'Notifications were not changed. Check private sync and try again.',
  );
}

/// Runs a private person change; a failure is explained in a snackbar.
/// Returns whether it was saved.
Future<bool> runPersonChange(
  BuildContext context,
  Future<void> Function() change, {
  String failure = 'The change was not saved. Check private sync and try again.',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await change();
    return true;
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(failure)));
    return false;
  }
}

/// "Add chat…" of a merged person: the merge picker anchored at the
/// person, then the merge with Undo. Used by the person page and the inbox
/// long-press menu of a merged row.
Future<void> addChatsToPerson(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) async {
  if (!personal.ready) return;
  final projection = InboxProjection(personal);
  final anchor = projection.activeSourcesOf(group).firstOrNull;
  final picked = await showMergePicker(
    context,
    personal: personal,
    anchor: anchor,
    title: 'Add a chat to ${projection.personName(group)}',
    excludeGroupId: group.id,
  );
  if (picked == null ||
      picked.isEmpty ||
      !context.mounted ||
      !identical(Matrix.of(context).client, personal.client)) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final MergePlan plan;
  try {
    plan = planAddToPerson(personal, group, [
      for (final candidate in picked) ...candidate.sources,
    ]);
    await applyMerge(personal, plan);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('The chat could not be added. Check private sync.'),
      ),
    );
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text('Added to the merged chat'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(
            undoMerge(personal, plan).catchError((Object _) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'The change was not undone. Check private sync.',
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
}

/// Removes [roomId] from [group] with Undo. Removing the second-last chat
/// unmerges the person (the chats return as separate chats).
Future<void> removeChatFromPerson(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
  required String roomId,
  VoidCallback? onUnmerged,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  PersonGroup? next;
  try {
    next = await removePersonSource(personal, group, roomId);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'The chat was not removed. Check private sync and try again.',
        ),
      ),
    );
    return;
  }
  if (next == null) onUnmerged?.call();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          next == null ? 'Chats unmerged' : 'Removed from the merged chat',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(
            personal.putGroup(group).catchError((Object _) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'The change was not undone. Check private sync.',
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
}

/// Unmerges [group] with Undo; the chats and messages are kept.
Future<void> unmergePerson(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  // Hidden at once; the delete may wait for a merge acknowledgement. If that
  // never comes, the person returns and the user is told.
  unawaited(
    personal.removeGroup(group.id).catchError((Object _) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The chats were not unmerged. Check private sync.'),
        ),
      );
    }),
  );
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text('Chats unmerged'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(
            personal.putGroup(group).catchError((Object _) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'The change was not undone. Check private sync.',
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
}

/// The rooms [room] could be replaced with: picker for a chat that was left
/// or recreated (a new portal of the same contact).
Future<void> replacePersonSource(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
  required String roomId,
}) async {
  final projection = InboxProjection(personal);
  final anchor = projection.activeSourcesOf(group).firstOrNull;
  final source = projection
      .sourcesOf(group)
      .where((s) => s.member.roomId == roomId)
      .firstOrNull;
  final picked = await showMergePicker(
    context,
    personal: personal,
    anchor: anchor,
    title: source == null
        ? 'Replace a chat'
        : 'Replace the ${personNetworkLabel(source)} chat',
    excludeGroupId: group.id,
    single: true,
  );
  if (picked == null ||
      picked.isEmpty ||
      !context.mounted ||
      !identical(Matrix.of(context).client, personal.client)) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    final plan = planAddToPerson(personal, group, [
      for (final candidate in picked) ...candidate.sources,
    ]);
    await applyMerge(personal, plan);
    final next = plan.group.members.any((m) => m.roomId == roomId)
        ? plan.group.withoutSource(
            roomId,
            preferredDefault: picked.first.representative.id,
          )
        : plan.group;
    if (next != null && !identical(next, plan.group)) {
      await personal.putGroup(next);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chat replaced'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              undoMerge(personal, plan).catchError((Object _) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'The change was not undone. Check private sync.',
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      );
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('The chat was not replaced. Check private sync.'),
      ),
    );
  }
}

/// A short description of when [room] last had a message, for pickers.
String? personSourceActivity(BuildContext context, Room room) {
  final last = room.lastEvent?.originServerTs;
  if (last == null) return null;
  final now = DateTime.now();
  final age = now.difference(last);
  if (age.isNegative || age < const Duration(minutes: 1)) return 'Active now';
  if (age < const Duration(hours: 1)) {
    return 'Last message ${age.inMinutes} min ago';
  }
  if (age < const Duration(days: 1)) {
    return 'Last message ${age.inHours} h ago';
  }
  if (age < const Duration(days: 7)) {
    final days = age.inDays;
    return days == 1 ? 'Last message yesterday' : 'Last message $days days ago';
  }
  return 'No recent messages';
}
