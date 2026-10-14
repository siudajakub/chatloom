// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/merged_chat_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

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
  const PersonalSearchPage({super.key, required this.personal});
  @override
  State<PersonalSearchPage> createState() => _PersonalSearchPageState();
}

class _PersonalSearchPageState extends State<PersonalSearchPage> {
  final query = TextEditingController();
  final timelines = <String, Timeline>{};
  final unavailable = <String>{};
  String? selectedScope, loadedScope, network, mediaType;
  bool? outgoing;
  DateTime? afterDay, beforeDay;
  bool bookmarksOnly = false, busy = false, searched = false;
  int generation = 0, pages = 0;
  String? problem;
  PersonalClient get personal => widget.personal;
  @override
  void initState() {
    super.initState();
    unawaited(personal.load());
  }

  @override
  void dispose() {
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
            if (mounted && generation == current) setState(() {});
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
    } catch (_) {
      problem = 'Could not load more history. Try again.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _date(bool start) async {
    final chosen = await showDatePicker(
      context: context,
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
      text: query.text,
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

  List<Event> _results() {
    if (loadedScope != selectedScope) return [];
    final search = _query();
    if (search == null) return [];
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
    final events = <Event>[];
    final seen = <String>{};
    for (final timeline in timelines.values) {
      for (final source in timeline.events) {
        if (!{
              EventTypes.Message,
              EventTypes.Sticker,
              EventTypes.Encrypted,
            }.contains(source.type) ||
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
        if (search.matchesMessage(
          MessageSearchEntry(
            source: ref,
            timestamp: source.originServerTs,
            text: display.text,
            transcript: transcripts[ref.key],
            fileName: filename is String ? filename : null,
            messageType: type,
            isOutgoing: source.senderId == personal.client.userID,
            bookmarked: bookmarked.contains(ref.key),
          ),
        )) {
          events.add(source);
        }
      }
    }
    events.sort((a, b) {
      final byTime = b.originServerTs.compareTo(a.originServerTs);
      return byTime != 0
          ? byTime
          : personal.source(a).key.compareTo(personal.source(b).key);
    });
    return events;
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
      return Scaffold(
        appBar: AppBar(title: const Text('Search conversations')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selected?.key,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Person or conversation',
                        ),
                        items: [
                          for (final item in scopes)
                            DropdownMenuItem(
                              value: item.key,
                              child: Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          labelText: 'Text, transcript or filename',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          DropdownButton<String>(
                            hint: const Text('All networks'),
                            value: networks.contains(network) ? network : null,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('All networks'),
                              ),
                              for (final value in networks)
                                DropdownMenuItem(
                                  value: value,
                                  child: Text(value),
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
                          DropdownButton<bool>(
                            hint: const Text('Sent & received'),
                            value: outgoing,
                            items: const [
                              DropdownMenuItem(
                                value: null,
                                child: Text('Sent & received'),
                              ),
                              DropdownMenuItem(
                                value: true,
                                child: Text('Sent'),
                              ),
                              DropdownMenuItem(
                                value: false,
                                child: Text('Received'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => outgoing = value),
                          ),
                          DropdownButton<String>(
                            hint: const Text('All types'),
                            value: mediaType,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('All types'),
                              ),
                              for (final entry in const {
                                'text': 'Tekst',
                                'image': 'Photos',
                                'video': 'Wideo',
                                'audio': 'Audio',
                                'file': 'Files',
                              }.entries)
                                DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => mediaType = value),
                          ),
                          FilterChip(
                            label: const Text('Bookmarks'),
                            selected: bookmarksOnly,
                            onSelected: (value) =>
                                setState(() => bookmarksOnly = value),
                          ),
                          TextButton(
                            onPressed: () => _date(true),
                            child: Text(_dateLabel(afterDay, 'From date')),
                          ),
                          TextButton(
                            onPressed: () => _date(false),
                            child: Text(_dateLabel(beforeDay, 'To date')),
                          ),
                          if (afterDay != null || beforeDay != null)
                            IconButton(
                              tooltip: 'Clear date range',
                              onPressed: () => setState(() {
                                afterDay = null;
                                beforeDay = null;
                              }),
                              icon: const Icon(Icons.close),
                            ),
                          FilledButton.icon(
                            onPressed:
                                busy || selected == null || _query() == null
                                ? null
                                : _search,
                            icon: const Icon(Icons.search),
                            label: const Text('Search'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (busy) const LinearProgressIndicator(),
                if (_query() == null)
                  const ListTile(
                    title: Text('The start date must be before the end date.'),
                  ),
                if (problem != null)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(problem!),
                  ),
                ListTile(
                  title: Text(
                    loadedScope == selectedScope && loadedScope != null
                        ? 'Loaded history: $loaded events, ${timelines.length} sources'
                        : 'Choose a person or conversation, then select Search.',
                  ),
                  subtitle: const Text(
                    'Results cover loaded history only. No results does not mean the source network has no matching messages.',
                  ),
                ),
                Expanded(
                  child: results.isEmpty
                      ? Center(
                          child: Text(
                            searched && loadedScope == selectedScope
                                ? 'No matches in loaded history.'
                                : 'Select Search to search the loaded history.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (context, index) {
                            final original = results[index];
                            final display = original.getDisplayEvent(
                              timelines[original.room.id]!,
                            );
                            final ref = personal.source(original);
                            final transcript = personal.transcripts.values
                                .where(
                                  (j) =>
                                      j.source.key == ref.key &&
                                      j.state == JobState.done,
                                )
                                .firstOrNull
                                ?.text;
                            return ListTile(
                              title: Text(
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
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${InboxProjection(personal).displayName(original.room)} · ${PersonalClient.networkOf(original.room)} · ${MaterialLocalizations.of(context).formatShortDate(original.originServerTs.toLocal())}',
                              ),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => SourceChatPage(source: ref),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (loadedScope == selectedScope && more)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextButton(
                      onPressed: busy || pages >= 10 ? null : _older,
                      child: Text(
                        pages >= 10
                            ? 'Search session limit reached'
                            : 'Load 50 more events per source',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
