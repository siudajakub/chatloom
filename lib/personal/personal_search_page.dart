// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// One search hit with everything its row needs, computed once per result
/// set instead of once per row build.
@immutable
class PersonalSearchHit {
  const PersonalSearchHit({
    required this.event,
    required this.display,
    required this.source,
    required this.timestamp,
    this.transcript,
  });

  final Event event;
  final Event display;
  final SourceEventRef source;
  final DateTime timestamp;
  final String? transcript;

  /// Newest first; equal times by source key (precomputed, so sorting never
  /// rebuilds keys).
  static int compare(PersonalSearchHit a, PersonalSearchHit b) {
    final byTime = b.timestamp.compareTo(a.timestamp);
    return byTime != 0 ? byTime : a.source.key.compareTo(b.source.key);
  }
}

/// Keeps one computed value while its signature is unchanged (records and
/// lists of plain values compare by value).
final class PersonalSearchMemo<T> {
  Object? _signature;
  T? _value;
  bool _has = false;

  /// How often [resolve] had to compute (for tests).
  int computations = 0;

  T resolve(Object? signature, T Function() compute) {
    if (_has && _signature == signature) return _value as T;
    computations++;
    _signature = signature;
    _value = compute();
    _has = true;
    return _value as T;
  }

  void clear() {
    _has = false;
    _signature = null;
    _value = null;
  }
}

class _SearchScope {
  final String key;
  final String name;
  final List<ConversationRef> sources;
  const _SearchScope(this.key, this.name, this.sources);
}

/// Search is initiated by an explicit tap and limited to a selected person or
/// conversation. It never emits read markers or uploads message contents.
class PersonalSearchPage extends StatefulWidget {
  final PersonalClient personal;

  /// Text to search for (from the full-screen search); nothing is loaded
  /// until a conversation is chosen and Search is pressed.
  final String initialQuery;
  const PersonalSearchPage({
    super.key,
    required this.personal,
    this.initialQuery = '',
  });

  /// Number of result scans so far (tests check typing is debounced and
  /// unrelated rebuilds reuse the memoised results).
  @visibleForTesting
  static int debugScans = 0;
  @override
  State<PersonalSearchPage> createState() => _PersonalSearchPageState();
}

class _PersonalSearchPageState extends State<PersonalSearchPage> {
  /// Typing applies to the results after this pause (Telegram filters as
  /// you type; one scan per pause instead of one per keystroke).
  static const typingDebounce = Duration(milliseconds: 150);

  late final query = TextEditingController(text: widget.initialQuery);

  /// The query text the results use; follows [query] after [typingDebounce].
  late String _appliedText = widget.initialQuery;
  Timer? _typing;

  /// Bumped when a loaded timeline or the personal store (bookmarks,
  /// transcripts) changes, so the memoised results are recomputed only then.
  int _timelineRevision = 0, _personalRevision = 0;
  final _resultsMemo = PersonalSearchMemo<List<PersonalSearchHit>>();
  final timelines = <String, Timeline>{};
  final unavailable = <String>{};
  String? selectedScope, loadedScope, network, mediaType;
  bool? outgoing;
  DateTime? afterDay, beforeDay;
  bool bookmarksOnly = false, busy = false, searched = false;
  int generation = 0, pages = 0;
  String? problem;

  /// Last problem shown, kept while its row collapses.
  String? _shownProblem;
  PersonalClient get personal => widget.personal;
  @override
  void initState() {
    super.initState();
    personal.addListener(_personalChanged);
    PersonalPageLoad.request(context, personal);
  }

  void _personalChanged() => _personalRevision++;

  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(typingDebounce, _applyTyping);
  }

  void _applyTyping() {
    _typing?.cancel();
    _typing = null;
    if (!mounted || _appliedText == query.text) return;
    setState(() => _appliedText = query.text);
  }

  @override
  void dispose() {
    _typing?.cancel();
    personal.removeListener(_personalChanged);
    generation++;
    for (final t in timelines.values) {
      t.cancelSubscriptions();
    }
    query.dispose();
    super.dispose();
  }

  List<_SearchScope> _scopes() {
    final rooms = personal.client.rooms
        .where((r) => !r.isSpace && !PersonalPrivacy.isJournal(r))
        .toList();
    final items = <_SearchScope>[];
    for (final entry in personal.values.entries.where(
      (e) => e.key.startsWith('person:'),
    )) {
      try {
        final group = PersonGroup.fromJson(entry.value);
        if (group.members.every((m) => m.accountId == personal.client.userID)) {
          items.add(
            _SearchScope('person:${group.id}', group.name, group.members),
          );
        }
      } catch (_) {}
    }
    final projection = InboxProjection(personal);
    items.addAll(
      rooms.map(
        (room) => _SearchScope(
          room.id,
          '${projection.displayName(room)} · ${PersonalClient.networkOf(room)}',
          [personal.ref(room)],
        ),
      ),
    );
    return items;
  }

  _SearchScope? get scope =>
      _scopes().where((s) => s.key == selectedScope).firstOrNull;
  List<ConversationRef> get selectedSources =>
      scope?.sources
          .where((s) => network == null || s.network == network)
          .toList() ??
      [];
  Future<void> _search() async {
    final selected = scope;
    final sources = selectedSources;
    if (selected == null || sources.isEmpty || busy) return;
    if (sources.length > 5) {
      setState(
        () => problem =
            'Choose a network or conversation. Each search supports up to five sources.',
      );
      return;
    }
    final current = ++generation;
    setState(() {
      busy = true;
      problem = null;
      searched = true;
      pages = 0;
      loadedScope = null;
    });
    for (final timeline in timelines.values) {
      timeline.cancelSubscriptions();
    }
    timelines.clear();
    unavailable.clear();
    for (final source in sources) {
      final room = personal.client.getRoomById(source.roomId);
      if (room == null || source.accountId != personal.client.userID) {
        unavailable.add(source.roomId);
        continue;
      }
      try {
        final timeline = await room.getTimeline(
          limit: 100,
          onUpdate: () {
            if (mounted && generation == current) {
              setState(() => _timelineRevision++);
            }
          },
        );
        if (!mounted || generation != current) {
          timeline.cancelSubscriptions();
          return;
        }
        timelines[source.roomId] = timeline;
      } catch (_) {
        unavailable.add(source.roomId);
      }
    }
    if (mounted && generation == current) {
      setState(() {
        busy = false;
        loadedScope = selected.key;
        if (unavailable.isNotEmpty) {
          problem =
              'Some selected sources are unavailable. Results cover loaded history only.';
        }
      });
    }
  }

  Future<void> _older() async {
    if (busy || pages >= 10) return;
    setState(() => busy = true);
    try {
      for (final timeline in timelines.values.where(
        (t) => t.canRequestHistory,
      )) {
        final before = timeline.events.map((e) => e.eventId).toSet();
        await timeline.requestHistory(historyCount: 50);
        final after = timeline.events.map((e) => e.eventId).toSet();
        if (after.length == before.length &&
            after.containsAll(before) &&
            timeline.canRequestHistory) {
          throw StateError('History stalled');
        }
      }
      pages++;
      _timelineRevision++;
    } catch (_) {
      problem = 'Could not load more history. Try again.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _date(bool start) async {
    // The Notion calendar sheet (spring motion, glass), as in "jump to
    // date", instead of the Material dialog.
    final chosen = await showNotionDatePicker(
      context: context,
      title: start ? 'From date' : 'To date',
      initialDate: (start ? afterDay : beforeDay) ?? DateTime.now(),
      firstDate: DateTime(1970),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      start ? afterDay = chosen : beforeDay = chosen;
    });
  }

  PersonalSearchQuery? _query() {
    if (afterDay != null &&
        beforeDay != null &&
        afterDay!.isAfter(beforeDay!)) {
      return null;
    }
    final before = beforeDay;
    return PersonalSearchQuery(
      text: _appliedText,
      networks: network == null ? [] : [network!],
      messageTypes: mediaType == null ? [] : [mediaType!],
      outgoing: outgoing,
      bookmarksOnly: bookmarksOnly,
      after: afterDay?.toUtc().subtract(const Duration(microseconds: 1)),
      before: before == null
          ? null
          : DateTime(before.year, before.month, before.day + 1).toUtc(),
    );
  }

  /// The hits for the current query and filters, memoised on everything
  /// they depend on: rebuilds for other reasons (focus, progress, a busy
  /// flag) reuse the last list.
  List<PersonalSearchHit> _results() => _resultsMemo.resolve((
    loadedScope,
    selectedScope,
    _appliedText,
    network,
    mediaType,
    outgoing,
    bookmarksOnly,
    afterDay,
    beforeDay,
    _timelineRevision,
    _personalRevision,
    generation,
  ), _computeResults);

  List<PersonalSearchHit> _computeResults() {
    PersonalSearchPage.debugScans++;
    if (loadedScope != selectedScope) return const [];
    final search = _query();
    if (search == null) return const [];
    final bookmarked = <String>{};
    for (final value in personal.values.entries.where(
      (e) => e.key.startsWith('bookmark:'),
    )) {
      try {
        bookmarked.add(
          SourceEventRef.fromJson(
            Map<String, dynamic>.from(value.value['source'] as Map),
          ).key,
        );
      } catch (_) {}
    }
    final transcripts = {
      for (final j in personal.transcripts.values.where(
        (j) => j.state == JobState.done,
      ))
        j.source.key: j.text,
    };
    const searchable = {
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.Encrypted,
    };
    final hits = <PersonalSearchHit>[];
    final seen = <String>{};
    for (final timeline in timelines.values) {
      for (final source in timeline.events) {
        if (!searchable.contains(source.type) ||
            source.relationshipType == RelationshipTypes.edit ||
            source.redacted) {
          continue;
        }
        final ref = personal.source(source);
        if (!seen.add(ref.key)) continue;
        final display = source.getDisplayEvent(timeline);
        final filename = display.content['filename'];
        final type = switch (display.messageType) {
          MessageTypes.Image => 'image',
          MessageTypes.Video => 'video',
          MessageTypes.Audio => 'audio',
          MessageTypes.File => 'file',
          MessageTypes.Sticker => 'image',
          _ => 'text',
        };
        final transcript = transcripts[ref.key];
        if (search.matchesMessage(
          MessageSearchEntry(
            source: ref,
            timestamp: source.originServerTs,
            text: display.text,
            transcript: transcript,
            fileName: filename is String ? filename : null,
            messageType: type,
            isOutgoing: source.senderId == personal.client.userID,
            bookmarked: bookmarked.contains(ref.key),
          ),
        )) {
          hits.add(
            PersonalSearchHit(
              event: source,
              display: display,
              source: ref,
              timestamp: source.originServerTs,
              transcript: transcript,
            ),
          );
        }
      }
    }
    return hits..sort(PersonalSearchHit.compare);
  }

  /// A result's text, at most three lines' worth (the row does not clip).
  static String _short(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length > 240 ? '${line.substring(0, 240)}…' : line;
  }

  String _dateLabel(DateTime? value, String empty) => value == null
      ? empty
      : MaterialLocalizations.of(context).formatShortDate(value);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) {
      final scopes = _scopes();
      final selected = scopes.where((s) => s.key == selectedScope).firstOrNull;
      final networks =
          selected?.sources.map((s) => s.network).toSet().toList() ?? [];
      final results = _results();
      final loaded = timelines.values.fold<int>(
        0,
        (sum, t) => sum + t.events.length,
      );
      final more = timelines.values.any((t) => t.canRequestHistory);
      final emptyTitle = searched && loadedScope == selectedScope
          ? 'No matches in loaded history.'
          : 'Select Search to search the loaded history.';
      // Typing filters in place; a new search or filter swaps the list.
      final resultsKey = (
        loadedScope,
        network,
        outgoing,
        mediaType,
        bookmarksOnly,
        afterDay,
        beforeDay,
      );
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: notionGlassAppBar(title: const Text('Search conversations')),
        body: NotionBelowGlassHeader(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: NotionSize.contentMaxWidth,
              ),
              // The filters scroll in at most half the height, so the page
              // never overflows with the keyboard up and results stay visible
              // while typing.
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight / 2,
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Picker row and filter pills instead of
                                  // Material dropdowns and chips (UI-10).
                                  NotionPickerRow<String?>(
                                    key: const ValueKey('search-scope'),
                                    label: 'Person or conversation',
                                    icon: Icons.person_search_outlined,
                                    value: selected?.key,
                                    options: [
                                      for (final item in scopes)
                                        NotionChoice<String?>(
                                          item.key,
                                          item.name,
                                        ),
                                    ],
                                    onChanged: busy
                                        ? null
                                        : (value) => setState(() {
                                            selectedScope = value;
                                            network = null;
                                          }),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: query,
                                    onChanged: _typed,
                                    onSubmitted: (_) {
                                      _applyTyping();
                                      _search();
                                    },
                                    decoration: const InputDecoration(
                                      hintText: 'Text, transcript or filename',
                                      prefixIcon: Icon(Icons.search),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: NotionSpace.xs,
                                    runSpacing: NotionSpace.xs,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      NotionChoicePill<String?>(
                                        key: const ValueKey('search-network'),
                                        title: 'Network',
                                        value: networks.contains(network)
                                            ? network
                                            : null,
                                        neutral: null,
                                        options: [
                                          const NotionChoice<String?>(
                                            null,
                                            'All networks',
                                          ),
                                          for (final value in networks)
                                            NotionChoice<String?>(
                                              value,
                                              notionNetworkLabel(value),
                                            ),
                                        ],
                                        onChanged: busy
                                            ? null
                                            : (value) => setState(() {
                                                network = value;
                                                loadedScope = null;
                                                searched = false;
                                              }),
                                      ),
                                      NotionChoicePill<bool?>(
                                        key: const ValueKey('search-direction'),
                                        title: 'Sent or received',
                                        value: outgoing,
                                        neutral: null,
                                        options: const [
                                          NotionChoice<bool?>(
                                            null,
                                            'Sent & received',
                                          ),
                                          NotionChoice<bool?>(true, 'Sent'),
                                          NotionChoice<bool?>(
                                            false,
                                            'Received',
                                          ),
                                        ],
                                        onChanged: (value) =>
                                            setState(() => outgoing = value),
                                      ),
                                      NotionChoicePill<String?>(
                                        key: const ValueKey('search-type'),
                                        title: 'Type',
                                        value: mediaType,
                                        neutral: null,
                                        options: const [
                                          NotionChoice<String?>(
                                            null,
                                            'All types',
                                          ),
                                          NotionChoice<String?>('text', 'Text'),
                                          NotionChoice<String?>(
                                            'image',
                                            'Photos',
                                          ),
                                          NotionChoice<String?>(
                                            'video',
                                            'Videos',
                                          ),
                                          NotionChoice<String?>(
                                            'audio',
                                            'Audio',
                                          ),
                                          NotionChoice<String?>(
                                            'file',
                                            'Files',
                                          ),
                                        ],
                                        onChanged: (value) =>
                                            setState(() => mediaType = value),
                                      ),
                                      NotionGlassPill(
                                        key: const ValueKey('search-bookmarks'),
                                        icon: bookmarksOnly
                                            ? Icons.bookmark
                                            : Icons.bookmark_outline,
                                        label: 'Bookmarks',
                                        selected: bookmarksOnly,
                                        onPressed: () => setState(
                                          () => bookmarksOnly = !bookmarksOnly,
                                        ),
                                      ),
                                      NotionGlassPill(
                                        icon: Icons.event_outlined,
                                        label: _dateLabel(
                                          afterDay,
                                          'From date',
                                        ),
                                        selected: afterDay != null,
                                        onPressed: () => _date(true),
                                      ),
                                      NotionGlassPill(
                                        icon: Icons.event_outlined,
                                        label: _dateLabel(beforeDay, 'To date'),
                                        selected: beforeDay != null,
                                        onPressed: () => _date(false),
                                      ),
                                      if (afterDay != null || beforeDay != null)
                                        NotionGlassPill(
                                          icon: Icons.close,
                                          tooltip: 'Clear date range',
                                          onPressed: () => setState(() {
                                            afterDay = null;
                                            beforeDay = null;
                                          }),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: NotionButton.primary(
                                      label: 'Search',
                                      icon: Icons.search,
                                      onPressed:
                                          busy ||
                                              selected == null ||
                                              _query() == null
                                          ? null
                                          : _search,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Quick searches never flash a bar; the slot is reserved.
                            if (busy)
                              const NotionDelayedReveal(
                                placeholder: SizedBox(height: 4),
                                child: LinearProgressIndicator(),
                              ),
                            NotionSizeReveal(
                              visible: _query() == null,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: NotionSpace.md,
                                ),
                                child: NotionListRow(
                                  leading: Icon(Icons.event_busy_outlined),
                                  title:
                                      'The start date must be before the end date.',
                                ),
                              ),
                            ),
                            NotionSizeReveal(
                              visible: problem != null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: NotionSpace.md,
                                ),
                                child: NotionListRow(
                                  leading: const Icon(Icons.info_outline),
                                  title: _shownProblem =
                                      problem ?? _shownProblem ?? '',
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: NotionSpace.md,
                              ),
                              child: NotionListRow(
                                title:
                                    loadedScope == selectedScope &&
                                        loadedScope != null
                                    ? 'Loaded history: $loaded events, ${timelines.length} sources'
                                    : 'Choose a person or conversation, then select Search.',
                                subtitle:
                                    'Results cover loaded history only. No results does not mean the source network has no matching messages.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Results fade through when the query or filters change; the
                    // first screenful of a new result set rises in once.
                    Expanded(
                      child: NotionFadeThrough(
                        alignment: Alignment.topCenter,
                        child: results.isEmpty
                            ? NotionEmptyState(
                                key: ValueKey(('empty', emptyTitle)),
                                icon: searched && loadedScope == selectedScope
                                    ? Icons.search_off
                                    : Icons.manage_search,
                                title: emptyTitle,
                              )
                            : NotionEntranceScope(
                                key: ValueKey(('results', resultsKey)),
                                child: ListView.builder(
                                  itemCount: results.length,
                                  itemBuilder: (context, index) {
                                    final hit = results[index];
                                    final original = hit.event;
                                    final display = hit.display;
                                    final ref = hit.source;
                                    final transcript = hit.transcript;
                                    return NotionEntrance(
                                      playKey: original.eventId,
                                      rise: NotionMotion.riseList,
                                      child: NotionListRow(
                                        title: _short(
                                          RoundVideoDescriptor.fromContent(
                                                    display.content,
                                                    redacted: display.redacted,
                                                  ) !=
                                                  null
                                              ? transcript == null
                                                    ? 'Video message'
                                                    : 'Video message · $transcript'
                                              : display.text.isEmpty
                                              ? transcript ?? 'Attachment'
                                              : display.text,
                                        ),
                                        subtitle:
                                            '${InboxProjection(personal).displayName(original.room)} · ${notionNetworkLabel(PersonalClient.networkOf(original.room))} · ${MaterialLocalizations.of(context).formatShortDate(original.originServerTs.toLocal())}',
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                SourceChatPage(source: ref),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ),
                    if (loadedScope == selectedScope && more)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: NotionButton.ghost(
                          label: pages >= 10
                              ? 'Search session limit reached'
                              : 'Load 50 more events per source',
                          onPressed: busy || pages >= 10 ? null : _older,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
