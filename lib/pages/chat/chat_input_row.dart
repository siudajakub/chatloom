// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/pages/chat/recording_input_row.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:fluffychat/personal/round_video/round_outbox_panel.dart';
import 'package:fluffychat/personal/round_video/round_record_button.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/other_party_can_receive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart';
import 'input_bar.dart';

class ChatInputRow extends StatelessWidget {
  final ChatController controller;
  static const double height = 56.0;
  const ChatInputRow(this.controller, {super.key});

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
            return NotionComposer(
              input: InputBar(
                room: controller.room,
                minLines: 1,
                maxLines: 6,
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
                  hintText: 'Write a message…',
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
              actions: [
                if (controller.editEvent == null)
                  PopupMenuButton<AddPopupMenuActions>(
                    useRootNavigator: true,
                    tooltip: 'Attach media or a file',
                    icon: const Icon(Icons.attach_file_outlined),
                    iconColor: theme.colorScheme.onSurfaceVariant,
                    onSelected: controller.onAddPopupMenuButtonSelected,
                    itemBuilder: (BuildContext context) => [
                      if (controller.canRecordRoundSilently)
                        const PopupMenuItem(
                          value: AddPopupMenuActions.roundVideoSilent,
                          child: ListTile(
                            leading: Icon(Icons.notifications_off_outlined),
                            title: Text('Record a round video silently'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      if (PlatformInfos.isMobile)
                        PopupMenuItem(
                          value: AddPopupMenuActions.location,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              foregroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.gps_fixed_outlined),
                            ),
                            title: Text(L10n.of(context).shareLocation),
                            contentPadding: const EdgeInsets.all(0),
                          ),
                        ),
                      PopupMenuItem(
                        value: AddPopupMenuActions.poll,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
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
                              backgroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              foregroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.videocam_outlined),
                            ),
                            title: Text(L10n.of(context).recordAVideo),
                            contentPadding: const EdgeInsets.all(0),
                          ),
                        ),
                        PopupMenuItem(
                          value: AddPopupMenuActions.photoCamera,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              foregroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.camera_alt_outlined),
                            ),
                            title: Text(L10n.of(context).takeAPhoto),
                            contentPadding: const EdgeInsets.all(0),
                          ),
                        ),
                        PopupMenuDivider(),
                      ],
                      PopupMenuItem(
                        value: AddPopupMenuActions.video,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
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
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
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
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
                            child: const Icon(Icons.attachment_outlined),
                          ),
                          title: Text(L10n.of(context).sendFile),
                          contentPadding: const EdgeInsets.all(0),
                        ),
                      ),
                    ],
                  ),
                if (PlatformInfos.platformCanRecord &&
                    controller.sendController.text.isEmpty &&
                    controller.editEvent == null)
                  if (controller.roundRecordingMode)
                    RoundRecordButton(onRecord: controller.recordRound)
                  else
                    HoverBuilder(
                      builder: (context, hovered) => IconButton(
                        tooltip: 'Record a voice message',
                        onPressed: hovered
                            ? () => recordingViewModel.startRecording(
                                controller.room,
                              )
                            : () => ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  showCloseIcon: true,
                                  content: Text(
                                    L10n.of(
                                      context,
                                    ).longPressToRecordVoiceMessage,
                                  ),
                                ),
                              ),
                        onLongPress: () =>
                            recordingViewModel.startRecording(controller.room),
                        icon: const Icon(Icons.mic_none_outlined),
                      ),
                    ),
                if (PlatformInfos.isAndroid &&
                    PersonalClient.networkOf(controller.room) == 'telegram' &&
                    controller.sendController.text.isEmpty &&
                    controller.editEvent == null)
                  NotionIconButton(
                    icon: controller.roundRecordingMode
                        ? Icons.mic_none_outlined
                        : Icons.videocam_outlined,
                    label: controller.roundRecordingMode
                        ? 'Switch to voice messages'
                        : 'Switch to round video',
                    onPressed: controller.toggleRoundRecordingMode,
                  ),
                NotionIconButton(
                  icon: controller.showEmojiPicker
                      ? Icons.keyboard
                      : Icons.add_reaction_outlined,
                  label: 'Emoji picker',
                  onPressed: controller.emojiPickerAction,
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
              source: Text(
                notionNetworkLabel(PersonalClient.networkOf(controller.room)),
                style: NotionTokens.caption.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              sendAction: NotionSendButton(
                onPressed: controller.sendController.text.trim().isEmpty
                    ? null
                    : controller.send,
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
