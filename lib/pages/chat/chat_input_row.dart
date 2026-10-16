// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/pages/chat/compact_composer.dart';
import 'package:fluffychat/pages/chat/recording_input_row.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart'
    show personalDate, schedulePersonalAttachment;
import 'package:fluffychat/personal/scheduled_composer.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';
import 'package:fluffychat/personal/round_video/round_outbox_panel.dart';
import 'package:fluffychat/personal/round_video/round_record_button.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/other_party_can_receive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart';
import 'input_bar.dart';

class ChatInputRow extends StatelessWidget {
  final ChatController controller;
  static const double height = 56.0;
  const ChatInputRow(this.controller, {super.key});

  Future<void> _schedule(BuildContext context, {bool media = false}) async {
    final room = controller.room;
    final personal = PersonalClient.of(room.client);
    final text = controller.sendController.text;
    try {
      final frozen = FrozenScheduledComposer.capture(
        room: room,
        target: SendTarget(
          conversation: personal.ref(room),
          readUpToEventId: controller.personalSeenEventId,
        ),
        reply: controller.replyEvent,
        editing: controller.editEvent != null,
        threadRootEventId: controller.activeThreadId,
        threadLastEventId: controller.threadLastEventId,
        isCurrent: () =>
            context.mounted &&
            controller.mounted &&
            identical(controller.room, room) &&
            identical(Matrix.of(context).client, room.client),
      );
      bool sameContext() =>
          context.mounted &&
          controller.mounted &&
          identical(controller.room, room) &&
          frozen.matchesContext(
            reply: controller.replyEvent,
            editing: controller.editEvent != null,
            threadRootEventId: controller.activeThreadId,
            threadLastEventId: controller.threadLastEventId,
          );
      await personal.load();
      if (!context.mounted || !sameContext()) return;
      if (media) {
        await schedulePersonalAttachment(
          context,
          personal,
          frozen.target,
          composeContext: frozen,
        );
        return;
      }
      if (text.trim().isEmpty) return;
      final due = await personalDate(context);
      if (due == null || !context.mounted) return;
      frozen.validateCurrent();
      if (!due.isAfter(DateTime.now())) return;
      final id = const Uuid().v4();
      await personal.schedule(
        ScheduledSend(
          id: id,
          target: frozen.target,
          dueAt: due,
          content: frozen.content({'msgtype': 'm.text', 'body': text}),
          transactionId: 'schedule-$id',
        ),
      );
      if (sameContext() && controller.sendController.text == text) {
        await personal.saveDraft(room, '');
        if (sameContext() && controller.sendController.text == text) {
          controller.sendController.clear();
          controller.cancelReplyEventAction();
        } else if (sameContext()) {
          await personal.saveDraft(room, controller.sendController.text);
        }
      }
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Scheduling was not confirmed. Your draft is preserved.',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!controller.room.otherPartyCanReceiveMessages) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          L10n.of(context).otherPartyNotLoggedIn,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final selectedTextButtonStyle = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onSurface,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (PlatformInfos.isAndroid &&
            PersonalClient.networkOf(controller.room) == 'telegram')
          RoundOutboxPanel(room: controller.room),
        RecordingViewModel(
          builder: (context, recordingViewModel) {
            if (recordingViewModel.isRecording) {
              return RecordingInputRow(
                state: recordingViewModel,
                onSend: controller.onVoiceMessageSend,
              );
            }
            if (controller.selectMode)
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (controller.selectedEvents.every(
                    (event) => event.status == EventStatus.error,
                  ))
                    SizedBox(
                      height: height,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: controller.deleteErrorEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.delete_forever_outlined),
                            Text(L10n.of(context).delete),
                          ],
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: height,
                      child: TextButton(
                        style: selectedTextButtonStyle,
                        onPressed: controller.forwardEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.keyboard_arrow_left_outlined),
                            Text(L10n.of(context).forward),
                          ],
                        ),
                      ),
                    ),
                  controller.selectedEvents.length == 1
                      ? controller.selectedEvents.first
                                .getDisplayEvent(controller.timeline!)
                                .status
                                .isSent
                            ? SizedBox(
                                height: height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.replyAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).reply),
                                      const Icon(Icons.keyboard_arrow_right),
                                    ],
                                  ),
                                ),
                              )
                            : SizedBox(
                                height: height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.sendAgainAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).tryToSendAgain),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.send_outlined, size: 16),
                                    ],
                                  ),
                                ),
                              )
                      : const SizedBox.shrink(),
                ],
              );
            return TextFieldTapRegion(
              child: CompactComposer(
                input: InputBar(
                  room: controller.room,
                  minLines: 1,
                  maxLines: conversationComposerMaxLines(
                    context,
                    hasContext:
                        controller.replyEvent != null ||
                        controller.editEvent != null,
                  ),
                  autofocus: !PlatformInfos.isMobile,
                  keyboardType: TextInputType.multiline,
                  textInputAction:
                      AppSettings.sendOnEnter.value && PlatformInfos.isMobile
                      ? TextInputAction.send
                      : null,
                  onSubmitted: controller.onInputBarSubmitted,
                  onSubmitImage: controller.sendImageFromClipBoard,
                  focusNode: controller.inputFocus,
                  controller: controller.sendController,
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    counter: SizedBox.shrink(),
                    hintText: 'Message…',
                    hintMaxLines: 1,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                  onChanged: controller.onInputBarChanged,
                  suggestionEmojis:
                      getDefaultEmojiLocale(
                        AppSettings.emojiSuggestionLocale.value.isNotEmpty
                            ? Locale(AppSettings.emojiSuggestionLocale.value)
                            : Localizations.localeOf(context),
                      ).fold(
                        [],
                        (emojis, category) => emojis..addAll(category.emoji),
                      ),
                ),
                addAction: IconButton(
                  tooltip: 'More message actions',
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (controller.editEvent == null)
                              PopupMenuButton<AddPopupMenuActions>(
                                useRootNavigator: true,
                                tooltip: 'Attach media or a file',
                                icon: const Icon(Icons.attach_file_outlined),
                                iconColor: theme.colorScheme.onSurfaceVariant,
                                onSelected: (choice) {
                                  Navigator.of(context).pop();
                                  controller.onAddPopupMenuButtonSelected(
                                    choice,
                                  );
                                },
                                itemBuilder: (BuildContext context) => [
                                  if (controller.canRecordRoundSilently)
                                    const PopupMenuItem(
                                      value:
                                          AddPopupMenuActions.roundVideoSilent,
                                      child: ListTile(
                                        leading: Icon(
                                          Icons.notifications_off_outlined,
                                        ),
                                        title: Text(
                                          'Record a round video silently',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  if (PlatformInfos.isMobile)
                                    PopupMenuItem(
                                      value: AddPopupMenuActions.location,
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          backgroundColor: theme
                                              .colorScheme
                                              .onPrimaryContainer,
                                          foregroundColor: theme
                                              .colorScheme
                                              .primaryContainer,
                                          child: const Icon(
                                            Icons.gps_fixed_outlined,
                                          ),
                                        ),
                                        title: Text(
                                          L10n.of(context).shareLocation,
                                        ),
                                        contentPadding: const EdgeInsets.all(0),
                                      ),
                                    ),
                                  PopupMenuItem(
                                    value: AddPopupMenuActions.poll,
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: theme
                                            .colorScheme
                                            .onPrimaryContainer,
                                        foregroundColor:
                                            theme.colorScheme.primaryContainer,
                                        child: const Icon(Icons.poll_outlined),
                                      ),
                                      title: Text(L10n.of(context).startPoll),
                                      contentPadding: const EdgeInsets.all(0),
                                    ),
                                  ),
                                  PopupMenuDivider(),
                                  if (PlatformInfos.isMobile) ...[
                                    PopupMenuItem(
                                      value: AddPopupMenuActions.videoCamera,
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          backgroundColor: theme
                                              .colorScheme
                                              .onPrimaryContainer,
                                          foregroundColor: theme
                                              .colorScheme
                                              .primaryContainer,
                                          child: const Icon(
                                            Icons.videocam_outlined,
                                          ),
                                        ),
                                        title: Text(
                                          L10n.of(context).recordAVideo,
                                        ),
                                        contentPadding: const EdgeInsets.all(0),
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: AddPopupMenuActions.photoCamera,
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          backgroundColor: theme
                                              .colorScheme
                                              .onPrimaryContainer,
                                          foregroundColor: theme
                                              .colorScheme
                                              .primaryContainer,
                                          child: const Icon(
                                            Icons.camera_alt_outlined,
                                          ),
                                        ),
                                        title: Text(
                                          L10n.of(context).takeAPhoto,
                                        ),
                                        contentPadding: const EdgeInsets.all(0),
                                      ),
                                    ),
                                    PopupMenuDivider(),
                                  ],
                                  PopupMenuItem(
                                    value: AddPopupMenuActions.video,
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: theme
                                            .colorScheme
                                            .onPrimaryContainer,
                                        foregroundColor:
                                            theme.colorScheme.primaryContainer,
                                        child: const Icon(Icons.movie_outlined),
                                      ),
                                      title: Text(L10n.of(context).sendVideo),
                                      contentPadding: const EdgeInsets.all(0),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: AddPopupMenuActions.image,
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: theme
                                            .colorScheme
                                            .onPrimaryContainer,
                                        foregroundColor:
                                            theme.colorScheme.primaryContainer,
                                        child: const Icon(Icons.image_outlined),
                                      ),
                                      title: Text(L10n.of(context).sendImage),
                                      contentPadding: const EdgeInsets.all(0),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: AddPopupMenuActions.file,
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: theme
                                            .colorScheme
                                            .onPrimaryContainer,
                                        foregroundColor:
                                            theme.colorScheme.primaryContainer,
                                        child: const Icon(
                                          Icons.attachment_outlined,
                                        ),
                                      ),
                                      title: Text(L10n.of(context).sendFile),
                                      contentPadding: const EdgeInsets.all(0),
                                    ),
                                  ),
                                ],
                              ),
                            if (PlatformInfos.isAndroid &&
                                PersonalClient.networkOf(controller.room) ==
                                    'telegram' &&
                                controller.sendController.text.isEmpty &&
                                controller.editEvent == null)
                              NotionIconButton(
                                icon: controller.roundRecordingMode
                                    ? Icons.mic_none_outlined
                                    : Icons.videocam_outlined,
                                label: controller.roundRecordingMode
                                    ? 'Switch to voice messages'
                                    : 'Switch to round video',
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  controller.toggleRoundRecordingMode();
                                },
                              ),
                            PopupMenuButton<bool>(
                              tooltip: 'Schedule a message',
                              icon: const Icon(Icons.schedule_outlined),
                              enabled: controller.editEvent == null,
                              onSelected: (media) {
                                Navigator.of(context).pop();
                                _schedule(context, media: media);
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: false,
                                  enabled: controller.sendController.text
                                      .trim()
                                      .isNotEmpty,
                                  child: const Text('Schedule text'),
                                ),
                                const PopupMenuItem(
                                  value: true,
                                  child: Text('Schedule an attachment'),
                                ),
                              ],
                            ),
                            NotionIconButton(
                              icon: controller.showEmojiPicker
                                  ? Icons.keyboard
                                  : Icons.add_reaction_outlined,
                              label: 'Emoji picker',
                              onPressed: () {
                                Navigator.of(context).pop();
                                controller.emojiPickerAction();
                              },
                            ),
                            if (Matrix.of(context).isMultiAccount &&
                                Matrix.of(context).hasComplexBundles &&
                                Matrix.of(context).currentBundle!.length > 1)
                              SizedBox(
                                width: 48,
                                height: 48,
                                child: _ChatAccountPicker(controller),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                ),
                source: ConversationSourceChip(
                  network: PersonalClient.networkOf(controller.room),
                  locked: controller.replyEvent != null,
                ),
                primaryAction: controller.sendController.text.trim().isNotEmpty
                    ? NotionSendButton(onPressed: controller.send)
                    : PlatformInfos.platformCanRecord &&
                          controller.editEvent == null
                    ? controller.roundRecordingMode
                          ? RoundRecordButton(onRecord: controller.recordRound)
                          : IconButton(
                              tooltip: 'Record a voice message',
                              onPressed: () => recordingViewModel
                                  .startRecording(controller.room),
                              onLongPress: () => recordingViewModel
                                  .startRecording(controller.room),
                              icon: const Icon(Icons.mic_none_outlined),
                            )
                    : const NotionSendButton(),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ChatAccountPicker extends StatelessWidget {
  final ChatController controller;

  const _ChatAccountPicker(this.controller);

  void _popupMenuButtonSelected(String mxid, BuildContext context) {
    final client = Matrix.of(
      context,
    ).currentBundle!.firstWhere((cl) => cl!.userID == mxid, orElse: () => null);
    if (client == null) {
      Logs().w('Attempted to switch to a non-existing client $mxid');
      return;
    }
    Navigator.of(context).pop();
    controller.setSendingClient(client);
  }

  @override
  Widget build(BuildContext context) {
    final clients = controller.currentRoomBundle;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: FutureBuilder<Profile>(
        future: controller.sendingClient.fetchOwnProfile(),
        builder: (context, snapshot) => PopupMenuButton<String>(
          useRootNavigator: true,
          onSelected: (mxid) => _popupMenuButtonSelected(mxid, context),
          itemBuilder: (BuildContext context) => clients
              .map(
                (client) => PopupMenuItem(
                  value: client!.userID,
                  child: FutureBuilder<Profile>(
                    future: client.fetchOwnProfile(),
                    builder: (context, snapshot) => ListTile(
                      leading: Avatar(
                        mxContent: snapshot.data?.avatarUrl,
                        name:
                            snapshot.data?.displayName ??
                            client.userID!.localpart,
                        size: 20,
                      ),
                      title: Text(snapshot.data?.displayName ?? client.userID!),
                      contentPadding: const EdgeInsets.all(0),
                    ),
                  ),
                ),
              )
              .toList(),
          child: Avatar(
            mxContent: snapshot.data?.avatarUrl,
            name:
                snapshot.data?.displayName ??
                Matrix.of(context).client.userID!.localpart,
            size: 20,
          ),
        ),
      ),
    );
  }
}
