// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show notionInboxAvatar;
import 'package:chatloom/pages/chat_list/chat_list_view.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/person_route.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/localized_exception_extension.dart'
    show ExceptionContext;
import 'package:chatloom/utils/owned_async_wait.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/show_scaffold_dialog.dart';
import 'package:chatloom/utils/show_update_snackbar.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:collection/collection.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show ChatPlacement, PersonGroup;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../../utils/account_bundles.dart';
import '../../config/setting_keys.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/matrix.dart';

enum ActiveFilter { allChats, unread, groups, messages, tag }

extension LocalizedActiveFilter on ActiveFilter {
  String toLocalizedString(BuildContext context) {
    switch (this) {
      case ActiveFilter.allChats:
        return L10n.of(context).all;
      case ActiveFilter.messages:
        return L10n.of(context).messages;
      case ActiveFilter.unread:
        return L10n.of(context).unread;
      case ActiveFilter.groups:
        return L10n.of(context).groups;
      case ActiveFilter.tag:
        throw 'Tags should not directly be displayed!';
    }
  }
}

/// The long-press menu of an inbox row, in order: Pin/Unpin, Merge… (or
/// Unmerge on a merged person), Notifications, Ignore/Restore. Disabled
/// entries explain themselves by staying visible (private sync not ready,
/// a change awaiting acknowledgement, a network group that cannot merge).
List<ChatMenuItem> chatMenuItems(
  PersonalClient owner,
  Room room, {
  required String pinLabel,
  required String unpinLabel,
}) {
  final projection = InboxProjection(owner);
  final entity = projection.entityFor(room);
  final group = projection.groupFor(room);
  final joined = room.membership == Membership.join;
  final pinned = projection.metadataFor(room).isPinned;
  final ignored = projection.placementFor(room) == ChatPlacement.ignored;
  return [
    ChatMenuItem(
      ChatMenuAction.pin,
      pinned ? Icons.push_pin : Icons.push_pin_outlined,
      pinned ? unpinLabel : pinLabel,
      enabled: joined && NotionMetadataActions.canEdit(owner, entity),
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
      ChatMenuAction.notifications,
      Icons.notifications_outlined,
      'Notifications',
      enabled: joined,
    ),
    ChatMenuItem(
      ChatMenuAction.ignore,
      ignored ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ignored ? 'Restore chat' : 'Ignore chat',
      enabled: joined && canEditChatPreferences(owner, 'org:$entity'),
    ),
  ];
}

class ChatList extends StatefulWidget {
  final String? activeChat;

  /// Person group whose merged chat (or one of its source chats) is open in
  /// the side column; its inbox row is shown as selected.
  final String? activeGroup;
  final String? activeSpace;
  final bool displayNavigationRail;

  const ChatList({
    super.key,
    required this.activeChat,
    this.activeGroup,
    this.activeSpace,
    this.displayNavigationRail = false,
  });

  @override
  ChatListController createState() => ChatListController();
}

class ChatListController extends State<ChatList> with TickerProviderStateMixin {
  static ChatListController? _shortcutOwner;
  OwnedAsyncWait? _firstSyncWait;
  int _firstSyncGeneration = 0;

  StreamSubscription? _intentDataStreamSubscription;

  StreamSubscription? _intentFileStreamSubscription;

  StreamSubscription? _callEventSubscription;

  late ActiveFilter activeFilter;
  String? activeTag;

  String? _activeSpaceId;

  String? get activeSpaceId => _activeSpaceId;

  Future<void> setActiveSpace(String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();
    if (!mounted) return;
    if (!ChatLoomThemes.isColumnMode(context) &&
        !AppSettings.displayNavigationRail.value) {
      await AppSettings.displayNavigationRail.setItem(true);
    }

    setState(() {
      _activeSpaceId = spaceId;
    });
  }

  void clearActiveSpace() => setState(() {
    _activeSpaceId = null;
  });

  void _onCallEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionCallAccept():
        _joinCallWith(event.callKitParams);
        break;
      case CallEventActionCallEnded():
        final roomId = event.callKitParams.extra?.tryGet<String>('roomId');
        if (roomId != null &&
            Matrix.of(context).activeCallRoomId.value == roomId) {
          Matrix.of(context).activeCallRoomId.value = null;
        }
        break;
      default:
        break;
    }
  }

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

    if (room.membership == Membership.leave) {
      context.go('/rooms/archive/${room.id}');
      return;
    }

    if (room.isSpace) {
      setActiveSpace(room.id);
      return;
    }

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
      case ActiveFilter.tag:
        return (room) => room.tags.keys.contains(activeTag);
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
    activeTag = null;
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
    return _inbox = InboxController(client, personal)..active = _inboxVisible;
  }

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

  /// Visible rooms for the current view, search, network and space settings.
  /// Selection runs over cached records and is memoised until the inbox or
  /// one of the inputs changes.
  List<Room> filterRooms() {
    final inbox = this.inbox;
    final network = selectedNetwork;
    final query = searchController.text;
    final hideInSpaces = AppSettings.hideRoomsInSpaces.value;
    final key = (
      inbox,
      inbox.generation,
      personalFilter,
      personalLabel,
      query,
      activeFilter,
      activeTag,
      network,
      hideInSpaces,
    );
    if (key == _selectionKey) return _selection;
    final index = inbox.index;
    final delegated = inbox.delegated;
    final roomFilter = getRoomFilterByActiveFilter(activeFilter);
    _selection = inbox.projection
        .select(index, filter: personalFilter, query: query)
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
        .where((room) => !hideInSpaces || delegated[room.id] == null)
        .toList(growable: false);
    _selectionKey = key;
    return _selection;
  }

  bool isSearchMode = false;
  Future<QueryPublicRoomsResponse>? publicRoomsResponse;
  String? searchServer;
  Timer? _coolDown;
  SearchUserDirectoryResponse? userSearchResult;
  QueryPublicRoomsResponse? roomSearchResult;

  bool isSearching = false;
  bool publicDiscovery = false;
  int _searchGeneration = 0;
  int _searchScrollGeneration = 0;
  final Map<String, double> _preSearchInboxOffsets = {};
  static const String _serverStoreNamespace = 'im.fluffychat.search.server';

  Future<void> setServer() async {
    final matrix = Matrix.of(context);
    final l10n = L10n.of(context);
    final newServer = await showTextInputDialog(
      useRootNavigator: false,
      title: l10n.changeTheHomeserver,
      context: context,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
      prefixText: 'https://',
      hintText: matrix.client.homeserver?.host,
      initialText: searchServer,
      keyboardType: TextInputType.url,
      autocorrect: false,
      validator: (server) =>
          server.contains('.') == true ? null : l10n.invalidServerName,
    );
    if (newServer == null) return;
    if (!mounted) return;
    matrix.store.setString(_serverStoreNamespace, newServer);
    _searchGeneration++;
    setState(() {
      searchServer = newServer;
    });
    _coolDown?.cancel();
    // Changing the server does not disclose a query until the explicit search.
    setState(() {
      roomSearchResult = null;
      userSearchResult = null;
      publicDiscovery = false;
      isSearching = false;
    });
  }

  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  Future<void> _search() async {
    final client = Matrix.of(context).client;
    final generation = ++_searchGeneration;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (!isSearching) {
      setState(() {
        isSearching = true;
      });
    }
    SearchUserDirectoryResponse? userSearchResult;
    QueryPublicRoomsResponse? roomSearchResult;
    final searchQuery = searchController.text.trim();
    try {
      roomSearchResult = await client.queryPublicRooms(
        server: searchServer,
        filter: PublicRoomQueryFilter(genericSearchTerm: searchQuery),
        limit: 20,
      );
      if (!mounted ||
          generation != _searchGeneration ||
          !publicDiscovery ||
          client != Matrix.of(context).client)
        return;

      if (searchQuery.isValidMatrixIdStrict() &&
          searchQuery.sigil == '#' &&
          roomSearchResult.chunk.any(
                (room) => room.canonicalAlias == searchQuery,
              ) ==
              false) {
        final response = await client.getRoomIdByAlias(searchQuery);
        final roomId = response.roomId;
        if (roomId != null) {
          roomSearchResult.chunk.add(
            PublishedRoomsChunk(
              name: searchQuery,
              guestCanJoin: false,
              numJoinedMembers: 0,
              roomId: roomId,
              worldReadable: false,
              canonicalAlias: searchQuery,
            ),
          );
        }
      }
      if (!mounted ||
          generation != _searchGeneration ||
          !publicDiscovery ||
          client != Matrix.of(context).client)
        return;
      userSearchResult = await client.searchUserDirectory(
        searchQuery,
        limit: 20,
      );
    } catch (e) {
      // Directory errors may embed the query or identifiers in their payload.
      Logs().w('Public discovery failed (${e.runtimeType})');
      if (!mounted ||
          generation != _searchGeneration ||
          client != Matrix.of(context).client)
        return;
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Public discovery could not be completed. Try again or choose another homeserver.',
          ),
        ),
      );
    }
    if (!mounted ||
        !isSearchMode ||
        !publicDiscovery ||
        generation != _searchGeneration ||
        client != Matrix.of(context).client)
      return;
    setState(() {
      isSearching = false;
      this.roomSearchResult = roomSearchResult;
      this.userSearchResult = userSearchResult;
    });
  }

  void onSearchEnter(String text, {bool globalSearch = false}) {
    _rememberInboxPositionBeforeSearch();
    _searchGeneration++;
    _coolDown?.cancel();
    setState(() {
      isSearchMode = true;
      publicDiscovery = false;
      isSearching = false;
      roomSearchResult = null;
      userSearchResult = null;
    });
  }

  void discoverPublic() {
    if (searchController.text.trim().isEmpty) return;
    setState(() {
      isSearchMode = true;
      publicDiscovery = true;
    });
    _search();
  }

  void openNavrail() {
    setState(() {
      AppSettings.displayNavigationRail.setItem(
        !AppSettings.displayNavigationRail.value,
      );
    });
  }

  void startSearch() {
    _rememberInboxPositionBeforeSearch();
    setState(() {
      isSearchMode = true;
    });
    searchFocusNode.requestFocus();
    _coolDown?.cancel();
  }

  void cancelSearch({bool unfocus = true}) {
    final account = inboxAccountKey;
    final originalOffset = isSearchMode
        ? _preSearchInboxOffsets.remove(account)
        : null;
    final restoration = ++_searchScrollGeneration;
    _searchGeneration++;
    _coolDown?.cancel();
    setState(() {
      searchController.clear();
      isSearchMode = false;
      roomSearchResult = userSearchResult = null;
      isSearching = false;
      publicDiscovery = false;
    });
    if (unfocus) searchFocusNode.unfocus();
    if (originalOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            restoration != _searchScrollGeneration ||
            inboxAccountKey != account ||
            isSearchMode ||
            activeSpaceId != null ||
            !scrollController.hasClients)
          return;
        final position = scrollController.position;
        if (!position.hasContentDimensions) return;
        scrollController.jumpTo(
          originalOffset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      });
    }
  }

  void _rememberInboxPositionBeforeSearch() {
    if (isSearchMode) return;
    _searchScrollGeneration++;
    if (scrollController.hasClients && scrollController.position.hasPixels) {
      _preSearchInboxOffsets[inboxAccountKey] = scrollController.offset;
    }
  }

  final ScrollController scrollController = ScrollController();
  final ValueNotifier<bool> scrolledToTop = ValueNotifier(true);

  final StreamController<Client> _clientStream = StreamController.broadcast();

  Stream<Client> get clientStream => _clientStream.stream;

  void addAccountAction() => context.go('/rooms/settings/account');

  void _onScroll() {
    final newScrolledToTop = scrollController.position.pixels <= 0;
    if (newScrolledToTop != scrolledToTop.value) {
      scrolledToTop.value = newScrolledToTop;
    }
  }

  Future<void> editSpace(BuildContext context, String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();
    if (!context.mounted) return;
    context.push('/rooms/$spaceId/details');
  }

  // Needs to match GroupsSpacesEntry for 'separate group' checking.
  List<Room> get spaces =>
      Matrix.of(context).client.rooms.where((r) => r.isSpace).toList();

  String? get activeChat => widget.activeChat;
  String? get activeGroup => widget.activeGroup;

  void _processIncomingSharedMedia(List<SharedMediaFile> files) {
    if (!mounted) return;
    files.removeWhere(
      (file) => file.path.startsWith(AppConfig.deepLinkPrefix) == true,
    );
    if (files.isEmpty) return;

    showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: files.map((file) {
          if ({SharedMediaType.text, SharedMediaType.url}.contains(file.type)) {
            return TextShareItem(file.path);
          }
          return FileShareItem(
            XFile(
              file.path.replaceFirst('file://', ''),
              mimeType: file.mimeType,
            ),
          );
        }).toList(),
      ),
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
  void onLauncherShortcut(String action) =>
      UrlLauncher(context, action).launchUrl();

  @protected
  Future<void> bindLauncherShortcuts() async {
    if (!mounted) return;
    _shortcutOwner = this;
    final shortcuts = FlutterShortcuts();
    await shortcuts.initialize();
    if (!mounted || !identical(_shortcutOwner, this)) return;
    await shortcuts.listenAction(_dispatchShortcut);
  }

  void _joinCallWith(CallKitParams params) {
    if (!mounted) return;
    final roomId = params.extra?.tryGet<String>('roomId');
    final clientName = params.extra?.tryGet<String>('clientName');
    if (roomId != null) {
      context.go('/rooms/$roomId?client=$clientName&action=call');
    }
  }

  void _loadAccountInbox(Client client) {
    PersonalClient.of(client)
        .load()
        .then((_) {
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
    _initReceiveSharingIntent();
    _activeSpaceId = widget.activeSpace;

    scrollController.addListener(_onScroll);
    waitForInitialSync();
    if (PlatformInfos.isMobile) {
      _callEventSubscription = FlutterCallkitIncoming.onEvent.listen(
        _onCallEvent,
      );
      FlutterCallkitIncoming.activeCalls().then((calls) {
        final params = calls.firstOrNull;
        if (params == null) return;
        _joinCallWith(params);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (mounted) {
        searchServer = Matrix.of(
          context,
        ).store.getString(_serverStoreNamespace);
        Matrix.of(context).backgroundPush?.setupPush(context);
        UpdateNotifier.showUpdateDialog(context);
        UpdateNotifier.showUpdateAvailableBanner(context);
      }

      // Workaround for system UI overlay style not applied on app start
      SystemChrome.setSystemUIOverlayStyle(
        Theme.of(context).appBarTheme.systemOverlayStyle!,
      );
    });

    // Tags are not shown in the inbox; a saved tag filter falls back to all
    // chats. Room tags themselves are never changed here.
    activeFilter =
        ActiveFilter.values
            .where((filter) => filter != ActiveFilter.tag)
            .singleWhereOrNull(
              (filter) => AppSettings.chatFilter.value == filter.name,
            ) ??
        ActiveFilter.allChats;

    _processPushHelperCrashReport();

    super.initState();
    _loadAccountInbox(Matrix.of(context).client);
  }

  @override
  void dispose() {
    _cancelFirstSyncWait();
    if (identical(_shortcutOwner, this)) _shortcutOwner = null;
    _searchScrollGeneration++;
    _coolDown?.cancel();
    _intentDataStreamSubscription?.cancel();
    _intentFileStreamSubscription?.cancel();
    _callEventSubscription?.cancel();
    scrollController.removeListener(_onScroll);
    searchController.dispose();
    searchFocusNode.dispose();
    scrollController.dispose();
    scrolledToTop.dispose();
    _clientStream.close();
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
    ErrorReporter(
      context,
      'Push Helper has been crashed',
    ).onErrorCallback(report.first, StackTrace.fromString(report.last));
  }

  /// Long-press menu of an inbox row: Pin, Merge… (Unmerge on a merged
  /// person), Notifications and Ignore/Restore. Leave, block, tags, spaces
  /// and low priority are intentionally not offered here.
  Future<void> chatContextAction(
    Room room,
    BuildContext posContext, [
    Room? space,
  ]) async {
    final owner = personal;
    final account = inboxAccountKey;
    final box = posContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final projection = InboxProjection(owner);
    final l10n = L10n.of(context);
    final action = await showChatActionsMenu(
      posContext,
      anchor: anchor,
      title: projection.displayName(room),
      avatar: notionInboxAvatar(
        owner,
        projection,
        room,
        size: NotionSize.avatarSm,
      ),
      items: chatMenuItems(
        owner,
        room,
        pinLabel: l10n.pin,
        unpinLabel: l10n.unpin,
      ),
    );
    if (action == null) return;
    if (!mounted ||
        inboxAccountKey != account ||
        !identical(personal, owner) ||
        !identical(room.client, owner.client))
      return;

    switch (action) {
      case ChatMenuAction.pin:
        await showFutureLoadingDialog(
          context: context,
          future: () => NotionMetadataActions.setPinned(
            owner,
            InboxProjection(owner).entityFor(room),
            !InboxProjection(owner).metadataFor(room).isPinned,
          ),
        );
        return;
      case ChatMenuAction.merge:
        await mergeFrom(room);
        return;
      case ChatMenuAction.unmerge:
        final current = InboxProjection(owner).groupFor(room);
        if (current != null) await _unmerge(current);
        return;
      case ChatMenuAction.notifications:
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ChatPreferencesPage(personal: owner, room: room),
          ),
        );
        return;
      case ChatMenuAction.ignore:
        if (!canEditChatPreferences(
          owner,
          'org:${InboxProjection(owner).entityFor(room)}',
        ))
          return;
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
        await showFutureLoadingDialog(
          context: context,
          future: () => owner.put(
            'org:${metadata.entityId}',
            {
              ...?owner.values['org:${metadata.entityId}'],
              ...updated.toJson(),
            }.cast<String, dynamic>(),
          ),
        );
        return;
    }
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
            onPressed: () =>
                _runGroupChange(owner, account, () => undoMerge(owner, plan)),
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
    _runGroupChange(owner, account, () => owner.removeGroup(group.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chats unmerged'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                _runGroupChange(owner, account, () => owner.putGroup(group)),
          ),
        ),
      );
  }

  Future<void> setStatus() async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final currentPresence = await client.fetchCurrentPresence(client.userID!);
    if (!mounted) return;
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.setStatus,
      message: l10n.leaveEmptyToClearStatus,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
      hintText: l10n.statusExampleMessage,
      maxLines: 6,
      minLines: 1,
      maxLength: 255,
      initialText: currentPresence.statusMsg,
    );
    if (input == null) return;
    if (!mounted) return;
    if (!PersonalPrivacy.policy.allowOnlinePresence) return;
    await showFutureLoadingDialog(
      context: context,
      future: () => client.setPresence(
        client.userID!,
        PresenceType.online,
        statusMsg: input,
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

  void setActiveFilter(ActiveFilter filter, String? tag) {
    if (filter == ActiveFilter.tag && tag == null) {
      throw ('Must set a tag when setting filter to tags!');
    }
    setState(() {
      activeTag = tag;
      activeFilter = filter;
      if (filter == ActiveFilter.groups) {
        personalFilter = InboxFilter.groups;
        personalLabel = null;
      }
      if (filter == ActiveFilter.messages) {
        personalFilter = InboxFilter.inbox;
        personalLabel = null;
      }
    });
    AppSettings.chatFilter.setItem(
      filter == ActiveFilter.tag ? tag! : filter.name,
    );
  }

  void setActiveClient(Client client) {
    _cancelFirstSyncWait();
    _searchScrollGeneration++;
    _searchGeneration++;
    _coolDown?.cancel();
    context.go('/rooms');
    setState(() {
      activeFilter = ActiveFilter.allChats;
      personalFilter = InboxFilter.inbox;
      personalLabel = null;
      searchController.clear();
      isSearchMode = false;
      publicDiscovery = false;
      isSearching = false;
      roomSearchResult = null;
      userSearchResult = null;
      _activeSpaceId = null;
      Matrix.of(context).setActiveClient(client);
    });
    _clientStream.add(client);
    _loadAccountInbox(client);
    waitForInitialSync();
  }

  void setActiveBundle(String bundle) {
    _cancelFirstSyncWait();
    _searchScrollGeneration++;
    _searchGeneration++;
    _coolDown?.cancel();
    context.go('/rooms');
    setState(() {
      _activeSpaceId = null;
      personalFilter = InboxFilter.inbox;
      personalLabel = null;
      searchController.clear();
      isSearchMode = false;
      publicDiscovery = false;
      isSearching = false;
      roomSearchResult = null;
      userSearchResult = null;
      Matrix.of(context).activeBundle = bundle;
      if (!Matrix.of(
        context,
      ).currentBundle!.any((client) => client == Matrix.of(context).client)) {
        Matrix.of(
          context,
        ).setActiveClient(Matrix.of(context).currentBundle!.first);
      }
    });
    final client = Matrix.of(context).client;
    _loadAccountInbox(client);
    waitForInitialSync();
  }

  Future<void> editBundlesForAccount(
    String? userId,
    String? activeBundle,
  ) async {
    final l10n = L10n.of(context);
    final client = Matrix.of(
      context,
    ).widget.clients[Matrix.of(context).getClientIndexByMatrixId(userId!)];
    final action = await showModalActionPopup<EditBundleAction>(
      context: context,
      title: L10n.of(context).editBundlesForAccount,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: EditBundleAction.addToBundle,
          label: L10n.of(context).addToBundle,
        ),
        if (activeBundle != client.userID)
          AdaptiveModalAction(
            value: EditBundleAction.removeFromBundle,
            label: L10n.of(context).removeFromBundle,
          ),
      ],
    );
    if (action == null) return;
    switch (action) {
      case EditBundleAction.addToBundle:
        if (!mounted) return;
        final bundle = await showTextInputDialog(
          context: context,
          title: l10n.bundleName,
          hintText: l10n.bundleName,
        );
        if (bundle == null || bundle.isEmpty || bundle.isEmpty) return;
        if (!mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => client.setAccountBundle(bundle),
        );
        break;
      case EditBundleAction.removeFromBundle:
        if (!mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => client.removeFromAccountBundle(activeBundle!),
        );
    }
  }

  String? get secureActiveBundle {
    if (Matrix.of(context).activeBundle == null ||
        !Matrix.of(
          context,
        ).accountBundles.keys.contains(Matrix.of(context).activeBundle)) {
      return Matrix.of(context).accountBundles.keys.first;
    }
    return Matrix.of(context).activeBundle;
  }

  @override
  Widget build(BuildContext context) => ChatListView(this);
}

enum EditBundleAction { addToBundle, removeFromBundle }

/// Long-press actions of an inbox row ([ChatListController.chatContextAction]).
typedef ChatContextAction = ChatMenuAction;
