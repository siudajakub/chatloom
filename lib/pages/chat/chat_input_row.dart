// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/recording_input_row.dart';
import 'package:chatloom/pages/chat/recording_view_model.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/round_video/round_outbox_panel.dart';
import 'package:chatloom/personal/round_video/round_record_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/other_party_can_receive.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart' show AddPopupMenuActions;
import 'conversation_source.dart';
import 'input_bar.dart';

/// The composer of a conversation: one room ([ChatController]) or the
/// selected source of a merged person chat.
class ChatInputRow extends StatefulWidget {
  final ConversationComposerHost controller;
  static const double height = 56.0;
  const ChatInputRow(this.controller, {super.key});

  @override
  State<ChatInputRow> createState() => _ChatInputRowState();
}

class _ChatInputRowState extends State<ChatInputRow> {
  static const double height = ChatInputRow.height;
  final VoiceRecordHold _hold = VoiceRecordHold();
  bool _holding = false;

  ConversationComposerHost get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _hold.addListener(_holdChanged);
  }

  @override
  void dispose() {
    _hold.removeListener(_holdChanged);
    _hold.dispose();
    super.dispose();
  }

  /// Only hold start/end rebuild the row; drag progress repaints the overlay.
  void _holdChanged() {
    final holding = _hold.capturing;
    if (holding != _holding && mounted) setState(() => _holding = holding);
  }

  PopupMenuItem<AddPopupMenuActions> _attachItem(
    AddPopupMenuActions value,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: value,
    child: ListTile(
      leading: Icon(icon, size: NotionSize.icon),
      title: Text(label),
      contentPadding: EdgeInsets.zero,
    ),
  );

  Widget _attachMenu(BuildContext context, VoidCallback used) =>
      PopupMenuButton<AddPopupMenuActions>(
        useRootNavigator: true,
        tooltip: 'Attach media or a file',
        icon: const Icon(Icons.attach_file_outlined, size: NotionSize.iconMd),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(NotionSize.touchTarget),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          shape: NotionShapes.pill,
        ),
        onSelected: (choice) {
          used();
          controller.onAddPopupMenuButtonSelected(choice);
        },
        // Library media first, then capture, then structured content; the
        // rare silent round stays last.
        itemBuilder: (BuildContext context) => [
          _attachItem(
            AddPopupMenuActions.image,
            Icons.image_outlined,
            L10n.of(context).sendImage,
          ),
          _attachItem(
            AddPopupMenuActions.video,
            Icons.movie_outlined,
            L10n.of(context).sendVideo,
          ),
          _attachItem(
            AddPopupMenuActions.file,
            Icons.attachment_outlined,
            L10n.of(context).sendFile,
          ),
          if (PlatformInfos.isMobile) ...[
            const PopupMenuDivider(),
            _attachItem(
              AddPopupMenuActions.photoCamera,
              Icons.camera_alt_outlined,
              L10n.of(context).takeAPhoto,
            ),
            _attachItem(
              AddPopupMenuActions.videoCamera,
              Icons.videocam_outlined,
              L10n.of(context).recordAVideo,
            ),
          ],
          const PopupMenuDivider(),
          if (PlatformInfos.isMobile)
            _attachItem(
              AddPopupMenuActions.location,
              Icons.gps_fixed_outlined,
              L10n.of(context).shareLocation,
            ),
          _attachItem(
            AddPopupMenuActions.poll,
            Icons.poll_outlined,
            L10n.of(context).startPoll,
          ),
          if (controller.canRecordRoundSilently) ...[
            const PopupMenuDivider(),
            _attachItem(
              AddPopupMenuActions.roundVideoSilent,
              Icons.notifications_off_outlined,
              'Record a round video silently',
            ),
          ],
        ],
      );

  /// Opens the sending-account menu above the composer.
  Future<void> _pickAccount() async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final mxid = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        origin & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final client in controller.currentRoomBundle)
          if (client?.userID != null)
            PopupMenuItem(
              value: client!.userID,
              child: _AccountMenuEntry(client),
            ),
      ],
    );
    if (mxid == null || !mounted) return;
    final client = Matrix.of(
      context,
    ).currentBundle!.firstWhere((cl) => cl!.userID == mxid, orElse: () => null);
    if (client == null) {
      Logs().w('Attempted to switch to a non-existing client $mxid');
      return;
    }
    controller.setSendingClient(client);
  }

  List<ComposerAction> _actions(BuildContext context) {
    final matrix = Matrix.of(context);
    // Round video has no separate toggle: like Telegram, a tap on the record
    // button switches voice ↔ video (see [_primary]).
    return [
      if (controller.editEvent == null)
        ComposerAction(
          icon: Icons.attach_file_outlined,
          label: 'Attach media or a file',
          anchor: _attachMenu,
        ),
      ComposerAction(
        icon: controller.showEmojiPicker
            ? Icons.keyboard
            : Icons.add_reaction_outlined,
        label: 'Emoji picker',
        selected: controller.showEmojiPicker,
        onPressed: controller.emojiPickerAction,
      ),
      if (controller.allowsAccountSwitch &&
          matrix.isMultiAccount &&
          matrix.hasComplexBundles &&
          matrix.currentBundle!.length > 1)
        ComposerAction(
          icon: Icons.switch_account_outlined,
          label: 'Send from another account',
          onPressed: _pickAccount,
        ),
    ];
  }

  /// Each state is keyed so the composer morphs between them (mic ↔ send,
  /// voice ↔ round). A disabled send button stays the same widget and
  /// springs when it becomes enabled.
  Widget _primary(RecordingViewModelState recording) {
    final enabled = controller.composerEnabled;
    if (controller.sendController.text.trim().isNotEmpty) {
      return NotionSendButton(
        key: const ValueKey('primary-send'),
        busy: controller.composerBusy,
        onPressed: enabled ? controller.send : null,
      );
    }
    if (!PlatformInfos.platformCanRecord ||
        controller.editEvent != null ||
        !enabled) {
      return NotionSendButton(
        key: const ValueKey('primary-send'),
        busy: controller.composerBusy,
      );
    }
    // Telegram's single record button: a tap switches voice ↔ video when
    // round video is available here, a hold records in the current mode.
    final round =
        PlatformInfos.isAndroid &&
            PersonalClient.networkOf(controller.room) == 'telegram'
        ? controller.roundAvailability
        : null;
    if (controller.roundRecordingMode) {
      return RoundRecordButton(
        key: const ValueKey('primary-round'),
        onRecord: controller.recordRound,
        onToggleMode: () => _switchRecordMode(video: false),
      );
    }
    return VoiceRecordButton(
      key: const ValueKey('primary-voice'),
      hold: _hold,
      onToggleMode: round != null && round.canRecord
          ? () => _switchRecordMode(video: true)
          : null,
      // Unavailable round video explains why on the same tap.
      onTapHint: () => showComposerNotice(
        context,
        round == null || round.canRecord
            ? 'Hold to record a voice message, release to send.'
            : 'Hold to record a voice message. ${round.message}',
      ),
      recorded: () => recording.elapsed,
      onStart: () async {
        await recording.startRecording(controller.room);
        return recording.mounted &&
            recording.isRecording &&
            !recording.isStarting;
      },
      onSend: () => recording.stopAndSend(controller.onVoiceMessageSend),
      onCancel: () {
        if (recording.mounted) recording.cancel();
      },
    );
  }

  /// Persists the mode (global setting) and says how to record in it.
  void _switchRecordMode({required bool video}) {
    unawaited(controller.toggleRoundRecordingMode());
    showComposerNotice(
      context,
      video
          ? 'Hold to record a video message. Tap to switch to voice.'
          : 'Hold to record a voice message. Tap to switch to video.',
    );
  }

  Event _displayOf(Event event) {
    final timeline = controller.timelineFor(event);
    return timeline == null ? event : event.getDisplayEvent(timeline);
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
            // A held recording keeps the composer (and this pointer) mounted.
            // The recorder and the selection actions rise into the
            // composer's place (one-shot, settles to identity).
            if (recordingViewModel.isRecording && !_hold.capturing) {
              return NotionEntrance(
                afterRoute: false,
                child: RecordingInputRow(
                  state: recordingViewModel,
                  onSend: controller.onVoiceMessageSend,
                ),
              );
            }
            if (controller.selectMode) {
              return NotionEntrance(
                afterRoute: false,
                child: Row(
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
                        ? _displayOf(
                                controller.selectedEvents.first,
                              ).status.isSent
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
                                        const Icon(
                                          Icons.send_outlined,
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                        : const SizedBox.shrink(),
                  ],
                ),
              );
            }
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
                actions: _actions(context),
                actionsEnabled: controller.composerEnabled,
                collapseOnText: controller.sendController,
                collapseToken: Object.hash(
                  controller.room.id,
                  controller.sendingClient.userID,
                  controller.replyEvent?.eventId,
                  controller.editEvent?.eventId,
                  _holding,
                ),
                inputOverlay: _hold.capturing
                    ? VoiceRecordHoldOverlay(
                        hold: _hold,
                        duration: recordingViewModel.elapsed,
                      )
                    : null,
                source: controller.buildComposerSource(context),
                primaryAction: _primary(recordingViewModel),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _AccountMenuEntry extends StatelessWidget {
  final Client client;
  const _AccountMenuEntry(this.client);

  @override
  Widget build(BuildContext context) => FutureBuilder<Profile>(
    future: client.fetchOwnProfile(),
    builder: (context, snapshot) => ListTile(
      leading: Avatar(
        mxContent: snapshot.data?.avatarUrl,
        name: snapshot.data?.displayName ?? client.userID!.localpart,
        size: NotionSize.avatarSm,
      ),
      title: Text(snapshot.data?.displayName ?? client.userID!),
      contentPadding: EdgeInsets.zero,
    ),
  );
}
