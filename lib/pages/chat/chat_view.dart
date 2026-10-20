// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' as ui;

import 'package:async/async.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_list_tile.dart';
import 'package:chatloom/pages/chat/chat_app_bar_title.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/pinned_events.dart';
import 'package:chatloom/pages/chat/reply_display.dart';
import 'package:chatloom/pages/chat/undecryptable_chat_hint.dart';
import 'package:chatloom/pages/chat/undecryptable_fix_sheet.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:chatloom/utils/sync_status_localization.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:chatloom/widgets/pulsating_widget.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../utils/stream_extension.dart';
import 'chat_emoji_picker.dart';
import 'chat_input_row.dart';

enum _EventContextAction { info, report }

class ChatView extends StatelessWidget {
  final ChatController controller;

  const ChatView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasActiveGroupCall = controller.room.hasActiveMatrixRtcCall;
    if (controller.room.membership == Membership.invite) {
      showFutureLoadingDialog(
        context: context,
        future: () => controller.room.join(),
        exceptionContext: ExceptionContext.joinRoom,
      );
    }
    final bottomSheetPadding = ChatLoomThemes.isColumnMode(context) ? 16.0 : 12.0;
    final scrollUpBannerEventId = controller.scrollUpBannerEventId;

    final accountConfig = Matrix.of(context).client.applicationAccountConfig;

    return PopScope(
      canPop:
          controller.selectedEvents.isEmpty &&
          !controller.showEmojiPicker &&
          controller.activeThreadId == null,
      onPopInvokedWithResult: (pop, _) async {
        if (pop) return;
        if (controller.selectedEvents.isNotEmpty) {
          controller.clearSelectedEvents();
        } else if (controller.showEmojiPicker) {
          controller.emojiPickerAction();
        } else if (controller.activeThreadId != null) {
          controller.closeThread();
        }
      },
      child: FutureBuilder(
        future: controller.loadTimelineFuture,
        builder: (BuildContext context, snapshot) {
          // Built once per controller rebuild and handed to the room-state
          // listener as a stable child: room-state and sync-status ticks only
          // rebuild the chrome (app bar, notice, composer), never the timeline.
          final timelineBody = GestureDetector(
            onTap: controller.clearSingleSelectedEvent,
            child: snapshot.hasError && controller.timeline == null
                ? ChatTimelineLoadError(onRetry: controller.retryLoadTimeline)
                : ChatEventList(controller: controller),
          );
          return ChatRoomSignals(
            room: controller.room,
            child: timelineBody,
            builder: (context, timelineBody) {
              final scheduledSource = controller.room;
              final sync = controller.room.client.onSyncStatus.value;
              final showSyncNotice = chatSyncNoticeVisible(
                controller.room.client,
              );
              final syncHeight = showSyncNotice
                  ? 32.0 * MediaQuery.textScalerOf(context).scale(1)
                  : 0.0;
              var appbarBottomHeight = syncHeight;
              final activeThreadId = controller.activeThreadId;
              // Rows the list shows that still wait for a key; brand-new ones
              // get a moment for a key already on its way.
              final locked = (controller.timeline?.events ?? const <Event>[])
                  .filterByVisibleInGui(threadId: activeThreadId)
                  .where(isUndecryptable)
                  .toList();
              final lockedCount = UndecryptableMessages.settledCount(locked);
              if (lockedCount > 0) {
                appbarBottomHeight += UndecryptableChatHint.heightFor(
                  MediaQuery.textScalerOf(context),
                );
              }
              if (activeThreadId != null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              if (controller.room.pinnedEventIds.isNotEmpty &&
                  activeThreadId == null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              if (scrollUpBannerEventId != null && activeThreadId == null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              final chatBackground = InboxProjection(
                PersonalClient.of(controller.room.client),
              ).metadataFor(controller.room).theme?.backgroundColor;
              return Scaffold(
                key: Key('chat_page'),
                backgroundColor: chatBackground == null
                    ? null
                    : Color(chatBackground),
                // Timeline scrolls under the glass header (DESIGN.md "Glass").
                extendBodyBehindAppBar: true,
                appBar: AppBar(
                  actionsIconTheme: IconThemeData(
                    color: controller.selectedEvents.isEmpty
                        ? null
                        : theme.colorScheme.onTertiaryContainer,
                  ),
                  backgroundColor: Colors.transparent,
                  flexibleSpace: NotionGlassBar(
                    tint: controller.selectedEvents.isEmpty
                        ? controller.activeThreadId != null
                              ? theme.colorScheme.secondaryContainer
                              : null
                        : theme.colorScheme.tertiaryContainer,
                  ),
                  toolbarHeight: NotionTokens.headerHeight,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  shape: Border(
                    bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  automaticallyImplyLeading: false,
                  leading: controller.selectMode
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: controller.clearSelectedEvents,
                          tooltip: L10n.of(context).close,
                          color: theme.colorScheme.onTertiaryContainer,
                        )
                      : activeThreadId != null
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: controller.closeThread,
                          tooltip: L10n.of(context).backToMainChat,
                          color: theme.colorScheme.onSecondaryContainer,
                        )
                      : ChatLoomThemes.isColumnMode(context)
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.chevron_left),
                          tooltip: 'Back',
                          onPressed: () => Navigator.maybePop(context),
                        ),
                  titleSpacing: ChatLoomThemes.isColumnMode(context) ? 24 : 0,
                  title: ChatAppBarTitle(controller),
                  // Selection and chat actions cross-fade instead of
                  // swapping in one frame.
                  actions: [
                    NotionFadeThrough(
                      duration: NotionMotion.short,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Row(
                        key: ValueKey(controller.selectMode),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.selectMode) ...[
                            if (controller.canEditSelectedEvents)
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: L10n.of(context).edit,
                                onPressed: controller.editSelectedEventAction,
                              ),
                            if (controller.selectedEvents.length == 1 &&
                                controller.activeThreadId == null &&
                                controller.room.canSendDefaultMessages)
                              IconButton(
                                icon: const Icon(Icons.message_outlined),
                                tooltip: L10n.of(context).replyInThread,
                                onPressed: () => controller.enterThread(
                                  controller.selectedEvents.single.eventId,
                                ),
                              ),
                            IconButton(
                              icon: const Icon(Icons.copy_outlined),
                              tooltip: L10n.of(context).copyToClipboard,
                              onPressed: controller.copyEventsAction,
                            ),
                            if (controller.canRedactSelectedEvents)
                              IconButton(
                                icon: const Icon(Icons.delete_outlined),
                                tooltip: L10n.of(context).redactMessage,
                                onPressed: controller.redactEventsAction,
                              ),
                            if (controller.selectedEvents.length == 1)
                              PopupMenuButton<_EventContextAction>(
                                useRootNavigator: true,
                                onSelected: (action) {
                                  switch (action) {
                                    case _EventContextAction.info:
                                      controller.showEventInfo();
                                      controller.clearSelectedEvents();
                                      break;
                                    case _EventContextAction.report:
                                      controller.reportEventAction();
                                      break;
                                  }
                                },
                                itemBuilder: (context) => [
                                  if (controller.canPinSelectedEvents)
                                    PopupMenuItem(
                                      onTap: controller.pinEvent,
                                      value: null,
                                      child: Row(
                                        mainAxisSize: .min,
                                        children: [
                                          const Icon(Icons.push_pin_outlined),
                                          const SizedBox(width: 12),
                                          Text(L10n.of(context).pinMessage),
                                        ],
                                      ),
                                    ),
                                  if (controller.canSaveSelectedEvent)
                                    PopupMenuItem(
                                      onTap: () =>
                                          controller.saveSelectedEvent(context),
                                      value: null,
                                      child: Row(
                                        mainAxisSize: .min,
                                        children: [
                                          const Icon(Icons.download_outlined),
                                          const SizedBox(width: 12),
                                          Text(L10n.of(context).downloadFile),
                                        ],
                                      ),
                                    ),
                                  PopupMenuItem(
                                    value: _EventContextAction.info,
                                    child: Row(
                                      mainAxisSize: .min,
                                      children: [
                                        const Icon(Icons.info_outlined),
                                        const SizedBox(width: 12),
                                        Text(L10n.of(context).messageInfo),
                                      ],
                                    ),
                                  ),
                                  if (controller
                                      .selectedEvents
                                      .single
                                      .status
                                      .isSent)
                                    PopupMenuItem(
                                      value: _EventContextAction.report,
                                      child: Row(
                                        mainAxisSize: .min,
                                        children: [
                                          const Icon(
                                            Icons.shield_outlined,
                                            color: Colors.red,
                                          ),
                                          const SizedBox(width: 12),
                                          Text(L10n.of(context).reportMessage),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                          ] else if (!controller.room.isArchived) ...[
                            if (hasActiveGroupCall)
                              PulsatingWidget(
                                color: theme.colorScheme.error,
                                child: Padding(
                                  padding: const EdgeInsets.all(4.0),
                                  child: TextButton.icon(
                                    icon: Icon(switch (controller
                                        .room
                                        .activeMatrixRtcCallIntent) {
                                      .voice => Icons.video_call_outlined,
                                      _ => Icons.mic_outlined,
                                    }),
                                    label: Text(
                                      controller.room
                                          .getActiveMatrixRtcMembers()
                                          .length
                                          .toString(),
                                    ),
                                    onPressed:
                                        controller
                                            .room
                                            .hasPermissionForMatrixRtcCall
                                        ? controller.startOrJoinVideoCall
                                        : null,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: theme.colorScheme.error,
                                      foregroundColor:
                                          theme.colorScheme.onError,
                                    ),
                                  ),
                                ),
                              )
                            else if (controller.room.states['m.bridge'] ==
                                    null &&
                                controller.room.states['uk.half-shot.bridge'] ==
                                    null &&
                                controller.room.hasPermissionForMatrixRtcCall &&
                                controller.supportLiveKitCalls)
                              IconButton(
                                icon: Icon(Icons.call_outlined),
                                onPressed: controller.startOrJoinVideoCall,
                              ),
                            RoomPersonalButton(
                              room: scheduledSource,
                              composer: controller.sendController,
                              readCutoff: () => controller.personalSeenEventId,
                              replyEvent: () => controller.replyEvent,
                              isEditing: () => controller.editEvent != null,
                              threadRootEventId: () =>
                                  controller.activeThreadId,
                              threadLastEventId: () =>
                                  controller.threadLastEventId,
                              isCurrentSource: () =>
                                  controller.mounted &&
                                  identical(controller.room, scheduledSource),
                              clearScheduledReply:
                                  controller.cancelReplyEventAction,
                              includeChatSettings: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  bottom: PreferredSize(
                    preferredSize: Size.fromHeight(appbarBottomHeight),
                    child: Column(
                      mainAxisSize: .min,
                      children: [
                        if (showSyncNotice)
                          SizedBox(
                            height: syncHeight,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    sync!.status == SyncStatus.error
                                        ? Icons.sync_problem_outlined
                                        : Icons.sync_outlined,
                                    size: 16,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      sync.calcLocalizedString(context),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (lockedCount > 0)
                          UndecryptableChatHint(
                            count: lockedCount,
                            onFix: () => showUndecryptableFixSheet(
                              context,
                              client: controller.room.client,
                              events: locked,
                            ),
                          ),
                        PinnedEvents(controller),
                        if (activeThreadId != null)
                          SizedBox(
                            height: ChatAppBarListTile.fixedHeight,
                            child: Center(
                              child: TextButton.icon(
                                onPressed: () =>
                                    controller.scrollToEventId(activeThreadId),
                                icon: const Icon(Icons.message),
                                label: Text(L10n.of(context).replyInThread),
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ),
                        if (scrollUpBannerEventId != null &&
                            activeThreadId == null)
                          ChatAppBarListTile(
                            leading: IconButton(
                              color: theme.colorScheme.onSurfaceVariant,
                              icon: const Icon(Icons.close),
                              tooltip: L10n.of(context).close,
                              onPressed: () {
                                controller.discardScrollUpBannerEventId();
                                controller.setReadMarker();
                              },
                            ),
                            title: L10n.of(context).jumpToLastReadMessage,
                            trailing: TextButton(
                              onPressed: () {
                                controller.scrollToEventId(
                                  scrollUpBannerEventId,
                                );
                                controller.discardScrollUpBannerEventId();
                              },
                              child: Text(L10n.of(context).jump),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                floatingActionButton: ConversationJumpButton(
                  visible:
                      controller.showScrollDownButton &&
                      controller.selectedEvents.isEmpty,
                  onPressed: controller.scrollDown,
                ),
                body: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (SizeChangedLayoutNotification notification) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => controller.updateInputBarHeight(),
                    );
                    return true;
                  },
                  child: DropTarget(
                    onDragDone: controller.onDragDone,
                    onDragEntered: controller.onDragEntered,
                    onDragExited: controller.onDragExited,
                    child: SafeArea(
                      top: false,
                      child: Stack(
                        children: <Widget>[
                          if (accountConfig.wallpaperUrl != null)
                            Opacity(
                              opacity: accountConfig.wallpaperOpacity ?? 0.5,
                              child: ImageFiltered(
                                imageFilter: ui.ImageFilter.blur(
                                  sigmaX: accountConfig.wallpaperBlur ?? 0.0,
                                  sigmaY: accountConfig.wallpaperBlur ?? 0.0,
                                ),
                                child: MxcImage(
                                  cacheKey: accountConfig.wallpaperUrl
                                      .toString(),
                                  uri: accountConfig.wallpaperUrl,
                                  fit: BoxFit.cover,
                                  height: MediaQuery.sizeOf(context).height,
                                  width: MediaQuery.sizeOf(context).width,
                                  isThumbnail: false,
                                  placeholder: (_) => Container(),
                                ),
                              ),
                            ),
                          timelineBody,
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: SizeChangedLayoutNotifier(
                              child: NotionGlassBar(
                                key: controller.inputBarKey,
                                alignment: Alignment.center,
                                child: Container(
                                  margin: EdgeInsets.all(bottomSheetPadding),
                                  constraints: const BoxConstraints(
                                    maxWidth: ChatLoomThemes.maxTimelineWidth,
                                  ),
                                  child: controller.room.isExtinct
                                      ? ElevatedButton.icon(
                                          icon: const Icon(Icons.chevron_right),
                                          label: Text(
                                            L10n.of(context).enterNewChat,
                                          ),
                                          onPressed:
                                              controller.goToNewRoomAction,
                                        )
                                      : controller
                                                .room
                                                .canSendDefaultMessages &&
                                            controller.room.membership ==
                                                Membership.join
                                      ? ConversationTint(
                                          color:
                                              controller
                                                  .selectedEvents
                                                  .isNotEmpty
                                              ? theme
                                                    .colorScheme
                                                    .tertiaryContainer
                                              : theme
                                                    .colorScheme
                                                    .surfaceContainer,
                                          borderRadius: BorderRadius.circular(
                                            NotionTokens.radius,
                                          ),
                                          child:
                                              controller
                                                      .room
                                                      .isAbandonedDMRoom ==
                                                  true
                                              ? Row(
                                                  mainAxisAlignment:
                                                      .spaceEvenly,
                                                  children: [
                                                    TextButton.icon(
                                                      style: TextButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              16,
                                                            ),
                                                        foregroundColor: theme
                                                            .colorScheme
                                                            .error,
                                                      ),
                                                      icon: const Icon(
                                                        Icons.archive_outlined,
                                                      ),
                                                      onPressed:
                                                          controller.leaveChat,
                                                      label: Text(
                                                        L10n.of(context).leave,
                                                      ),
                                                    ),
                                                    TextButton.icon(
                                                      style: TextButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              16,
                                                            ),
                                                      ),
                                                      icon: const Icon(
                                                        Icons.forum_outlined,
                                                      ),
                                                      onPressed: controller
                                                          .recreateChat,
                                                      label: Text(
                                                        L10n.of(
                                                          context,
                                                        ).reopenChat,
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : Column(
                                                  mainAxisSize: .min,
                                                  children: [
                                                    ReplyDisplay(controller),
                                                    ChatInputRow(controller),
                                                    ChatEmojiPicker(controller),
                                                  ],
                                                ),
                                        )
                                      : SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                          if (controller.dragging)
                            Container(
                              color: theme.scaffoldBackgroundColor.withAlpha(
                                230,
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.upload_outlined,
                                size: 100,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Whether the chat shows the "sync problem / connecting" strip.
bool chatSyncNoticeVisible(Client client) {
  final sync = client.onSyncStatus.value;
  return sync != null &&
      (sync.status == SyncStatus.error ||
          client.onSync.value == null ||
          client.prevBatch == null);
}

/// The private presentation of [room] the chat chrome shows: nickname and
/// theme (background, bubble colours). Value-comparable, cheap to compute.
Object? chatPersonalSignature(Room room) => (
  InboxProjection(PersonalClient.of(room.client)).displayName(room),
  Message.paletteSignature(Message.resolveRoomPalette(room)),
);

/// Rebuilds [builder] when this room's state changes, when the sync notice
/// must appear, disappear or update its text, or when the private nickname or
/// theme changes. The subscriptions live in state (not re-created per parent
/// build) and ordinary sync ticks or unrelated private-store activity are
/// ignored, so a healthy connection never rebuilds the chat chrome once per
/// second. [child] is passed through untouched so the timeline is not rebuilt
/// (it follows palette changes itself, see [ChatEventList]).
class ChatRoomSignals extends StatefulWidget {
  final Room room;
  final Widget child;
  final Widget Function(BuildContext context, Widget child) builder;

  const ChatRoomSignals({
    super.key,
    required this.room,
    required this.child,
    required this.builder,
  });

  @override
  State<ChatRoomSignals> createState() => _ChatRoomSignalsState();
}

class _ChatRoomSignalsState extends State<ChatRoomSignals> {
  StreamSubscription<bool>? _subscription;
  (bool, SyncStatus?)? _lastNotice;
  PersonalClient? _personal;
  Object? _personalSignature;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(ChatRoomSignals oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id ||
        !identical(oldWidget.room.client, widget.room.client)) {
      _subscribe();
    }
  }

  (bool, SyncStatus?) _notice(Client client) {
    final visible = chatSyncNoticeVisible(client);
    // While the strip is visible its text follows every status change; while
    // hidden only the transition into a visible state matters.
    return (visible, visible ? client.onSyncStatus.value?.status : null);
  }

  void _subscribe() {
    unawaited(_subscription?.cancel());
    final room = widget.room;
    final client = room.client;
    final roomId = room.id;
    _lastNotice = _notice(client);
    _subscription =
        StreamGroup.merge<Object>([
          client.onRoomState.stream.where((update) => update.roomId == roomId),
          client.onSyncStatus.stream.where((_) {
            final notice = _notice(client);
            if (notice == _lastNotice) return false;
            _lastNotice = notice;
            return true;
          }),
        ]).rateLimit(const Duration(seconds: 1)).listen((_) {
          if (mounted) setState(() {});
        });
    _personal?.removeListener(_onPersonalChanged);
    _personal = PersonalClient.of(client)..addListener(_onPersonalChanged);
    _personalSignature = chatPersonalSignature(room);
  }

  void _onPersonalChanged() {
    if (!mounted) return;
    final signature = chatPersonalSignature(widget.room);
    if (signature == _personalSignature) return;
    _personalSignature = signature;
    setState(() {});
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _personal?.removeListener(_onPersonalChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}

class ChatTimelineLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const ChatTimelineLoadError({required this.onRetry, super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Could not load this conversation.'),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
