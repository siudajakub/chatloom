// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_timeline_preload.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_list_body.dart' show InboxRowMemo;
import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show notionInboxAvatar;
import 'package:chatloom/pages/chat_list/chat_list_view.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/pages/chat_list/inbox_keyboard_navigation.dart';
import 'package:chatloom/personal/bridge_contact_search.dart'
    show BridgeDirectory;
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/conversation_shortcuts.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/message_notification.dart'
    show personalAppLockConfigured;
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/person_route.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_search_page.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/network_action_flows.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_search_page.dart';
import 'package:chatloom/personal/ui/person_sheets.dart'
    show showPersonNotificationsSheet;
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/localized_exception_extension.dart'
    show ExceptionContext;
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/owned_async_wait.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/show_update_snackbar.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:collection/collection.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show ChatPlacement, PersonGroup;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../config/setting_keys.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/matrix.dart';

enum ActiveFilter { allChats, unread, groups, messages }

/// The long-press menu of an inbox row, in order (Telegram, Messenger):
/// Mark as read/unread, Pin/Unpin, Mute…/Unmute, Archive/Unarchive, Merge…
/// (Unmerge on a merged person), Ignore/Restore. Notification settings are
/// the last row of the Mute menu. Disabled entries explain themselves by
/// staying visible (private sync not ready, a change awaiting
/// acknowledgement, a network group that cannot merge).
List<ChatMenuItem<ChatMenuAction>> chatMenuItems(
  PersonalClient owner,
  Room room, {
  required String pinLabel,
  required String unpinLabel,
}) {
  final projection = InboxProjection(owner);
  final entity = projection.entityFor(room);
  final group = projection.groupFor(room);
  final joined = room.membership == Membership.join;
  final metadata = projection.metadataFor(room);
  final pinned = metadata.isPinned;
  final ignored = projection.placementFor(room) == ChatPlacement.ignored;
  final unread = inboxSources(owner, room).any((source) => source.isUnread);
  final canWrite = joined && canEditChatPreferences(owner, 'org:$entity');
  return [
    unread
        ? ChatMenuItem(
            ChatMenuAction.read,
            Icons.mark_chat_read_outlined,
            'Mark as read',
            enabled: joined,
          )
        : ChatMenuItem(
            ChatMenuAction.unread,
            Icons.mark_chat_unread_outlined,
            'Mark as unread',
            enabled: joined,
          ),
    ChatMenuItem(
      ChatMenuAction.pin,
      pinned ? Icons.push_pin : Icons.push_pin_outlined,
      pinned ? unpinLabel : pinLabel,
      enabled: joined && NotionMetadataActions.canEdit(owner, entity),
    ),
    metadata.muted
        ? ChatMenuItem(
            ChatMenuAction.unmute,
            Icons.notifications_active_outlined,
            'Unmute',
            enabled: canWrite,
          )
        : ChatMenuItem(
            ChatMenuAction.mute,
            Icons.notifications_off_outlined,
            'Mute…',
            enabled: joined,
          ),
    metadata.archived
        ? ChatMenuItem(
            ChatMenuAction.unarchive,
            Icons.unarchive_outlined,
            'Unarchive',
            enabled: canWrite,
          )
        : ChatMenuItem(
            ChatMenuAction.archive,
            Icons.archive_outlined,
            'Archive',
            enabled: canWrite && !ignored,
          ),
    if (group != null)
      ChatMenuItem(
        ChatMenuAction.unmerge,
        Icons.call_split,
        'Unmerge',
        enabled: owner.ready,
      )
    else
      ChatMenuItem(
        ChatMenuAction.merge,
        Icons.call_merge,
        'Merge…',
        enabled: owner.ready && InboxProjection.mergeable(room),
      ),
    ChatMenuItem(
      ChatMenuAction.ignore,
      ignored ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ignored ? 'Restore chat' : 'Ignore chat',
      enabled: canWrite,
    ),
    // On the network itself, only where its bridge declares it (FX-01); a
    // merged person has several chats and is deleted per source instead.
    if (group == null && joined && NetworkChatFeatures.of(room).deleteChat)
      const ChatMenuItem(
        ChatMenuAction.deleteChat,
        Icons.delete_outline,
        'Delete chat…',
        destructive: true,
      ),
  ];
}

/// The source rooms of [room]'s inbox row: every room of a merged person,
/// otherwise the room itself.
List<Room> inboxSources(PersonalClient owner, Room room) {
  final group = InboxProjection(owner).groupFor(room);
  if (group == null) return [room];
  final rooms = group.members
      .map((member) => owner.client.getRoomById(member.roomId))
      .whereType<Room>()
      .toList();
  return rooms.isEmpty ? [room] : rooms;
}

/// Marks [room]'s inbox row read without opening it: each unread source
/// gets a manual read marker through the privacy filter (the same rule as
/// the chat's own "Mark as read": incognito allows an explicit action, the
/// receipt is public only when public receipts are on) and loses a manual
/// unread flag (room account data, no receipt). [privateReceipt] keeps the
/// receipt private whatever the receipt setting says (bulk "Mark all as
/// read" under incognito, FX-17).
Future<void> markInboxRowRead(
  PersonalClient owner,
  Room room, {
  bool privateReceipt = false,
}) async {
  for (final source in inboxSources(owner, room)) {
    if (source.membership != Membership.join || !source.isUnread) continue;
    if (source.markedUnread) await source.markUnread(false);
    final id = source.lastEvent?.eventId;
    if (source.notificationCount > 0 && id != null) {
      await PersonalPrivacy.markRead(
        source,
        id,
        manual: true,
        privateReceipt: privateReceipt,
      );
    }
  }
}

/// Marks [room]'s inbox row unread (Telegram's dot): the manual-unread flag
/// on one source (a merged person's default chat), never a receipt.
Future<void> markInboxRowUnread(PersonalClient owner, Room room) {
  final group = InboxProjection(owner).groupFor(room);
  final target =
      (group == null ? null : owner.client.getRoomById(group.defaultRoomId)) ??
      room;
  return target.markUnread(true);
}

/// Human end of a timed mute for the confirmation ("for 1 hour").
String muteLabel(MuteChoice choice) => switch (choice) {
  MuteChoice.hour => 'Muted for 1 hour',
  MuteChoice.eightHours => 'Muted for 8 hours',
  MuteChoice.week => 'Muted for 1 week',
  MuteChoice.always || MuteChoice.settings => 'Muted',
};

class ChatList extends StatefulWidget {
  final String? activeChat;

  /// Person group whose merged chat (or one of its source chats) is open in
  /// the side column; its inbox row is shown as selected.
  final String? activeGroup;

  const ChatList({super.key, required this.activeChat, this.activeGroup});

  @override
  ChatListController createState() => ChatListController();
}

class ChatListController extends State<ChatList> with TickerProviderStateMixin {
  static ChatListController? _shortcutOwner;
  bool _searchOpen = false;
  OwnedAsyncWait? _firstSyncWait;
  int _firstSyncGeneration = 0;

  StreamSubscription? _intentDataStreamSubscription;

  StreamSubscription? _intentFileStreamSubscription;

  late ActiveFilter activeFilter;

  Future<void> onChatTap(Room room) async {
    final group = InboxProjection(personal).groupFor(room);
    if (group != null) {
      context.go(personChatLocation(group.id));
      return;
    }

    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (room.membership == Membership.invite) {
      final joinResult = await showFutureLoadingDialog(
        context: context,
        future: () async {
          final waitForRoom = room.client.waitForRoomInSync(
            room.id,
            join: true,
          );
          await room.join();
          await waitForRoom;
        },
        exceptionContext: ExceptionContext.joinRoom,
      );
      if (joinResult.error != null) return;
    }
    if (!mounted) return;

    if (room.membership == Membership.ban) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.youHaveBeenBannedFromThisChat)),
      );
      return;
    }

    if (room.isSpace) {
      return; // Spaces are not part of the ChatLoom UI.
    }

    // Telegram: the chat slides in with its messages already there.
    await ChatTimelinePreload.warm(room);
    if (!mounted) return;
    context.go('/rooms/${room.id}');
  }

  bool Function(Room) getRoomFilterByActiveFilter(ActiveFilter activeFilter) {
    switch (activeFilter) {
      case ActiveFilter.allChats:
        return (room) => true;
      case ActiveFilter.messages:
        return (room) => !room.isSpace && room.isDirectChatForDisplay;
      case ActiveFilter.groups:
        return (room) => !room.isSpace && !room.isDirectChatForDisplay;
      case ActiveFilter.unread:
        return (room) => room.isUnreadOrInvited;
    }
  }

  final _personalViews = <String, (InboxFilter, String?)>{};
  InboxFilter get personalFilter =>
      _personalViews[inboxAccountKey]?.$1 ?? InboxFilter.inbox;
  set personalFilter(InboxFilter filter) =>
      _personalViews[inboxAccountKey] = (filter, personalLabel);
  String? get personalLabel => _personalViews[inboxAccountKey]?.$2;
  set personalLabel(String? label) =>
      _personalViews[inboxAccountKey] = (personalFilter, label);
  PersonalClient get personal => PersonalClient.of(Matrix.of(context).client);
  void setPersonalFilter(InboxFilter filter, String? label) => setState(() {
    personalFilter = filter;
    personalLabel = label;
    activeFilter = ActiveFilter.allChats;
  });
  final networkSelections = NotionAccountNetworkSelection();
  String get inboxAccountKey =>
      '${Matrix.of(context).client.clientName}:${Matrix.of(context).client.userID}';
  String? get selectedNetwork {
    final saved = networkSelections.forAccount(inboxAccountKey);
    if (saved == null) return null;
    final canonical =
        canonicalNetwork(saved) ?? (saved == 'other' ? saved : null);
    return availableNetworks.contains(canonical) ? canonical : null;
  }

  void setNetwork(String? network) => setState(() {
    networkSelections.select(inboxAccountKey, network);
  });

  InboxController? _inbox;
  bool _inboxVisible = true;

  /// Built inbox rows reused across publishes (see [InboxRowMemo]).
  final rowMemo = InboxRowMemo();

  /// Rows (by inbox entity) that a merge, unmerge or undo just produced:
  /// each flashes once so the eye finds where the chats went (Telegram
  /// animates such moves; the inbox does not reorder with motion).
  final Map<String, int> _rowFlashes = {};
  final Set<String> _freshFlashes = {};

  /// Flash counter of [entity]; a change replays the row highlight.
  int rowFlash(String entity) => _rowFlashes[entity] ?? 0;

  /// True once for a row created by such a change, so it flashes when it
  /// first mounts (it has no earlier state to compare with).
  bool takeFreshFlash(String entity) => _freshFlashes.remove(entity);

  void _flashRows(Iterable<String> entities) {
    for (final entity in entities) {
      _rowFlashes[entity] = rowFlash(entity) + 1;
      _freshFlashes.add(entity);
    }
  }

  static Iterable<String> _sourceEntities(PersonGroup group) =>
      group.members.map((member) => member.roomId);

  /// Cached inbox of the active account; recreated when the account changes.
  InboxController get inbox {
    final client = Matrix.of(context).client;
    final personal = PersonalClient.of(client);
    final current = _inbox;
    if (current != null &&
        identical(current.client, client) &&
        identical(current.personal, personal)) {
      return current;
    }
    if (current != null) {
      // Listeners rebuild onto the new controller first; release afterwards.
      current.detach();
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    _selectionKey = null;
    rowMemo.clear();
    return _inbox = InboxController(client, personal)
      ..active = _inboxVisible
      ..addListener(_offerShortcuts);
  }

  final _shortcuts = ConversationShortcutPublisher();
  DateTime? _shortcutsCheckedAt;

  /// Android launcher shortcuts for the newest chats (FT-21), checked at most
  /// once a minute and published at most every few minutes; none while the
  /// app lock is set or notification previews are off.
  void _offerShortcuts() {
    if (!PlatformInfos.isAndroid || !mounted) return;
    final inbox = _inbox;
    if (inbox == null || inbox.loading) return;
    final now = DateTime.now();
    final checked = _shortcutsCheckedAt;
    if (checked != null && now.difference(checked) < _shortcutCheckInterval) {
      return;
    }
    _shortcutsCheckedAt = now;
    final top = topConversationShortcuts(inbox.projection, inbox.index);
    personalAppLockConfigured().then((locked) {
      if (!mounted || !identical(_inbox, inbox)) return;
      _shortcuts.offer(
        top,
        allowed: !locked && AppSettings.personalNotificationPreviews.value,
      );
    }, onError: (Object _) {});
  }

  static const _shortcutCheckInterval = Duration(minutes: 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by a chat (mobile) → stop recomputing; refresh once on return.
    _inboxVisible = ModalRoute.isCurrentOf(context) ?? true;
    _inbox?.active = _inboxVisible;
  }

  /// Networks of non-technical chats (computed once per inbox change).
  List<String> get availableNetworks => inbox.networks;

  Object? _selectionKey;
  List<Room> _selection = const [];

  /// Visible rooms for the current view, search, network settings.
  /// Selection runs over cached records and is memoised until the inbox or
  /// one of the inputs changes.
  List<Room> filterRooms() {
    final inbox = this.inbox;
    final network = selectedNetwork;
    final key = (
      inbox,
      inbox.generation,
      personalFilter,
      personalLabel,
      activeFilter,
      network,
    );
    if (key == _selectionKey) return _selection;
    final index = inbox.index;
    final roomFilter = getRoomFilterByActiveFilter(activeFilter);
    _selection = inbox.projection
        .select(index, filter: personalFilter)
        .where(roomFilter)
        .where(
          (room) =>
              network == null ||
              notionMatchesNetwork(
                index.recordFor(room)?.networks ??
                    notionRoomNetworks(inbox.projection, room),
                network,
              ),
        )
        .toList(growable: false);
    _selectionKey = key;
    return _selection;
  }

  /// Opens the full-screen search: chats, people on the connected networks
  /// and recent messages. It is also where new chats start (Telegram,
  /// Messenger); the app never searches the Matrix directory.
  void openSearch() {
    if (!mounted || !PersonalPrivacy.surfaceUnlocked || _searchOpen) return;
    _searchOpen = true;
    final client = Matrix.of(context).client;
    final navigator = Navigator.of(context);
    navigator
        .push(
          MaterialPageRoute<void>(
            builder: (_) => NotionSearchPage(
              personal: personal,
              inbox: inbox,
              directory: BridgeDirectory.of(client),
              onOpenRoom: onChatTap,
              onOpenMessage: openMessage,
              onSearchHistory: (query) => navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => PersonalSearchPage(
                    personal: personal,
                    initialQuery: query,
                  ),
                ),
              ),
              onSelectView: (view) => setPersonalFilter(view, null),
            ),
          ),
        )
        .whenComplete(() => _searchOpen = false);
  }

  /// Opens [room] at [eventId] (a search hit); a merged person's source
  /// event opens in the person chat.
  void openMessage(Room room, String eventId) {
    final group = InboxProjection(personal).groupFor(room);
    if (group != null) {
      context.go(
        personChatLocation(group.id, sourceRoomId: room.id, eventId: eventId),
      );
      return;
    }
    context.go(
      Uri(
        path: '/rooms/${room.id}',
        queryParameters: {'event': eventId},
      ).toString(),
    );
  }

  final ScrollController scrollController = ScrollController();
  String? get activeChat => widget.activeChat;
  String? get activeGroup => widget.activeGroup;

  void _processIncomingSharedMedia(List<SharedMediaFile> files) {
    if (!mounted) return;
    files.removeWhere(
      (file) => file.path.startsWith(AppConfig.deepLinkPrefix) == true,
    );
    if (files.isEmpty) return;

    showForwardSheet(
      context,
      title: 'Share',
      items: files.map((file) {
        if ({SharedMediaType.text, SharedMediaType.url}.contains(file.type)) {
          return TextShareItem(file.path);
        }
        return FileShareItem(
          XFile(file.path.replaceFirst('file://', ''), mimeType: file.mimeType),
        );
      }).toList(),
    );
  }

  void _initReceiveSharingIntent() {
    if (!PlatformInfos.isMobile) return;

    // For sharing images coming from outside the app while the app is in the memory
    _intentFileStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_processIncomingSharedMedia, onError: print);

    // For sharing images coming from outside the app while the app is closed
    ReceiveSharingIntent.instance.getInitialMedia().then(
      _processIncomingSharedMedia,
    );

    if (PlatformInfos.isAndroid) {
      unawaited(bindLauncherShortcuts());
    }
  }

  // The plugin stores this tear-off in a process-wide MethodChannel. It must
  // never capture a widget; dispose releases the separately held owner.
  static void _dispatchShortcut(String action) {
    final owner = _shortcutOwner;
    if (owner == null || !owner.mounted) return;
    owner.onLauncherShortcut(action);
  }

  @protected
  void onLauncherShortcut(String action) {
    final entity = conversationShortcutEntity(action);
    if (entity == null) {
      UrlLauncher(context, action).launchUrl();
      return;
    }
    // A conversation shortcut (FT-21): a merged person or one chat of the
    // current account; a shortcut of a chat that is gone does nothing.
    if (!PersonalPrivacy.surfaceUnlocked) return;
    if (entity.startsWith('person:')) {
      context.go(personChatLocation(entity.substring('person:'.length)));
      return;
    }
    final room = Matrix.of(context).client.getRoomById(entity);
    if (room != null && room.membership == Membership.join) {
      unawaited(onChatTap(room));
    }
  }

  @protected
  Future<void> bindLauncherShortcuts() async {
    if (!mounted) return;
    _shortcutOwner = this;
    final shortcuts = FlutterShortcuts();
    await shortcuts.initialize();
    if (!mounted || !identical(_shortcutOwner, this)) return;
    await shortcuts.listenAction(_dispatchShortcut);
  }

  void _loadAccountInbox(Client client) {
    PersonalClient.of(client)
        .load()
        .then((_) {
          // Messages removed for you (FX-16), from the store just opened.
          HiddenMessages.instance.load(client);
          if (mounted && Matrix.of(context).client == client) setState(() {});
        })
        .catchError((Object error, StackTrace stack) {
          if (!mounted || Matrix.of(context).client != client) return;
          ErrorReporter(
            context,
            'Unable to load personal inbox',
          ).onErrorCallback(error, stack);
        });
  }

  @override
  void initState() {
    if (PlatformInfos.isMacOS) {
      MacDesktopCommands.bindInbox(this, inboxKeyboardCommands(this));
    }
    _initReceiveSharingIntent();

    waitForInitialSync();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (mounted) {
        Matrix.of(context).backgroundPush?.setupPush(context);
        UpdateNotifier.showUpdateDialog(context);
      }

      // Workaround for system UI overlay style not applied on app start
      SystemChrome.setSystemUIOverlayStyle(
        Theme.of(context).appBarTheme.systemOverlayStyle!,
      );
    });

    // Tags are not shown in the inbox; a saved tag filter falls back to all
    // chats. Room tags themselves are never changed here.
    activeFilter =
        ActiveFilter.values.singleWhereOrNull(
          (filter) => AppSettings.chatFilter.value == filter.name,
        ) ??
        ActiveFilter.allChats;

    _processPushHelperCrashReport();

    super.initState();
    _loadAccountInbox(Matrix.of(context).client);
  }

  @override
  void dispose() {
    MacDesktopCommands.unbindSearch(this);
    _cancelFirstSyncWait();
    if (identical(_shortcutOwner, this)) _shortcutOwner = null;
    _intentDataStreamSubscription?.cancel();
    _intentFileStreamSubscription?.cancel();
    scrollController.dispose();
    _inbox?.dispose();
    _inbox = null;
    super.dispose();
  }

  void _processPushHelperCrashReport() {
    final store = Matrix.of(context).store;
    final report = store.getStringList(AppConfig.pushHelperCrashReportKey);
    if (report == null) return;
    store.remove(AppConfig.pushHelperCrashReportKey);
    if (report.length < 2) return;
    // A past background crash is not something to answer at launch.
    logBackgroundError(
      'push_helper_crash',
      report.first,
      StackTrace.fromString(report.last),
    );
  }

  /// Long-press menu of an inbox row (see [chatMenuItems]). Every change
  /// applies at once without a loader; reversible ones offer Undo, a
  /// failure is explained in a snackbar. Leave, block, tags, spaces and low
  /// priority are intentionally not offered here.
  Future<void> chatContextAction(Room room, BuildContext posContext) async {
    final owner = personal;
    final account = inboxAccountKey;
    final box = posContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final projection = InboxProjection(owner);
    final l10n = L10n.of(context);
    final title = projection.displayName(room);
    Widget avatar() => notionInboxAvatar(
      owner,
      InboxProjection(owner),
      room,
      size: NotionSize.avatarSm,
    );
    final action = await showChatActionsMenu(
      posContext,
      anchor: anchor,
      title: title,
      avatar: avatar(),
      items: chatMenuItems(
        owner,
        room,
        pinLabel: l10n.pin,
        unpinLabel: l10n.unpin,
      ),
    );
    if (action == null || !mounted) return;
    if (!_sameInbox(owner, account) || !identical(room.client, owner.client)) {
      return;
    }
    String entity() => InboxProjection(owner).entityFor(room);

    switch (action) {
      case ChatMenuAction.read:
      case ChatMenuAction.unread:
        applyRowAction(room, action, owner: owner, account: account);
        return;
      case ChatMenuAction.pin:
        final pinned = InboxProjection(owner).metadataFor(room).isPinned;
        _runChange(
          owner,
          account,
          () => NotionMetadataActions.setPinned(owner, entity(), !pinned),
          failure: pinned
              ? 'Couldn’t unpin the chat. Check private sync and try again.'
              : 'Couldn’t pin the chat. Check private sync and try again.',
        );
        return;
      case ChatMenuAction.mute:
        final choice = await showChatActionsMenu<MuteChoice>(
          posContext.mounted ? posContext : context,
          anchor: anchor,
          title: title,
          avatar: avatar(),
          haptic: false,
          items: muteMenuItems(
            canMute: canEditChatPreferences(owner, 'org:${entity()}'),
          ),
        );
        if (choice == null || !mounted || !_sameInbox(owner, account)) return;
        if (choice == MuteChoice.settings) {
          await _openNotificationSettings(owner, room);
          return;
        }
        final target = entity();
        final duration = choice.duration;
        _runChange(
          owner,
          account,
          () => NotionMetadataActions.setMuted(
            owner,
            target,
            muted: true,
            until: duration == null ? null : DateTime.now().add(duration),
          ),
          failure: 'Couldn’t mute the chat. Check private sync and try again.',
          done: muteLabel(choice),
          undo: () =>
              NotionMetadataActions.setMuted(owner, target, muted: false),
        );
        return;
      case ChatMenuAction.unmute:
        _runChange(
          owner,
          account,
          () => NotionMetadataActions.setMuted(owner, entity(), muted: false),
          failure:
              'Couldn’t unmute the chat. Check private sync and try again.',
        );
        return;
      case ChatMenuAction.archive:
      case ChatMenuAction.unarchive:
        applyRowAction(room, action, owner: owner, account: account);
        return;
      case ChatMenuAction.merge:
        await mergeFrom(room);
        return;
      case ChatMenuAction.unmerge:
        final current = InboxProjection(owner).groupFor(room);
        if (current != null) await _unmerge(current);
        return;
      case ChatMenuAction.notifications:
        await _openNotificationSettings(owner, room);
        return;
      case ChatMenuAction.deleteChat:
        // The row hides itself while the network deletes the chat
        // (InboxController listens to NetworkChatActions).
        await deleteNetworkChatFlow(
          context,
          room,
          name: title,
          fromRequest: isMessageRequest(room),
        );
        return;
      case ChatMenuAction.ignore:
        final target = entity();
        if (!canEditChatPreferences(owner, 'org:$target')) return;
        final projection = InboxProjection(owner);
        final metadata = projection.metadataFor(room);
        final ignored = projection.placementFor(room) == ChatPlacement.ignored;
        final kind = projection.classifier.classify(room);
        final updated = ignored
            ? metadata.restoreIgnored(
                inheritedIgnored:
                    kind.isGroup &&
                    projection
                            .networkPreferences(kind.network)
                            .groupPlacement ==
                        ChatPlacement.ignored,
              )
            : metadata.setIgnored(true);
        final previous = owner.values['org:$target'];
        Future<void> write(Map<String, dynamic> value) =>
            owner.put('org:$target', value);
        _runChange(
          owner,
          account,
          () => write(
            {...?previous, ...updated.toJson()}.cast<String, dynamic>(),
          ),
          failure: ignored
              ? 'Couldn’t restore the chat. Check private sync and try again.'
              : 'Couldn’t ignore the chat. Check private sync and try again.',
          done: ignored ? null : 'Chat ignored',
          undo: ignored
              ? null
              : () => write(
                  {
                    ...?owner.values['org:$target'],
                    ...InboxProjection(owner)
                        .metadataForEntity(target)
                        .restoreIgnored(
                          inheritedIgnored:
                              kind.isGroup &&
                              projection
                                      .networkPreferences(kind.network)
                                      .groupPlacement ==
                                  ChatPlacement.ignored,
                        )
                        .toJson(),
                  }.cast<String, dynamic>(),
                ),
        );
        return;
    }
  }

  /// Notification settings of an inbox row: a merged person's own sheet
  /// (the person's mode for every network, as on its person page), else the
  /// chat's preferences page.
  Future<void> _openNotificationSettings(
    PersonalClient owner,
    Room room,
  ) async {
    final group = InboxProjection(owner).groupFor(room);
    if (group != null) {
      await showPersonNotificationsSheet(
        context,
        personal: owner,
        group: group,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChatPreferencesPage(personal: owner, room: room),
      ),
    );
  }

  /// Mark read/unread and archive/unarchive of an inbox row, from its
  /// long-press menu or a swipe (UX-14): applied at once, "Chat archived"
  /// with Undo, a failure explained in a snackbar.
  void applyRowAction(
    Room room,
    ChatMenuAction action, {
    PersonalClient? owner,
    String? account,
  }) {
    final personal = owner ?? this.personal;
    final key = account ?? inboxAccountKey;
    switch (action) {
      case ChatMenuAction.read:
        _runChange(
          personal,
          key,
          () => markInboxRowRead(personal, room),
          failure: 'Couldn’t mark the chat as read. Try again.',
        );
      case ChatMenuAction.unread:
        _runChange(
          personal,
          key,
          () => markInboxRowUnread(personal, room),
          failure: 'Couldn’t mark the chat as unread. Try again.',
        );
      case ChatMenuAction.archive:
      case ChatMenuAction.unarchive:
        final archive = action == ChatMenuAction.archive;
        final target = InboxProjection(personal).entityFor(room);
        final sources = inboxSources(personal, room);
        _runChange(
          personal,
          key,
          () => NotionMetadataActions.setArchived(
            personal,
            target,
            archive,
            sources: sources,
          ),
          failure: archive
              ? 'Couldn’t archive the chat. Check private sync and try again.'
              : 'Couldn’t move the chat back. Check private sync and try again.',
          done: archive ? 'Chat archived' : null,
          undo: archive
              ? () => NotionMetadataActions.setArchived(
                  personal,
                  target,
                  false,
                  sources: sources,
                )
              : null,
        );
      default:
        return;
    }
  }

  /// The swipe sides of an inbox row (UX-14, Telegram): towards the start
  /// archives (unarchives in the Archive view), towards the end marks read
  /// or unread. Null without the setting, for invites and left chats. The
  /// menu's rules decide at release, so a swipe never does what its menu
  /// row would refuse.
  ({NotionSwipeActionSide? archive, NotionSwipeActionSide? read})?
  rowSwipeSides(Room room, InboxProjection projection) {
    if (!AppSettings.inboxSwipeActions.value ||
        room.membership != Membership.join) {
      return null;
    }
    final group = projection.groupFor(room);
    final sources = group == null
        ? [room]
        : [
            for (final member in group.members)
              ?room.client.getRoomById(member.roomId),
          ];
    final unread = sources.any((source) => source.isUnread);
    final archived = projection.metadataFor(room).archived;
    final ignored = projection.placementFor(room) == ChatPlacement.ignored;
    void commit(ChatMenuAction action, String refused) {
      if (!mounted) return;
      final item = chatMenuItems(
        personal,
        room,
        pinLabel: '',
        unpinLabel: '',
      ).firstWhereOrNull((item) => item.action == action);
      if (item == null || !item.enabled) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(refused)));
        return;
      }
      applyRowAction(room, action);
    }

    return (
      archive: ignored
          ? null
          : NotionSwipeActionSide(
              icon: archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: archived ? 'Unarchive' : 'Archive',
              onCommit: () => commit(
                archived ? ChatMenuAction.unarchive : ChatMenuAction.archive,
                'Archive needs private sync. Try again in a moment.',
              ),
            ),
      read: NotionSwipeActionSide(
        icon: unread
            ? Icons.mark_chat_read_outlined
            : Icons.mark_chat_unread_outlined,
        label: unread ? 'Read' : 'Unread',
        onCommit: () => commit(
          unread ? ChatMenuAction.read : ChatMenuAction.unread,
          'Couldn’t change this chat right now. Try again.',
        ),
      ),
    );
  }

  Object? _unreadKey;
  int _unreadChats = 0;
  Object? _requestKey;
  int _requestChats = 0;

  /// Message requests waiting for an answer (FX-02): the "Requests" chip
  /// appears only while there are some. Memoised like [unreadViewCount].
  int requestViewCount() {
    final inbox = this.inbox;
    final key = (inbox, inbox.generation);
    if (key == _requestKey) return _requestChats;
    _requestChats = inbox.projection
        .select(inbox.index, filter: InboxFilter.requests)
        .length;
    _requestKey = key;
    return _requestChats;
  }

  /// Chats in the Unread view for the selected network: the "Unread" chip's
  /// count (UX-16). Memoised per inbox change, like [filterRooms].
  int unreadViewCount() {
    final inbox = this.inbox;
    final network = selectedNetwork;
    final key = (inbox, inbox.generation, network);
    if (key == _unreadKey) return _unreadChats;
    final index = inbox.index;
    _unreadChats = inbox.projection
        .select(index, filter: InboxFilter.unread)
        .where(
          (room) =>
              network == null ||
              notionMatchesNetwork(
                index.recordFor(room)?.networks ??
                    notionRoomNetworks(inbox.projection, room),
                network,
              ),
        )
        .length;
    _unreadKey = key;
    return _unreadChats;
  }

  /// "Mark all as read" for the current view and network (FX-17, Telegram's
  /// folder action): every unread row through [markInboxRowRead], i.e.
  /// manual read markers through the privacy filter, private receipts while
  /// incognito. Applied at once with Undo, which puts the manual unread dot
  /// back on those rows (a read marker cannot be taken back).
  void markViewRead() {
    final personal = this.personal;
    final rows = [
      for (final room in filterRooms())
        if (room.membership == Membership.join &&
            inboxSources(personal, room).any(
              (source) =>
                  source.membership == Membership.join && source.isUnread,
            ))
          room,
    ];
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('No unread chats in this view.')),
        );
      return;
    }
    final incognito = AppSettings.personalIncognito.value;
    _runChange(
      personal,
      inboxAccountKey,
      () async {
        // One failing chat does not stop the others.
        Object? error;
        for (final room in rows) {
          try {
            await markInboxRowRead(personal, room, privateReceipt: incognito);
          } catch (e) {
            error ??= e;
          }
        }
        if (error != null) throw error;
      },
      failure: 'Couldn’t mark every chat as read. Try again.',
      done: rows.length == 1
          ? '1 chat marked as read'
          : '${rows.length} chats marked as read',
      undo: () async {
        for (final room in rows) {
          await markInboxRowUnread(personal, room);
        }
      },
    );
  }

  /// Saves the order the user dragged the pinned cards into (FX-17): pin
  /// orders live in the private store (`org:<entity>.pinOrder`). The
  /// carousel already shows the new order; a failure explains itself and
  /// completes with the error, so the pins fall back to the stored order.
  Future<void> reorderPins(List<String> entities) {
    final owner = personal;
    final account = inboxAccountKey;
    final messenger = ScaffoldMessenger.of(context);
    return NotionMetadataActions.reorderPins(owner, entities).then(
      (_) {
        if (_sameInbox(owner, account)) _refreshInbox();
      },
      onError: (Object error) {
        if (_sameInbox(owner, account)) {
          _refreshInbox();
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text(
                  'Couldn’t move the pinned chat. Check private sync and try again.',
                ),
              ),
            );
        }
        throw error;
      },
    );
  }

  /// Runs a private change without blocking the UI: the inbox shows it as
  /// soon as the local replica has it. [done] confirms it in a snackbar,
  /// with Undo when [undo] is given; a failure explains itself.
  void _runChange(
    PersonalClient owner,
    String account,
    Future<void> Function() change, {
    required String failure,
    String? done,
    Future<void> Function()? undo,
  }) {
    if (!_sameInbox(owner, account)) return;
    final messenger = ScaffoldMessenger.of(context);
    void failed(Object _) {
      if (!_sameInbox(owner, account)) return;
      _refreshInbox();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure)));
    }

    change().then((_) {
      if (_sameInbox(owner, account)) _refreshInbox();
    }, onError: failed);
    if (done == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(done),
          action: undo == null
              ? null
              : SnackBarAction(
                  label: 'Undo',
                  onPressed: () {
                    if (!_sameInbox(owner, account)) return;
                    undo().then((_) {
                      if (_sameInbox(owner, account)) _refreshInbox();
                    }, onError: failed);
                  },
                ),
        ),
      );
  }

  bool _sameInbox(PersonalClient owner, String account) =>
      mounted && inboxAccountKey == account && identical(personal, owner);

  /// Shows a private group change at once instead of after the debounce.
  void _refreshInbox() => inbox
    ..markChanged(all: true)
    ..refresh();

  /// Runs a person group change without blocking the UI (an unmerge may
  /// wait for the acknowledgement of a merge made moments ago).
  void _runGroupChange(
    PersonalClient owner,
    String account,
    Future<void> Function() change,
  ) {
    if (!_sameInbox(owner, account) || !owner.ready) return;
    final messenger = ScaffoldMessenger.of(context);
    change().then(
      (_) {
        if (_sameInbox(owner, account)) _refreshInbox();
      },
      onError: (Object _) {
        if (!_sameInbox(owner, account)) return;
        _refreshInbox();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('The change was not saved. Check private sync.'),
          ),
        );
      },
    );
    _refreshInbox();
  }

  /// Opens the merge picker for [room]; the merged person replaces the
  /// source rows at once, with Undo in a snackbar.
  Future<void> mergeFrom(Room room) async {
    final owner = personal;
    final account = inboxAccountKey;
    if (!owner.ready || !InboxProjection.mergeable(room)) return;
    final picked = await showMergePicker(
      context,
      personal: owner,
      anchor: room,
    );
    if (picked == null ||
        picked.isEmpty ||
        !_sameInbox(owner, account) ||
        !owner.ready ||
        !identical(room.client, owner.client))
      return;
    final MergePlan plan;
    try {
      plan = planMerge(owner, [
        room,
        for (final candidate in picked) ...candidate.sources,
      ], anchor: room);
      await applyMerge(owner, plan);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The chats could not be merged. Check private sync.'),
        ),
      );
      return;
    }
    if (!mounted || !_sameInbox(owner, account)) return;
    _flashRows(['person:${plan.group.id}']);
    _refreshInbox();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            plan.createsGroup ? 'Chats merged' : 'Added to the merged chat',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              _flashRows([
                ..._sourceEntities(plan.group),
                if (plan.previous != null) 'person:${plan.previous!.id}',
                for (final absorbed in plan.absorbed) 'person:${absorbed.id}',
              ]);
              _runGroupChange(owner, account, () => undoMerge(owner, plan));
            },
          ),
        ),
      );
  }

  Future<void> _unmerge(PersonGroup group) async {
    final owner = personal;
    final account = inboxAccountKey;
    final confirmed = await showNotionConfirmDialog(
      context: context,
      title: 'Unmerge conversations?',
      message:
          'The source chats and their messages are kept and return to the inbox as separate chats.',
      confirmLabel: 'Unmerge',
    );
    if (!confirmed || !mounted || !_sameInbox(owner, account)) return;
    _flashRows(_sourceEntities(group));
    _runGroupChange(owner, account, () => owner.removeGroup(group.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chats unmerged'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              _flashRows(['person:${group.id}']);
              _runGroupChange(owner, account, () => owner.putGroup(group));
            },
          ),
        ),
      );
  }

  bool waitForFirstSync = false;

  void _cancelFirstSyncWait() {
    _firstSyncGeneration++;
    _firstSyncWait?.cancel();
    _firstSyncWait = null;
  }

  @protected
  Future<void> waitForInitialSync() async {
    if (!mounted) return;
    _cancelFirstSyncWait();
    final generation = _firstSyncGeneration;
    final wait = OwnedAsyncWait();
    _firstSyncWait = wait;
    final client = Matrix.of(context).client;
    bool current() =>
        mounted &&
        generation == _firstSyncGeneration &&
        identical(Matrix.of(context).client, client);
    try {
      if (!await wait.until(client.roomsLoading) || !current()) return;
      if (!await wait.until(client.accountDataLoading) || !current()) return;
      if (!await wait.until(client.userDeviceKeysLoading) || !current()) return;
      if (client.prevBatch == null &&
          !await wait.firstWhere(
            client.onSyncStatus.stream,
            (status) => status.status == SyncStatus.finished,
          )) {
        return;
      }
      if (!current()) return;
      // Unverified sessions, key backup and private sync health show in the
      // inbox status row (InboxHealthStatus), not as a per-launch snackbar.
      setState(() {
        waitForFirstSync = true;
      });
    } catch (_) {
      if (current()) Logs().w('Initial sync readiness is unavailable');
    } finally {
      wait.cancel();
      if (identical(_firstSyncWait, wait)) _firstSyncWait = null;
    }
  }

  void setActiveClient(Client client) {
    _cancelFirstSyncWait();
    context.go('/rooms');
    setState(() {
      activeFilter = ActiveFilter.allChats;
      personalFilter = InboxFilter.inbox;
      personalLabel = null;
      Matrix.of(context).setActiveClient(client);
    });
    _loadAccountInbox(client);
    waitForInitialSync();
  }

  @override
  Widget build(BuildContext context) => ChatListView(this);
}
