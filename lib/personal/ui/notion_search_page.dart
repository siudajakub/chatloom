// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show notionInboxAvatar, personalConversationAvatar;
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_start_chat.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_search_page.dart'
    show PersonalSearchMemo;
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart'
    show NotionNetworkGlyph;
import 'package:chatloom/personal/ui/notion_search_controls.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The one place to find and start conversations (Telegram, Messenger):
/// chats, people from the connected networks and recent messages.
///
/// * Typing filters on the device: chats and people of the account's
///   bridged chats, the bridges' contact lists (fetched without the query)
///   and the latest message of each chat.
/// * Sending the query to a network ("Search WhatsApp for …", "Look up
///   +48… on Telegram") and starting a chat through a bridge are explicit
///   taps; starting a chat asks first.
/// * Matrix itself is never searched: no user directory, no public rooms,
///   no Matrix ids.
class NotionSearchPage extends StatefulWidget {
  const NotionSearchPage({
    super.key,
    required this.personal,
    required this.inbox,
    required this.directory,
    required this.onOpenRoom,
    required this.onOpenMessage,
    required this.onSearchHistory,
    this.onSelectView,
    this.closeOnOpen,
    this.initialQuery = '',
  });

  final PersonalClient personal;
  final InboxController inbox;
  final BridgeDirectory directory;

  /// Opens a conversation (the inbox's own tap handling: merged persons,
  /// invites).
  final ValueChanged<Room> onOpenRoom;
  final void Function(Room room, String eventId) onOpenMessage;

  /// Opens the history search, prefilled with the query.
  final ValueChanged<String> onSearchHistory;

  /// Shows an inbox view (Unread, Archive, …) and closes the search.
  final ValueChanged<InboxFilter>? onSelectView;

  /// Close the search before opening a result. By default only in the
  /// two-column layout, where the chat opens beside the inbox; on phones the
  /// search stays under the chat, so Back returns to the results (Telegram).
  final bool? closeOnOpen;
  final String initialQuery;

  /// Typing applies after this pause (as in the history search).
  static const typingDebounce = Duration(milliseconds: 150);

  /// Result rows per section before "Show more".
  static const chatLimit = 6, peopleLimit = 5, messageLimit = 5;

  @override
  State<NotionSearchPage> createState() => _NotionSearchPageState();
}

class _NotionSearchPageState extends State<NotionSearchPage> {
  late final _query = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode(debugLabel: 'Search');
  late String _applied = widget.initialQuery.trim();
  Timer? _typing;
  final _expanded = <String>{};
  final _starting = <String>{};
  bool _calloutDismissed = false;

  final _bridgesMemo = PersonalSearchMemo<List<BridgeEndpoint>>();
  final _peopleMemo = PersonalSearchMemo<List<BridgePerson>>();
  final _chatsMemo = PersonalSearchMemo<List<SearchChatCandidate>>();
  final _messagesMemo = PersonalSearchMemo<List<SearchMessageCandidate>>();
  final _resultsMemo = PersonalSearchMemo<UnifiedSearchResults>();

  Client get _client => widget.personal.client;
  BridgeDirectory get _directory => widget.directory;

  @override
  void initState() {
    super.initState();
    _directory.addListener(_directoryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // whoami + capabilities only: no query leaves the device.
      unawaited(_directory.probe(_bridges()));
      if (_applied.isNotEmpty) _loadContacts();
    });
  }

  @override
  void didUpdateWidget(NotionSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.directory, widget.directory)) {
      oldWidget.directory.removeListener(_directoryChanged);
      widget.directory.addListener(_directoryChanged);
    }
  }

  @override
  void dispose() {
    _typing?.cancel();
    _directory.removeListener(_directoryChanged);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _directoryChanged() {
    if (!mounted) return;
    if (_applied.isNotEmpty) _loadContacts();
    setState(() {});
  }

  void _loadContacts() => unawaited(_directory.loadContacts(_bridges()));

  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(NotionSearchPage.typingDebounce, _apply);
  }

  void _apply() {
    _typing?.cancel();
    _typing = null;
    final text = _query.text.trim();
    if (!mounted || text == _applied) return;
    setState(() {
      _applied = text;
      _expanded.clear();
    });
    if (text.isNotEmpty) _loadContacts();
  }

  void _close() => Navigator.of(context).maybePop();

  // -------------------------------------------------------------------------
  // Data (memoised per inbox generation; typing reuses it)
  // -------------------------------------------------------------------------

  Object get _generation => (widget.inbox, widget.inbox.generation);

  List<BridgeEndpoint> _bridges() =>
      _bridgesMemo.resolve(_generation, () => discoverBridges(_client.rooms));

  List<BridgePerson> _people() => _peopleMemo.resolve(_generation, () {
    final projection = widget.inbox.projection;
    final own = OwnSenderResolver.of(_client);
    return indexBridgePeople(
      rooms: _client.rooms,
      bridges: _bridges(),
      ownUserId: _client.userID ?? '',
      isOwn: (id, roomId) => own.isOwnSender(id, roomId: roomId),
      isTechnical: (room) => projection.classifier.classify(room).technical,
      roomName: projection.displayName,
    );
  });

  List<SearchChatCandidate> _chats() => _chatsMemo.resolve(_generation, () {
    final index = widget.inbox.index;
    final projection = index.projection;
    return [
      for (final record in index.records)
        if (!record.technical)
          SearchChatCandidate(
            record: record,
            roomIds: [
              record.representativeRoomId,
              if (record.entityId.startsWith('person:'))
                ...?projection
                    .groupById(record.entityId.substring('person:'.length))
                    ?.members
                    .map((m) => m.roomId),
            ],
          ),
    ];
  });

  List<SearchMessageCandidate> _messages() =>
      _messagesMemo.resolve(_generation, () {
        final index = widget.inbox.index;
        final projection = index.projection;
        final result = <SearchMessageCandidate>[];
        for (final room in index.rooms) {
          if (room.membership != Membership.join ||
              PersonalPrivacy.isJournal(room) ||
              projection.classifier.classify(room).technical) {
            continue;
          }
          final event = room.lastEvent;
          if (event == null ||
              event.redacted ||
              event.type != EventTypes.Message) {
            continue;
          }
          final text = personalPreviewLabel(event);
          if (text.trim().isEmpty) continue;
          result.add(
            SearchMessageCandidate(
              roomId: room.id,
              eventId: event.eventId,
              chatName: projection.displayName(room),
              text: text,
              preview: personalEventPreview(event),
              time: event.originServerTs,
            ),
          );
        }
        return result;
      });

  UnifiedSearchResults _results() => _resultsMemo.resolve(
    (_applied, _generation, _directory, _directory.revision),
    () => mergeUnifiedSearch(
      query: _applied,
      chats: _chats(),
      people: _people(),
      bridges: _bridges(),
      remote: _directory.stateOf,
      messages: _messages(),
      roomExists: (id) => _client.getRoomById(id) != null,
    ),
  );

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  bool get _closeOnOpen =>
      widget.closeOnOpen ?? ChatLoomThemes.isColumnMode(context);

  void _openRoom(Room room) {
    final open = widget.onOpenRoom;
    if (_closeOnOpen) Navigator.of(context).pop();
    open(room);
  }

  /// Inbox views replace the search.
  void Function(T) _closing<T>(void Function(T) select) => (value) {
    Navigator.of(context).pop();
    select(value);
  };

  void _openRoomId(String roomId) {
    final room = _client.getRoomById(roomId);
    if (room != null) _openRoom(room);
  }

  void _openMessage(SearchMessageCandidate message) {
    final room = _client.getRoomById(message.roomId);
    if (room == null) return;
    final open = widget.onOpenMessage;
    if (_closeOnOpen) Navigator.of(context).pop();
    open(room, message.eventId);
  }

  void _searchHistory() => widget.onSearchHistory(_applied);

  Future<void> _tapPerson(SearchPersonHit hit, SearchNetworkGroup group) async {
    final roomId = hit.roomId;
    if (roomId != null) {
      _openRoomId(roomId);
      return;
    }
    final network = group.bridge.label;
    if (!group.canStartChats || hit.identifier == null) {
      await showNotionDialog<void>(
        context: context,
        title: 'Can’t start a new chat yet',
        message: switch (group.status) {
          BridgeRemoteStatus.notLoggedIn =>
            'Your $network bridge isn’t signed in. Existing chats still work.',
          BridgeRemoteStatus.ready =>
            'Your $network bridge doesn’t support starting chats.',
          _ =>
            'ChatLoom can’t reach your $network bridge, so it can’t open a '
                'chat with ${hit.name}. Existing chats still work.',
        },
        actions: (context) => [
          NotionButton(
            label: MaterialLocalizations.of(context).okButtonLabel,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
      return;
    }
    if (_starting.contains(hit.key)) return;
    final confirmed = await confirmBridgedChat(
      context,
      name: hit.name,
      network: network,
    );
    if (!confirmed || !mounted) return;
    setState(() => _starting.add(hit.key));
    try {
      final room = await startBridgedChat(
        directory: _directory,
        bridge: group.bridge,
        identifier: hit.identifier!,
        loginId: hit.loginId,
        client: _client,
      );
      if (!mounted) return;
      _openRoom(room);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(bridgedChatError(error, network))));
    } finally {
      if (mounted) setState(() => _starting.remove(hit.key));
    }
  }

  void _retry() => unawaited(_directory.probe(_bridges(), force: true));

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.inbox,
    builder: (context, _) {
      final empty = _applied.isEmpty;
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          toolbarHeight: NotionSize.headerHeight,
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          flexibleSpace: const NotionGlassBar(),
          leading: NotionIconButton(
            icon: Icons.chevron_left,
            label: 'Close search',
            onPressed: _close,
          ),
          titleSpacing: 0,
          title: NotionSearchField(
            controller: _query,
            focusNode: _focus,
            autofocus: true,
            onChanged: _typed,
            onSubmitted: (_) => _apply(),
            onClose: _close,
          ),
          actions: const [SizedBox(width: NotionSpace.sm)],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NotionSize.contentMaxWidth,
            ),
            child: NotionFadeThrough(
              alignment: Alignment.topCenter,
              child: empty
                  ? _EmptySearch(
                      key: const ValueKey('search-empty'),
                      bridges: _bridges(),
                      directory: _directory,
                      onSelectView: widget.onSelectView == null
                          ? null
                          : _closing(widget.onSelectView!),
                      onRetry: _retry,
                    )
                  : NotionEntranceScope(
                      key: const ValueKey('search-results'),
                      // Inside the Scaffold body the top padding includes
                      // the glass header, so results scroll under it.
                      child: Builder(builder: _resultsList),
                    ),
            ),
          ),
        ),
      );
    },
  );

  Widget _resultsList(BuildContext context) {
    final results = _results();
    final items = _items(results);
    final keys = <Key, int>{
      for (final (index, item) in items.indexed) item.key: index,
    };
    final padding = MediaQuery.paddingOf(context);
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        NotionSpace.inset,
        padding.top + NotionSpace.xs,
        NotionSpace.inset,
        padding.bottom + NotionSpace.xxl,
      ),
      itemCount: items.length,
      findChildIndexCallback: (key) => keys[key],
      itemBuilder: (context, index) {
        final item = items[index];
        return NotionEntrance(
          key: item.key,
          playKey: item.key,
          rise: NotionMotion.riseList,
          child: item.build(context),
        );
      },
    );
  }

  List<_Item> _items(UnifiedSearchResults results) {
    final query = _applied;
    final items = <_Item>[];
    if (results.isEmpty && !_anyChecking()) {
      items.add(
        _Item(
          'empty',
          (context) => Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xxl),
            child: NotionEmptyState(
              icon: Icons.search_off,
              title: 'No results for “$query”',
              message:
                  'Try another name, a phone number or @username, or search '
                  'the message history.',
              action: NotionButton(
                label: 'Search message history',
                icon: Icons.manage_search,
                onPressed: _searchHistory,
              ),
            ),
          ),
        ),
      );
      return items;
    }

    // Chats.
    if (results.chats.isNotEmpty) {
      items.add(_header('chats', 'Chats'));
      final all = _expanded.contains('chats');
      final shown = all
          ? results.chats
          : results.chats.take(NotionSearchPage.chatLimit);
      for (final hit in shown) {
        items.add(
          _Item('chat:${hit.record.entityId}', (c) => _chatRow(c, hit)),
        );
      }
      final hidden = results.chats.length - NotionSearchPage.chatLimit;
      if (!all && hidden > 0) {
        items.add(_more('chats', 'Show $hidden more chats'));
      }
    }

    // People by network.
    final callout = _callout();
    if (callout != null) items.add(callout);
    for (final group in results.networks) {
      final key = 'net:${group.bridge.botId}';
      items.add(_Item('$key:header', (c) => _networkHeader(c, group)));
      final all = _expanded.contains(key);
      final shown = all
          ? group.people
          : group.people.take(NotionSearchPage.peopleLimit);
      for (final hit in shown) {
        items.add(_Item('$key:${hit.key}', (c) => _personRow(c, hit, group)));
      }
      final hidden = group.people.length - NotionSearchPage.peopleLimit;
      if (!all && hidden > 0) items.add(_more(key, 'Show $hidden more'));
      if (group.lookup case final lookup?) {
        items.add(_Item('$key:lookup', (c) => _lookupRow(c, group, lookup)));
      }
      if (group.canSearch) {
        items.add(_Item('$key:search', (c) => _searchRow(c, group, query)));
      }
    }

    // Messages.
    items.add(_header('messages', 'Messages'));
    final all = _expanded.contains('messages');
    final shown = all
        ? results.messages
        : results.messages.take(NotionSearchPage.messageLimit);
    for (final message in shown) {
      items.add(
        _Item('msg:${message.eventId}', (c) => _messageRow(c, message)),
      );
    }
    final hidden = results.messages.length - NotionSearchPage.messageLimit;
    if (!all && hidden > 0) items.add(_more('messages', 'Show $hidden more'));
    items.add(
      _Item(
        'history',
        (context) => NotionListRow(
          leading: const Icon(Icons.manage_search, size: NotionSize.icon),
          title: 'Search message history for “$query”',
          subtitle: results.messages.isEmpty
              ? 'Only the latest message of each chat is searched here.'
              : 'Older messages of a chat you choose',
          onTap: _searchHistory,
        ),
      ),
    );
    return items;
  }

  bool _anyChecking() => _bridges().any((bridge) {
    final status = _directory.stateOf(bridge).status;
    return status == BridgeRemoteStatus.checking ||
        _directory.stateOf(bridge).contactsLoading;
  });

  /// One note when no bridge can be asked for contacts.
  _Item? _callout() {
    final bridges = _bridges();
    if (_calloutDismissed || bridges.isEmpty) return null;
    final unavailable = bridges.every(
      (b) => _directory.stateOf(b).status == BridgeRemoteStatus.unavailable,
    );
    if (!unavailable) return null;
    final disabled = _directory.disabledReason;
    return _Item(
      'bridges-unavailable',
      (context) => Padding(
        padding: const EdgeInsets.only(top: NotionSpace.md),
        child: NotionCallout(
          icon: Icons.link_off,
          title: 'Only people from your chats',
          message:
              disabled ??
              'ChatLoom can’t reach your bridges’ contact lists, so it can’t '
                  'start new chats yet.',
          actionLabel: disabled == null ? 'Retry' : null,
          onAction: disabled == null ? _retry : null,
          onDismiss: () => setState(() => _calloutDismissed = true),
        ),
      ),
    );
  }

  _Item _header(String key, String title) => _Item(
    'header:$key',
    (context) => NotionSectionHeader(
      title: title,
      padding: const EdgeInsets.only(
        top: NotionSpace.lg,
        bottom: NotionSpace.xxs,
      ),
    ),
  );

  _Item _more(String section, String label) => _Item(
    'more:$section',
    (context) => NotionListRow(
      leading: const Icon(Icons.expand_more, size: NotionSize.icon),
      title: label,
      trailing: const SizedBox.shrink(),
      onTap: () => setState(() => _expanded.add(section)),
    ),
  );

  Widget _chatRow(BuildContext context, SearchChatHit hit) {
    final record = hit.record;
    final room = _client.getRoomById(record.representativeRoomId);
    if (room == null) return const SizedBox.shrink();
    final projection = widget.inbox.projection;
    final networks = record.networks.toSet().toList();
    final details = [
      ...networks.map(notionNetworkLabel),
      if (record.isGroup) 'Group',
      if (record.metadata.archived) 'Archived',
      if (record.metadata.ignored) 'Ignored',
    ];
    return NotionInboxRow(
      avatar: notionInboxAvatar(widget.personal, projection, room),
      name: record.displayName,
      preview: details.join(' · '),
      previewLeading: networks.length == 1
          ? NotionNetworkGlyph(
              network: networks.single,
              size: NotionSize.iconSm,
            )
          : null,
      time: record.lastActivity?.localizedTimeShort(context),
      unreadCount: record.unreadCount,
      onTap: () => _openRoom(room),
    );
  }

  Widget _networkHeader(BuildContext context, SearchNetworkGroup group) {
    final tokens = context.notion;
    final caption = switch (group.status) {
      _ when group.loadingContacts => null,
      BridgeRemoteStatus.ready => null,
      BridgeRemoteStatus.checking || BridgeRemoteStatus.unknown => null,
      BridgeRemoteStatus.notLoggedIn => 'Bridge not signed in',
      BridgeRemoteStatus.unavailable => 'From your chats',
    };
    final busy =
        group.loadingContacts || group.status == BridgeRemoteStatus.checking;
    return Padding(
      padding: const EdgeInsets.only(
        top: NotionSpace.lg,
        bottom: NotionSpace.xxs,
      ),
      child: Semantics(
        header: true,
        label: [group.bridge.label, ?caption].join(', '),
        excludeSemantics: true,
        child: Row(
          children: [
            NotionNetworkGlyph(
              network: group.bridge.network,
              size: NotionSize.iconSm,
            ),
            const SizedBox(width: NotionSpace.xs),
            Expanded(
              child: Text(
                group.bridge.label,
                style: tokens.typography.sectionLabel,
              ),
            ),
            if (busy)
              const NotionDelayedSpinner(size: NotionSize.iconSm)
            else if (caption != null)
              Text(caption, style: tokens.typography.captionMuted),
          ],
        ),
      ),
    );
  }

  Widget _personRow(
    BuildContext context,
    SearchPersonHit hit,
    SearchNetworkGroup group,
  ) {
    final secondary = context.notion.colors.textSecondary;
    final starting = _starting.contains(hit.key);
    final action = hit.hasChat
        ? null
        : starting
        ? const Padding(
            padding: EdgeInsets.only(left: NotionSpace.xs),
            child: NotionDelayedSpinner(),
          )
        : group.canStartChats
        ? Padding(
            padding: const EdgeInsets.only(left: NotionSpace.xs),
            child: Tooltip(
              message: 'Start chat',
              child: Icon(
                Icons.add_comment_outlined,
                size: NotionSize.icon,
                color: secondary,
              ),
            ),
          )
        : null;
    return NotionInboxRow(
      avatar: personalConversationAvatar(
        widget.personal,
        entityId: hit.key,
        avatar: hit.avatar,
        name: hit.name,
        client: _client,
      ),
      name: hit.name,
      preview: hit.subtitle ?? '',
      action: action,
      onTap: () => unawaited(_tapPerson(hit, group)),
    );
  }

  Widget _searchRow(
    BuildContext context,
    SearchNetworkGroup group,
    String query,
  ) {
    final network = group.bridge.label;
    return NotionListRow(
      leading: const Icon(Icons.travel_explore, size: NotionSize.icon),
      title: 'Search $network for “$query”',
      subtitle: group.searching
          ? 'Searching…'
          : group.searched
          ? (group.error ?? 'Search done. New people appear above.')
          : 'Sends “$query” to $network',
      trailing: group.searching ? const NotionDelayedSpinner() : null,
      onTap: group.searching || group.searched
          ? null
          : () => unawaited(_directory.searchUsers(group.bridge, query)),
    );
  }

  Widget _lookupRow(
    BuildContext context,
    SearchNetworkGroup group,
    SearchIdentifier lookup,
  ) {
    final network = group.bridge.label;
    final notFound =
        group.lookedUp &&
        _directory.stateOf(group.bridge).lookups[lookup.value] == null;
    return NotionListRow(
      leading: const Icon(Icons.person_search_outlined, size: NotionSize.icon),
      title: 'Look up ${lookup.display} on $network',
      subtitle: group.lookingUp
          ? 'Looking up…'
          : notFound
          ? (group.error ?? 'No $network account found')
          : group.lookedUp
          ? 'Found. Tap the person above to open the chat.'
          : switch (lookup.kind) {
              SearchIdentifierKind.phone => 'Sends the number to $network',
              SearchIdentifierKind.email => 'Sends the address to $network',
              SearchIdentifierKind.username => 'Sends the username to $network',
            },
      trailing: group.lookingUp ? const NotionDelayedSpinner() : null,
      onTap: group.lookingUp || group.lookedUp
          ? null
          : () => unawaited(_directory.lookUp(group.bridge, lookup)),
    );
  }

  Widget _messageRow(BuildContext context, SearchMessageCandidate message) {
    final room = _client.getRoomById(message.roomId);
    if (room == null) return const SizedBox.shrink();
    return NotionInboxRow(
      avatar: notionInboxAvatar(widget.personal, widget.inbox.projection, room),
      name: message.chatName,
      preview: message.preview,
      time: message.time.localizedTimeShort(context),
      onTap: () => _openMessage(message),
    );
  }
}

/// One row of the result list; [key] keeps rows (and their elements) while
/// typing reorders them.
class _Item {
  _Item(String id, this.build) : key = ValueKey('search:$id');
  final Key key;
  final WidgetBuilder build;
}

/// Before typing: inbox views to jump to and what each connected
/// network can do.
class _EmptySearch extends StatelessWidget {
  const _EmptySearch({
    super.key,
    required this.bridges,
    required this.directory,
    required this.onRetry,
    this.onSelectView,
  });

  final List<BridgeEndpoint> bridges;
  final BridgeDirectory directory;
  final VoidCallback onRetry;
  final ValueChanged<InboxFilter>? onSelectView;

  static const _views = <(InboxFilter, IconData)>[
    (InboxFilter.unread, Icons.mark_chat_unread_outlined),
    (InboxFilter.unanswered, Icons.reply_outlined),
    (InboxFilter.drafts, Icons.edit_note),
    (InboxFilter.direct, Icons.person_outline),
    (InboxFilter.archive, Icons.archive_outlined),
    (InboxFilter.lowPriority, Icons.low_priority),
    (InboxFilter.all, Icons.all_inbox_outlined),
  ];

  String _status(BridgeRemoteState state) => switch (state.status) {
    BridgeRemoteStatus.ready when state.contactsError != null =>
      'Start chats; contacts unavailable',
    BridgeRemoteStatus.ready when state.capabilities.createDm =>
      'Find people and start chats',
    BridgeRemoteStatus.ready => 'Find people',
    BridgeRemoteStatus.unknown ||
    BridgeRemoteStatus.checking => 'Checking the bridge…',
    BridgeRemoteStatus.notLoggedIn => 'Bridge not signed in',
    BridgeRemoteStatus.unavailable =>
      'People from your chats only'
          '${state.reason == null ? '' : ' (${state.reason})'}',
  };

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final selectView = onSelectView;
    final unavailable = bridges.any(
      (b) => directory.stateOf(b).status == BridgeRemoteStatus.unavailable,
    );
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        NotionSpace.inset,
        padding.top + NotionSpace.xs,
        NotionSpace.inset,
        padding.bottom + NotionSpace.xxl,
      ),
      children: [
        if (selectView != null) ...[
          const NotionSectionHeader(
            title: 'Show',
            padding: EdgeInsets.only(
              top: NotionSpace.md,
              bottom: NotionSpace.xs,
            ),
          ),
          Wrap(
            spacing: NotionSpace.xs,
            runSpacing: NotionSpace.xs,
            children: [
              for (final (view, icon) in _views)
                NotionGlassPill(
                  icon: icon,
                  label: inboxViewLabel(view),
                  onPressed: () => selectView(view),
                ),
            ],
          ),
        ],
        if (bridges.isNotEmpty) ...[
          NotionSectionHeader(
            title: 'Your networks',
            trailing: unavailable && directory.disabledReason == null
                ? NotionButton.ghost(label: 'Retry', onPressed: onRetry)
                : null,
          ),
          for (final bridge in bridges)
            NotionListRow(
              key: ValueKey('search-network:${bridge.botId}'),
              leading: NotionNetworkGlyph(
                network: bridge.network,
                size: NotionSize.icon,
              ),
              title: bridge.label,
              subtitle: _status(directory.stateOf(bridge)),
            ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: NotionSpace.lg),
          child: Text(
            'Type a name to find chats, people on your networks and recent '
            'messages. Phone numbers and @usernames can be looked up on '
            'networks that support it.',
            style: context.notion.typography.footnoteMuted,
          ),
        ),
      ],
    );
  }
}
