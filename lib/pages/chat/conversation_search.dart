// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/local_message_search.dart';
import 'package:chatloom/personal/ui/conversation_content_controller.dart'
    show MatrixContentSource;
import 'package:chatloom/personal/ui/notion_search_controls.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// In-chat search (FX-03), Telegram's search mode: the conversation header
/// becomes a search field, a bar in place of the composer says "3 of 17"
/// with older/newer arrows, and every step scrolls the open timeline to the
/// hit and flashes it (no second chat page). The results list shows sender,
/// date and the matching words in bold.
///
/// Hits come from the loaded timeline(s) and from the messages already
/// stored on this device (read page by page from the encrypted store, at
/// most [ConversationSearchController.maxStoredPerRoom] per room). Older
/// history is fetched from the server only on an explicit tap.
class ConversationSearchController extends ChangeNotifier {
  ConversationSearchController({
    required this.rooms,
    required this.loaded,
    required this.jump,
    this.read = readStoredEvents,
    this.older,
    this.pageSize = 200,
    this.maxStoredPerRoom = 2000,
  });

  /// The rooms of the conversation (one, or a person's sources).
  final List<Room> Function() rooms;

  /// Events already in the open timeline(s), any order.
  final Iterable<Event> Function() loaded;

  /// Shows a hit in the open timeline (loading it when needed).
  final Future<void> Function(Event event) jump;
  final StoredEventReader read;

  /// One older page of a room from the server (test seam); by default the
  /// room's history with the SDK's decryption.
  final Future<({List<Event> events, String? next})> Function(
    Room room,
    String? cursor,
  )?
  older;
  final int pageSize, maxStoredPerRoom;

  late final TextEditingController text = TextEditingController();
  late final FocusNode focus = FocusNode(debugLabel: 'Conversation search');

  LocalMessagePool _pool = LocalMessagePool();
  bool _disposed = false;
  bool _active = false;
  bool _listOpen = false;
  List<String> _terms = const [];
  List<LocalMessageHit> _hits = const [];
  int _index = -1;
  bool _scanning = false, _storeComplete = false, _storeFailed = false;
  bool _remoteBusy = false, _remoteFailed = false;
  final _remoteCursors = <String, String?>{};
  final _remoteEnded = <String>{};
  int _generation = 0;

  bool get active => _active;

  /// The results list covers the timeline.
  bool get listOpen => _listOpen;
  List<String> get terms => _terms;
  List<LocalMessageHit> get hits => _hits;

  /// The hit the timeline shows (0 = newest), or -1 before the first step.
  int get index => _index;
  LocalMessageHit? get current =>
      _index >= 0 && _index < _hits.length ? _hits[_index] : null;

  /// Stored messages are still being read.
  bool get scanning => _scanning;
  bool get storeComplete => _storeComplete;
  bool get storeFailed => _storeFailed;
  bool get remoteBusy => _remoteBusy;
  bool get remoteFailed => _remoteFailed;

  /// Whether "Search older messages" can still fetch from the server.
  bool get canSearchOlder =>
      _storeComplete &&
      rooms().any(
        (room) =>
            !_remoteEnded.contains(room.id) &&
            (_remoteCursors[room.id] ?? room.prev_batch) != null,
      );

  bool get canStepOlder => _hits.isNotEmpty && _index + 1 < _hits.length;
  bool get canStepNewer => _index > 0;

  /// "3 of 17", "17 results", "Searching…", "No results" or nothing.
  String get status {
    if (_terms.isEmpty) return '';
    if (_hits.isEmpty) {
      return _scanning || _remoteBusy ? 'Searching…' : 'No results';
    }
    if (_index < 0) {
      return _hits.length == 1 ? '1 result' : '${_hits.length} results';
    }
    return '${_index + 1} of ${_hits.length}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Enters search mode (again: focuses the field).
  void open() {
    if (_disposed) return;
    if (_active) {
      focus.requestFocus();
      return;
    }
    _active = true;
    _listOpen = false;
    final generation = ++_generation;
    _notify();
    unawaited(_scanStore(generation));
  }

  /// Leaves search mode and forgets what it read.
  void close() {
    if (!_active || _disposed) return;
    _generation++;
    _active = false;
    _listOpen = false;
    _terms = const [];
    _hits = const [];
    _index = -1;
    _scanning = _storeComplete = _storeFailed = false;
    _remoteBusy = _remoteFailed = false;
    _remoteCursors.clear();
    _remoteEnded.clear();
    _pool = LocalMessagePool();
    text.clear();
    focus.unfocus();
    _notify();
  }

  /// Filters for [query] while typing; the results list opens with it.
  void setQuery(String query) {
    if (!_active) return;
    final terms = localSearchTerms(query);
    if (_sameTerms(terms, _terms)) return;
    _terms = terms;
    _index = -1;
    _refilter();
    _listOpen = terms.isNotEmpty;
    _notify();
  }

  static bool _sameTerms(List<String> a, List<String> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  /// Enter: shows the newest hit (or the current one again).
  void submit() {
    if (_hits.isEmpty) return;
    select(_index < 0 ? 0 : _index);
  }

  /// The up arrow: the next older hit.
  void stepOlder() {
    if (canStepOlder) select(_index + 1);
  }

  /// The down arrow: the next newer hit.
  void stepNewer() {
    if (canStepNewer) select(_index - 1);
  }

  /// Shows hit [index] in the timeline and closes the list.
  void select(int index) {
    if (index < 0 || index >= _hits.length) return;
    _index = index;
    _listOpen = false;
    focus.unfocus();
    _notify();
    unawaited(jump(_hits[index].event));
  }

  void toggleList() {
    if (_terms.isEmpty) return;
    _listOpen = !_listOpen;
    _notify();
  }

  void _refilter() {
    _pool.add(loaded());
    if (_terms.isEmpty) {
      _hits = const [];
      _index = -1;
      return;
    }
    final currentId = current?.eventId;
    _hits = _pool.search(_terms);
    if (currentId != null) {
      _index = _hits.indexWhere((hit) => hit.eventId == currentId);
    }
  }

  bool _current(int generation) =>
      !_disposed && _active && generation == _generation;

  Future<void> _scanStore(int generation) async {
    _scanning = true;
    for (final room in rooms()) {
      for (var start = 0; start < maxStoredPerRoom; start += pageSize) {
        List<Event> page;
        try {
          page = await read(room, start, pageSize);
        } catch (_) {
          if (!_current(generation)) return;
          _storeFailed = true;
          break;
        }
        if (!_current(generation)) return;
        if (_pool.add(page) && _terms.isNotEmpty) {
          _refilter();
          _notify();
        }
        if (page.length < pageSize) break;
      }
    }
    if (!_current(generation)) return;
    _scanning = false;
    _storeComplete = true;
    _notify();
  }

  /// One older page per room from the server, on an explicit tap only.
  Future<void> searchOlder() async {
    if (_remoteBusy || !_active || !canSearchOlder) return;
    final generation = _generation;
    _remoteBusy = true;
    _remoteFailed = false;
    _notify();
    for (final room in rooms()) {
      if (_remoteEnded.contains(room.id)) continue;
      final cursor = _remoteCursors[room.id] ?? room.prev_batch;
      if (cursor == null) continue;
      try {
        final page = await (older ?? _serverPage)(room, cursor);
        if (!_current(generation)) return;
        _pool.add(page.events);
        if (page.next == null || page.next == cursor) {
          _remoteEnded.add(room.id);
        } else {
          _remoteCursors[room.id] = page.next;
        }
      } catch (_) {
        if (!_current(generation)) return;
        _remoteFailed = true;
      }
    }
    if (!_current(generation)) return;
    _remoteBusy = false;
    _refilter();
    _notify();
  }

  static Future<({List<Event> events, String? next})> _serverPage(
    Room room,
    String? cursor,
  ) async {
    final page = await MatrixContentSource(room).older(cursor);
    return (events: page.events, next: page.next);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    text.dispose();
    focus.dispose();
    super.dispose();
  }
}

/// Lets a control deep in a conversation page (the ⋯ menu's "Search
/// conversation") open the page's own search mode.
class ConversationSearchScope extends InheritedWidget {
  const ConversationSearchScope({
    super.key,
    required this.open,
    required super.child,
  });

  final VoidCallback open;

  /// Opens the enclosing conversation's search; false when there is none.
  static bool maybeOpen(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<ConversationSearchScope>();
    if (scope == null) return false;
    scope.open();
    return true;
  }

  @override
  bool updateShouldNotify(ConversationSearchScope oldWidget) => false;
}

/// The header's search field (title slot while searching). Esc closes the
/// search, Enter shows the newest hit.
class ConversationSearchField extends StatelessWidget {
  const ConversationSearchField({super.key, required this.search});

  final ConversationSearchController search;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(end: NotionSpace.xs),
    child: NotionSearchField(
      key: const ValueKey('conversation-search-field'),
      controller: search.text,
      focusNode: search.focus,
      autofocus: true,
      hint: 'Search this chat',
      onChanged: search.setQuery,
      onSubmitted: (_) => search.submit(),
      onClose: search.close,
    ),
  );
}

/// Takes the composer's place while searching: the composer stays mounted
/// (draft, recording and focus state survive) but is neither painted nor
/// focusable, and the bar measures as the composer's height.
class ConversationSearchComposerSwitch extends StatelessWidget {
  const ConversationSearchComposerSwitch({
    super.key,
    required this.searching,
    required this.composer,
    required this.bar,
  });

  final bool searching;
  final Widget composer;
  final WidgetBuilder bar;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Offstage(
        offstage: searching,
        child: ExcludeFocus(
          excluding: searching,
          child: TickerMode(enabled: !searching, child: composer),
        ),
      ),
      if (searching) bar(context),
    ],
  );
}

/// "3 of 17" with the list toggle, jump to date and the older/newer arrows
/// (Telegram's search panel).
class ConversationSearchBar extends StatelessWidget {
  const ConversationSearchBar({
    super.key,
    required this.search,
    this.onPickDate,
  });

  final ConversationSearchController search;
  final VoidCallback? onPickDate;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: search,
    builder: (context, _) {
      final notion = context.notion;
      final hasHits = search.hits.isNotEmpty;
      return Row(
        key: const ValueKey('conversation-search-bar'),
        children: [
          NotionIconButton(
            icon: Icons.format_list_bulleted,
            label: search.listOpen ? 'Hide results' : 'Show results',
            selected: search.listOpen,
            onPressed: hasHits ? search.toggleList : null,
          ),
          const SizedBox(width: NotionSpace.xs),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: NotionFadeThrough(
                child: Text(
                  search.status,
                  key: ValueKey(search.status),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: notion.typography.callout,
                ),
              ),
            ),
          ),
          if (onPickDate != null)
            NotionIconButton(
              icon: Icons.calendar_today_outlined,
              label: 'Jump to date',
              onPressed: onPickDate,
            ),
          NotionIconButton(
            key: const ValueKey('conversation-search-older'),
            icon: Icons.keyboard_arrow_up,
            label: 'Older result',
            onPressed: search.canStepOlder ? search.stepOlder : null,
          ),
          NotionIconButton(
            key: const ValueKey('conversation-search-newer'),
            icon: Icons.keyboard_arrow_down,
            label: 'Newer result',
            onPressed: search.canStepNewer ? search.stepNewer : null,
          ),
        ],
      );
    },
  );
}

/// The results over the timeline while typing (or after the list toggle):
/// newest first, sender, date and the matching words. Opaque (it scrolls),
/// between the glass header and the search bar.
class ConversationSearchResults extends StatelessWidget {
  const ConversationSearchResults({
    super.key,
    required this.search,
    required this.bottomInset,
    this.sourceLabel,
  });

  final ConversationSearchController search;
  final ValueListenable<double?> bottomInset;

  /// "via WhatsApp" in a merged chat.
  final String? Function(Event event)? sourceLabel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: search,
    builder: (context, _) => NotionFadeThrough(
      child: !search.active || !search.listOpen
          ? const SizedBox.shrink(key: ValueKey('closed'))
          : _list(context),
    ),
  );

  Widget _list(BuildContext context) {
    final notion = context.notion;
    final hits = search.hits;
    final top = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      key: const ValueKey('conversation-search-results'),
      color: notion.colors.background,
      child: ValueListenableBuilder<double?>(
        valueListenable: bottomInset,
        builder: (context, inset, _) {
          if (hits.isEmpty && !search.scanning && !search.remoteBusy) {
            return Padding(
              padding: EdgeInsets.only(top: top, bottom: inset ?? 0),
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const NotionEmptyState(
                        icon: Icons.search_off,
                        title: 'No messages found',
                        message:
                            'Messages stored on this device were searched.',
                      ),
                      _footer(context),
                    ],
                  ),
                ),
              ),
            );
          }
          return ListView.builder(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              NotionSpace.xs,
              top + NotionSpace.xs,
              NotionSpace.xs,
              (inset ?? 0) + NotionSpace.xs,
            ),
            itemCount: hits.length + 1,
            itemBuilder: (context, index) {
              if (index == hits.length) return _footer(context);
              final hit = hits[index];
              return ConversationSearchResultRow(
                key: ValueKey(hit.eventId),
                hit: hit,
                terms: search.terms,
                selected: index == search.index,
                sourceLabel: sourceLabel?.call(hit.event),
                onTap: () => search.select(index),
              );
            },
          );
        },
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final typography = context.notion.typography;
    final String note;
    if (search.scanning || search.remoteBusy) {
      note = 'Searching messages on this device…';
    } else if (search.remoteFailed) {
      note = 'Older messages could not load. Try again.';
    } else if (search.storeFailed) {
      note = 'Some stored messages could not be read.';
    } else {
      note = 'Searched the messages stored on this device.';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.md,
        vertical: NotionSpace.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            note,
            textAlign: TextAlign.center,
            style: typography.captionMuted,
          ),
          if (search.canSearchOlder)
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: NotionButton.ghost(
                label: 'Search older messages',
                icon: Icons.history,
                busy: search.remoteBusy,
                onPressed: search.remoteBusy ? null : search.searchOlder,
              ),
            ),
        ],
      ),
    );
  }
}

/// One hit: sender and date, then the text around the match with the
/// matching words in bold (Telegram's search list).
class ConversationSearchResultRow extends StatelessWidget {
  const ConversationSearchResultRow({
    super.key,
    required this.hit,
    required this.terms,
    required this.onTap,
    this.selected = false,
    this.sourceLabel,
  });

  final LocalMessageHit hit;
  final List<String> terms;
  final VoidCallback onTap;
  final bool selected;
  final String? sourceLabel;

  static String senderName(Event event) {
    if (event.senderId == event.room.client.userID) return 'You';
    return event.senderFromMemoryOrFallback.calcDisplayname();
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final typography = notion.typography;
    final snippet = localSnippet(hit.text, terms);
    final ranges = localMatchRanges(snippet, terms);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in ranges) {
      if (start > at) spans.add(TextSpan(text: snippet.substring(at, start)));
      spans.add(
        TextSpan(
          text: snippet.substring(start, end),
          style: TextStyle(
            color: notion.colors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      at = end;
    }
    if (at < snippet.length) spans.add(TextSpan(text: snippet.substring(at)));
    final date = hit.time.localizedTimeShort(context);
    final source = sourceLabel;
    return Semantics(
      button: true,
      selected: selected,
      child: NotionPressable(
        scale: NotionMotion.pressRow,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: NotionRadius.rowAll,
            child: Ink(
              decoration: BoxDecoration(
                color: selected ? notion.colors.selected : null,
                borderRadius: NotionRadius.rowAll,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.sm,
                vertical: NotionSpace.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          senderName(hit.event),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NotionType.callout.copyWith(
                            color: notion.colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: NotionSpace.xs),
                      Text(
                        source == null ? date : '$date · $source',
                        style: typography.captionMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: NotionSpace.xxs),
                  Text.rich(
                    TextSpan(children: spans),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typography.footnoteMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
