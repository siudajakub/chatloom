// SPDX-License-Identifier: AGPL-3.0-or-later
// Settings › People: merge conversations, suggested merges (local only,
// dismissible, never automatic) and every merged person with its state, in
// the one name the inbox and the chat header show.
import 'dart:async';

import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show personalConversationAvatar;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/person_page.dart';
import 'package:chatloom/personal/ui/person_sheets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// The rows of Settings › People. [run] reports failures like the other
/// settings sections.
class PeopleSettingsSection extends StatefulWidget {
  final PersonalClient personal;
  final Future<void> Function(Future<void> Function() action) run;
  const PeopleSettingsSection({
    super.key,
    required this.personal,
    required this.run,
  });
  @override
  State<PeopleSettingsSection> createState() => _PeopleSettingsSectionState();
}

class _PeopleSettingsSectionState extends State<PeopleSettingsSection> {
  PersonalClient get personal => widget.personal;
  int? _suggestionKey;
  List<MergeSuggestion> _suggestions = const [];

  /// Suggestions only change with the chats, persons, names and dismissals;
  /// other store notifications (drafts, heartbeats) reuse them.
  List<MergeSuggestion> get _currentSuggestions {
    final key = Object.hashAll([
      personal.ready,
      personal.client.rooms.length,
      personal.groups.length,
      for (final entry in personal.values.entries)
        if (entry.key.startsWith('person:') ||
            entry.key.startsWith('merge-dismissed:') ||
            entry.key.startsWith('nickname:'))
          entry.key,
    ]);
    if (key != _suggestionKey) {
      _suggestionKey = key;
      _suggestions = personMergeSuggestions(personal, limit: 5);
    }
    return _suggestions;
  }

  bool get _current =>
      mounted && identical(Matrix.of(context).client, personal.client);

  /// Merge from People settings: the picker needs at least two chats; the
  /// first selected chat names the person (see [planMerge]).
  Future<void> _merge() async {
    if (!personal.ready) return;
    final picked = await showMergePicker(context, personal: personal);
    if (picked == null || picked.length < 2 || !mounted || !_current) return;
    await _apply(
      planMerge(personal, [
        for (final candidate in picked) ...candidate.sources,
      ], anchor: picked.first.representative),
    );
  }

  Future<void> _apply(MergePlan plan) async {
    final messenger = ScaffoldMessenger.of(context);
    await applyMerge(personal, plan);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            plan.createsGroup ? 'Chats merged' : 'Added to the merged chat',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              undoMerge(personal, plan).catchError((Object _) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'The change was not undone. Check private sync.',
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      );
  }

  Future<void> _acceptSuggestion(MergeSuggestion suggestion) async {
    final first = suggestionRooms(personal, suggestion.first);
    final second = suggestionRooms(personal, suggestion.second);
    if (first.isEmpty || second.isEmpty) return;
    await _apply(
      planMerge(personal, [...first, ...second], anchor: first.first),
    );
  }

  String _suggestionTitle(MergeSuggestion suggestion) {
    final projection = InboxProjection(personal);
    String name(MergeSuggestionCandidate side) {
      final rooms = suggestionRooms(personal, side);
      return rooms.isEmpty ? 'A chat' : projection.displayName(rooms.first);
    }

    return '${name(suggestion.first)} and ${name(suggestion.second)}';
  }

  String _suggestionReason(MergeSuggestion suggestion) {
    final networks = [
      for (final network in {
        ...suggestion.first.networks,
        ...suggestion.second.networks,
      })
        notionNetworkLabel(network),
    ]..sort();
    final where = networks.join(' and ');
    return suggestion.reason == MergeSuggestionReason.phone
        ? 'Same phone number on $where'
        : 'Same name on $where';
  }

  /// What a merged person looks like right now, in a few words.
  String _subtitle(
    PersonGroup group,
    InboxProjection projection,
    PersonGroupResolution resolution,
  ) {
    if (resolution.covered.any((g) => g.id == group.id)) {
      return 'Leftover from an earlier merge · its chats are in another merged chat';
    }
    final sources = projection.sourcesOf(group);
    final active = [
      for (final s in sources)
        if (s.status == PersonSourceStatus.active) s,
    ];
    final networks = {
      for (final s in active) notionNetworkLabel(s.member.network),
    }.join(', ');
    final issue = sources
        .where((s) => s.status != PersonSourceStatus.active)
        .firstOrNull;
    final count = '${active.length} ${active.length == 1 ? 'chat' : 'chats'}';
    final summary = networks.isEmpty ? count : '$count · $networks';
    if (issue == null) return summary;
    final network = personNetworkLabel(issue);
    return switch (issue.status) {
      PersonSourceStatus.inactive => '$summary · $network chat left or deleted',
      PersonSourceStatus.elsewhere =>
        '$summary · $network chat also in ${projection.personName(issue.owner!)}',
      PersonSourceStatus.unsafe =>
        'Needs attention · the $network chat is now a group chat',
      PersonSourceStatus.active => summary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final projection = InboxProjection.snapshot(personal);
    final resolution = projection.resolution;
    final groups = personal.groups;
    final suggestions = personal.ready
        ? _currentSuggestions
        : const <MergeSuggestion>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: const Icon(Icons.call_merge),
          title: 'Merge conversations',
          subtitle: 'One chat for one person across networks',
          onTap: personal.ready ? () => widget.run(_merge) : null,
        ),
        NotionSizeReveal(
          visible: suggestions.isNotEmpty,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NotionSectionHeader(title: 'Suggested'),
              for (final suggestion in suggestions)
                NotionListRow(
                  key: ValueKey(suggestion.dismissKey),
                  leading: const Icon(Icons.people_outline),
                  title: _suggestionTitle(suggestion),
                  subtitle: _suggestionReason(suggestion),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NotionIconButton(
                        icon: Icons.close,
                        label: 'Not the same person',
                        onPressed: () => widget.run(
                          () => dismissMergeSuggestion(personal, suggestion),
                        ),
                      ),
                      NotionIconButton(
                        icon: Icons.call_merge,
                        label: 'Merge',
                        onPressed: () =>
                            widget.run(() => _acceptSuggestion(suggestion)),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.xxs),
                child: Text(
                  'Found on this device by name or phone number. Nothing is merged until you choose Merge.',
                  style: tokens.typography.captionMuted,
                ),
              ),
            ],
          ),
        ),
        if (groups.isNotEmpty) const NotionSectionHeader(title: 'Merged chats'),
        for (final group in groups)
          NotionListRow(
            key: ValueKey(group.id),
            leading: SizedBox.square(
              dimension: NotionSize.avatar,
              child: personalConversationAvatar(
                personal,
                entityId: 'person:${group.id}',
                avatar: projection.avatarForGroup(group),
                name: projection.personName(group),
                size: NotionSize.avatar,
              ),
            ),
            title: projection.personName(group),
            subtitle: _subtitle(group, projection, resolution),
            trailing: resolution.covered.any((g) => g.id == group.id)
                ? NotionButton.ghost(
                    label: 'Clean up',
                    onPressed: personal.ready
                        ? () => widget.run(() => personal.removeGroup(group.id))
                        : null,
                  )
                : null,
            onTap: () =>
                showPersonPage(context, personal: personal, group: group),
          ),
        if (personal.invalidGroupCount > 0)
          NotionListRow(
            leading: const Icon(Icons.warning_amber_outlined),
            title:
                'Some saved merges could not be loaded. Their data is preserved.',
            subtitle: '${personal.invalidGroupCount} saved merges',
          ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Text(
              'Merge two or more conversations of one person. Every message keeps its network.',
              style: tokens.typography.footnoteMuted,
            ),
          ),
      ],
    );
  }
}
