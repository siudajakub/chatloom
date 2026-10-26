// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/recording_input_row.dart';
import 'package:chatloom/pages/chat/recording_view_model.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/round_video/messenger_round_gate.dart'
    show roundChatNetworks;
import 'package:chatloom/personal/round_video/round_availability.dart'
    show RoundAvailability;
import 'package:chatloom/personal/round_video/round_outbox_sync.dart';
import 'package:chatloom/personal/round_video/round_record_button.dart';
import 'package:chatloom/personal/stickers/sticker_suggestions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart' show AddPopupMenuActions;
import 'composer_menu.dart';
import 'composer_recipient_notice.dart';
import 'composer_send_later.dart';
import 'conversation_source.dart';
import 'conversation_source_picker.dart' show ConversationSourceHintHost;
import 'input_bar.dart';

/// Which record buttons the composer shows: the voice mic while the editor
/// is empty, not editing and enabled on a platform that records; the round
/// video button beside it when [round] (null outside Android Telegram chats)
/// can record, except while a voice message is held.
@visibleForTesting
({bool voice, bool round}) composerRecordButtons({
  required bool platformCanRecord,
  required bool editing,
  required bool enabled,
  required bool hasText,
  required bool holdingVoice,
  required RoundAvailability? round,
}) {
  final voice = platformCanRecord && !editing && enabled && !hasText;
  return (
    voice: voice,
    round: voice && !holdingVoice && (round?.canRecord ?? false),
  );
}

/// Which attach-menu entries [room]'s network takes (BR-03, FX-12):
/// Telegram's and Messenger's menus offer only what the chat can receive.
/// Everything stays for a room without a bridge declaration (native
/// Matrix); a complete declaration refuses what it omits (no polls outside
/// WhatsApp, no location on Messenger, Instagram or Slack).
@visibleForTesting
({bool media, bool file, bool photo, bool video, bool location, bool poll})
composerAttachOffers(Room room) {
  bool offers(BridgeFeature feature) =>
      RoomCapabilities.composerOffers(room, feature);
  final photo = offers(BridgeFeature.image);
  final video = offers(BridgeFeature.video);
  return (
    media: photo || video,
    file: offers(BridgeFeature.upload),
    photo: photo,
    video: video,
    location: offers(BridgeFeature.location),
    poll: offers(BridgeFeature.poll),
  );
}

/// The composer of a conversation: one room ([ChatController]) or the
/// selected source of a merged person chat.
class ChatInputRow extends StatefulWidget {
  final ConversationComposerHost controller;
  static const double height = 56.0;
  const ChatInputRow(this.controller, {super.key});

  /// Forces the phone attachment sheet (true) or the desktop menu (false).
  @visibleForTesting
  static bool? debugAttachSheet;

  @override
  State<ChatInputRow> createState() => _ChatInputRowState();
}

class _ChatInputRowState extends State<ChatInputRow> {
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

  /// "+" opens the attach menu directly (Telegram's paperclip, Messenger's
  /// "+"): one tap to the combined system photo and video picker. Library
  /// media first, then capture, then structured content; the rare silent
  /// round and the account switch stay last.
  Future<void> _openAttachMenu(BuildContext anchor) async {
    final l10n = L10n.of(context);
    final matrix = Matrix.of(context);
    void pick(AddPopupMenuActions choice) =>
        controller.onAddPopupMenuButtonSelected(choice);
    final offers = composerAttachOffers(controller.room);
    final listed = <ComposerMenuEntry<VoidCallback>>[
      if (offers.media)
        ComposerMenuEntry(
          () => pick(AddPopupMenuActions.gallery),
          Icons.photo_library_outlined,
          'Photo or video',
        ),
      if (offers.file)
        ComposerMenuEntry(
          () => pick(AddPopupMenuActions.file),
          Icons.attachment_outlined,
          l10n.sendFile,
        ),
      if (PlatformInfos.isMobile && (offers.photo || offers.video)) ...[
        const ComposerMenuEntry.divider(),
        if (offers.photo)
          ComposerMenuEntry(
            () => pick(AddPopupMenuActions.photoCamera),
            Icons.camera_alt_outlined,
            l10n.takeAPhoto,
          ),
        if (offers.video)
          ComposerMenuEntry(
            () => pick(AddPopupMenuActions.videoCamera),
            Icons.videocam_outlined,
            l10n.recordAVideo,
          ),
      ],
      if ((PlatformInfos.isMobile && offers.location) || offers.poll)
        const ComposerMenuEntry.divider(),
      if (PlatformInfos.isMobile && offers.location)
        ComposerMenuEntry(
          () => pick(AddPopupMenuActions.location),
          Icons.gps_fixed_outlined,
          l10n.shareLocation,
        ),
      if (offers.poll)
        ComposerMenuEntry(
          () => pick(AddPopupMenuActions.poll),
          Icons.poll_outlined,
          l10n.startPoll,
        ),
      if (controller.canRecordRoundSilently) ...[
        const ComposerMenuEntry.divider(),
        ComposerMenuEntry(
          () => pick(AddPopupMenuActions.roundVideoSilent),
          Icons.notifications_off_outlined,
          'Record a round video silently',
        ),
      ],
      if (controller.allowsAccountSwitch &&
          matrix.isMultiAccount &&
          matrix.hasComplexBundles &&
          matrix.currentBundle!.length > 1) ...[
        const ComposerMenuEntry.divider(),
        ComposerMenuEntry(
          _pickAccount,
          Icons.switch_account_outlined,
          'Send from another account',
        ),
      ],
    ];
    // No divider at an edge or after another (hidden entries).
    final entries = <ComposerMenuEntry<VoidCallback>>[];
    for (final entry in listed) {
      if (entry.isDivider && (entries.isEmpty || entries.last.isDivider)) {
        continue;
      }
      entries.add(entry);
    }
    if (entries.isNotEmpty && entries.last.isDivider) entries.removeLast();
    if (entries.isEmpty) return;
    final run = _attachSheet
        ? await _showAttachSheet(entries)
        : await showComposerMenu<VoidCallback>(
            anchor,
            semanticLabel: 'Attach',
            entries: entries,
          );
    if (!mounted || run == null) return;
    run();
  }

  /// Phones pick attachments from a sheet at the bottom of the screen.
  ///
  /// An anchored menu was positioned from the "+" button's rect at the
  /// moment of the tap. With the keyboard open, the menu route takes focus,
  /// the keyboard closes and the composer drops by the keyboard height, but
  /// the menu stays at the old position high above it. A bottom sheet does
  /// not depend on the button or the keyboard insets.
  bool get _attachSheet =>
      ChatInputRow.debugAttachSheet ?? PlatformInfos.isMobile;

  Future<VoidCallback?> _showAttachSheet(
    List<ComposerMenuEntry<VoidCallback>> entries,
  ) => showNotionSheet<VoidCallback>(
    // Above the whole app, like the menu.
    context: Navigator.of(context, rootNavigator: true).context,
    title: 'Attach',
    builder: (sheetContext) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in entries)
            if (entry.isDivider)
              const NotionGlassDivider(vertical: false)
            else
              NotionGlassMenuRow(
                leading: Icon(entry.icon, size: NotionSize.icon),
                title: entry.label!,
                onTap: () => Navigator.of(sheetContext).pop(entry.value),
              ),
        ],
      ),
    ),
  );

  /// The composer's "+": the attach menu, unavailable while editing.
  Widget _attachButton() {
    final enabled = controller.composerEnabled && controller.editEvent == null;
    return Builder(
      builder: (anchor) => IconButton(
        tooltip: 'Attach media or a file',
        icon: const Icon(Icons.add),
        onPressed: enabled ? () => _openAttachMenu(anchor) : null,
      ),
    );
  }

  /// Long press on Send (Telegram's `onSendLongClick`): Send later or Remind
  /// me, the same flows as the conversation menu. "Send without sound" is
  /// left out: the bridges cannot honour it.
  Future<void> _openSendMenu(BuildContext anchor) async {
    final host = controller;
    if (host is! ComposerSendLaterHost || host.editEvent != null) return;
    NotionHaptics.longPress();
    final run = await showComposerMenu<Future<void> Function()>(
      anchor,
      alignEnd: true,
      semanticLabel: 'Send options',
      entries: [
        ComposerMenuEntry(
          (host as ComposerSendLaterHost).composerSendLater,
          Icons.schedule_outlined,
          'Send later',
        ),
        ComposerMenuEntry(
          (host as ComposerSendLaterHost).composerRemindMe,
          Icons.alarm_outlined,
          'Remind me',
        ),
      ],
    );
    if (!mounted || run == null) return;
    await run();
  }

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

  /// Always beside "+": the emoji toggle (one tap, like Telegram and
  /// Messenger), unchanged in look and behaviour.
  List<ComposerAction> _inlineActions() => [
    ComposerAction(
      icon: controller.showEmojiPicker
          ? Icons.keyboard
          : Icons.add_reaction_outlined,
      label: 'Emoji picker',
      selected: controller.showEmojiPicker,
      onPressed: controller.emojiPickerAction,
    ),
  ];

  /// Round video in this chat, or null outside Telegram and Messenger
  /// chats (Messenger receives it as a square video). Display only:
  /// `TelegramRoundService.captureAndSend` re-checks it.
  RoundAvailability? get _round =>
      PlatformInfos.supportsRoundCapture &&
          roundChatNetworks.contains(PersonalClient.networkOf(controller.room))
      ? controller.roundAvailability
      : null;

  ({bool voice, bool round}) get _recordButtons => composerRecordButtons(
    platformCanRecord: PlatformInfos.platformCanRecord,
    editing: controller.editEvent != null,
    enabled: controller.composerEnabled,
    hasText: controller.sendController.text.trim().isNotEmpty,
    holdingVoice: _holding,
    round: _round,
  );

  /// The round video button beside the mic (see [composerRecordButtons]).
  /// Both stay visible, so there is no voice ↔ video mode to switch and no
  /// notice about switching.
  Widget? _roundAction(({bool voice, bool round}) record) {
    if (!record.round) return null;
    return RoundRecordButton(
      key: const ValueKey('composer-round'),
      onRecord: controller.recordRound,
    );
  }

  /// Each state is keyed so the composer morphs between them (mic ↔ send).
  /// A disabled send button stays the same widget and springs when it
  /// becomes enabled.
  Widget _primary(
    RecordingViewModelState recording,
    ({bool voice, bool round}) record,
  ) {
    final enabled = controller.composerEnabled;
    if (controller.sendController.text.trim().isNotEmpty) {
      final later =
          enabled &&
          controller is ComposerSendLaterHost &&
          controller.editEvent == null;
      return KeyedSubtree(
        key: const ValueKey('primary-send'),
        child: Builder(
          builder: (anchor) => NotionSendButton(
            busy: controller.composerBusy,
            onPressed: enabled ? controller.send : null,
            onLongPress: later ? () => _openSendMenu(anchor) : null,
          ),
        ),
      );
    }
    if (!record.voice) {
      // The same widget shape as the enabled send button above, so the
      // morph updates it in place (one button) instead of cross-fading.
      return KeyedSubtree(
        key: const ValueKey('primary-send'),
        child: Builder(
          builder: (_) => NotionSendButton(busy: controller.composerBusy),
        ),
      );
    }
    final round = _round;
    return VoiceRecordButton(
      key: const ValueKey('primary-voice'),
      hold: _hold,
      // A Telegram chat without round video says why on a quick tap, in the
      // button's small tooltip.
      tapHint: round == null || round.canRecord
          ? VoiceRecordButton.defaultTapHint
          : 'Hold to record a voice message. ${round.reason}',
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

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The composer stays: a calm notice replaces the old blocking text.
        ComposerRecipientNotice(room: controller.room),
        if (PlatformInfos.supportsRoundCapture &&
            roundChatNetworks.contains(
              PersonalClient.networkOf(controller.room),
            ))
          RoundOutboxSync(room: controller.room),
        // Telegram: a single emoji suggests matching stickers.
        StickerSuggestionStrip(host: controller),
        RecordingViewModel(
          builder: (context, recordingViewModel) {
            // A held recording keeps the composer (and this pointer) mounted.
            // The recorder rises into the composer's place (one-shot,
            // settles to identity).
            if (recordingViewModel.isRecording && !_hold.capturing) {
              return NotionEntrance(
                afterRoute: false,
                child: RecordingInputRow(
                  state: recordingViewModel,
                  onSend: controller.onVoiceMessageSend,
                ),
              );
            }
            final record = _recordButtons;
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
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    counter: const SizedBox.shrink(),
                    // A merged chat names the network it sends through.
                    hintText: switch (controller) {
                      ConversationSourceHintHost(:final composerHint) =>
                        composerHint,
                      _ => 'Message…',
                    },
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
                addAction: _attachButton(),
                inlineActions: _inlineActions(),
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
                    // Recording samples tick only the overlay's clock.
                    ? ListenableBuilder(
                        listenable: recordingViewModel.samples,
                        builder: (context, _) => VoiceRecordHoldOverlay(
                          hold: _hold,
                          duration: recordingViewModel.elapsed,
                        ),
                      )
                    : null,
                source: controller.buildComposerSource(context),
                secondaryAction: _roundAction(record),
                primaryAction: _primary(recordingViewModel, record),
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
