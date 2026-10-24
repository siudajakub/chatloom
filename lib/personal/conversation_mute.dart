// SPDX-License-Identifier: AGPL-3.0-or-later

/// Mute… / Unmute in a conversation's ⋯ menu (FX-07): the same private,
/// synced mute as the inbox long-press menu (Telegram's "Mute for 1 hour /
/// 8 hours / 1 week / until I unmute"), shown and cleared where the chat is
/// open. Ordinary and merged conversations share it.
library;

import 'package:chatloom/pages/chat_list/chat_actions_menu.dart'
    show MuteChoice, muteMenuItems;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/reminder_list.dart' show reminderWhen;
import 'package:chatloom/personal/ui/chat_preferences_page.dart'
    show canEditChatPreferences;
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The mute row of a conversation menu: whether the entity is muted, a
/// human end ("Muted until Today · 14:30", "Muted") and whether it can be
/// changed now (private sync ready, no conflict).
typedef ConversationMuteState = ({bool muted, String? until, bool canChange});

/// "Muted until Today · 14:30" for a timed mute, "Muted" without an end.
String conversationMuteSubtitle(
  DateTime? until,
  DateTime now,
  MaterialLocalizations localizations, {
  bool use24h = true,
}) => until == null
    ? 'Muted'
    : 'Muted until ${reminderWhen(until.toLocal(), now, localizations, use24h: use24h)}';

ConversationMuteState conversationMuteState(
  BuildContext context,
  PersonalClient personal,
  String entity,
) {
  final metadata = InboxProjection(personal).metadataForEntity(entity);
  final muted = metadata.muted;
  return (
    muted: muted,
    until: muted
        ? conversationMuteSubtitle(
            metadata.mutedUntil,
            DateTime.now(),
            MaterialLocalizations.of(context),
            use24h: MediaQuery.alwaysUse24HourFormatOf(context),
          )
        : null,
    canChange: canEditChatPreferences(personal, 'org:$entity'),
  );
}

/// Human confirmation for a mute choice.
String conversationMuteDone(MuteChoice choice) => switch (choice) {
  MuteChoice.hour => 'Muted for 1 hour',
  MuteChoice.eightHours => 'Muted for 8 hours',
  MuteChoice.week => 'Muted for 1 week',
  MuteChoice.always || MuteChoice.settings => 'Muted',
};

/// Runs `mute` (a second menu step with the durations, anchored at
/// [anchorContext]) or `unmute` for [entity]. Optimistic: the private
/// change is written at once and confirmed with an Undo snackbar; a
/// failure explains itself. [isCurrent] guards against a switched account
/// or chat.
Future<void> runConversationMute(
  BuildContext anchorContext,
  PersonalClient personal,
  String entity, {
  required bool unmute,
  required bool Function() isCurrent,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(anchorContext);
  final previous = InboxProjection(personal).metadataForEntity(entity);
  void say(String text, {Future<void> Function()? undo}) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        action: undo == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () {
                  if (!isCurrent()) return;
                  undo().catchError(
                    (_) => say('Couldn’t undo. Check private sync.'),
                  );
                },
              ),
      ),
    );
  Future<void> write(Future<void> Function() change, String failure) async {
    try {
      await change();
    } catch (_) {
      if (isCurrent()) say(failure);
      rethrow;
    }
  }

  if (unmute) {
    final until = previous.mutedUntil;
    try {
      await write(
        () => NotionMetadataActions.setMuted(personal, entity, muted: false),
        'Couldn’t unmute the chat. Check private sync and try again.',
      );
    } catch (_) {
      return;
    }
    if (!isCurrent()) return;
    say(
      'Unmuted',
      undo: () => NotionMetadataActions.setMuted(
        personal,
        entity,
        muted: true,
        until: until,
      ),
    );
    return;
  }
  final canMute = canEditChatPreferences(personal, 'org:$entity');
  final choice = await showNotionMenu<MuteChoice>(
    anchorContext,
    semanticLabel: 'Mute',
    keyPrefix: 'mute-menu',
    entries: [
      for (final item in muteMenuItems(canMute: canMute))
        if (item.action != MuteChoice.settings)
          NotionMenuEntry(
            value: item.action,
            label: item.label,
            icon: item.icon,
            enabled: item.enabled,
          ),
    ],
  );
  if (choice == null || !isCurrent()) return;
  final duration = choice.duration;
  try {
    await write(
      () => NotionMetadataActions.setMuted(
        personal,
        entity,
        muted: true,
        until: duration == null ? null : DateTime.now().add(duration),
      ),
      'Couldn’t mute the chat. Check private sync and try again.',
    );
  } catch (_) {
    return;
  }
  if (!isCurrent()) return;
  say(
    conversationMuteDone(choice),
    undo: () => NotionMetadataActions.setMuted(personal, entity, muted: false),
  );
}
