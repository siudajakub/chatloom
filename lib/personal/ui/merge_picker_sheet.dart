// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show personalConversationAvatar;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Picks the chats (or merged persons) to merge with [anchor]; without an
/// anchor (People settings) at least two are needed. Search is local only:
/// name, private nickname and network. Chats that look like the anchor's
/// person (same name or phone on another network) come first under
/// Suggested. [excludeGroupId] leaves that person out (adding to it);
/// [single] picks exactly one chat (replacing a chat). Resolves to null
/// when dismissed.
Future<List<MergeCandidate>?> showMergePicker(
  BuildContext context, {
  required PersonalClient personal,
  Room? anchor,
  String? title,
  String? excludeGroupId,
  bool single = false,
}) => showNotionSheet<List<MergeCandidate>>(
  context: context,
  title:
      title ??
      (anchor == null
          ? 'Merge conversations'
          : 'Merge ${InboxProjection(personal).displayName(anchor)} with…'),
  builder: (context) => MergePicker(
    personal: personal,
    anchor: anchor,
    excludeGroupId: excludeGroupId,
    single: single,
  ),
);

class MergePicker extends StatefulWidget {
  final PersonalClient personal;
  final Room? anchor;
  final String? excludeGroupId;
  final bool single;
  const MergePicker({
    super.key,
    required this.personal,
    this.anchor,
    this.excludeGroupId,
    this.single = false,
  });
  @override
  State<MergePicker> createState() => _MergePickerState();
}

class _MergePickerState extends State<MergePicker> {
  final _search = TextEditingController();
  final _selected = <String>{};
  late final List<MergeCandidate> _candidates = [
    for (final candidate in mergeCandidates(
      widget.personal,
      anchor: widget.anchor,
    ))
      if (widget.excludeGroupId == null ||
          candidate.group?.id != widget.excludeGroupId)
        candidate,
  ];

  /// Entities that look like the anchor's person, newest first. Local only.
  late final List<String> _suggested = widget.anchor == null
      ? const []
      : _suggestionsFor(widget.anchor!);
  late final InboxProjection _projection = InboxProjection.snapshot(
    widget.personal,
  );
  String _query = '';

  List<String> _suggestionsFor(Room anchor) {
    final entity = InboxProjection.snapshot(widget.personal).entityFor(anchor);
    final known = {for (final c in _candidates) c.entityId};
    final result = <String>[];
    for (final suggestion in personMergeSuggestions(
      widget.personal,
      anchor: anchor,
      limit: 5,
    )) {
      final other = suggestion.first.entityId == entity
          ? suggestion.second.entityId
          : suggestion.first.entityId;
      if (known.contains(other) && !result.contains(other)) result.add(other);
    }
    return result;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _current =>
      widget.personal.ready &&
      identical(Matrix.of(context).client, widget.personal.client);

  int get _needed => widget.anchor == null && !widget.single ? 2 : 1;

  /// Suggested candidates first (while not searching), then the rest.
  List<MergeCandidate> get _visible {
    if (_query.trim().isNotEmpty) {
      return _candidates.where((c) => c.matches(_query)).toList();
    }
    if (_suggested.isEmpty) return _candidates;
    return [
      for (final id in _suggested)
        ?_candidates.where((c) => c.entityId == id).firstOrNull,
      for (final candidate in _candidates)
        if (!_suggested.contains(candidate.entityId)) candidate,
    ];
  }

  void _toggle(MergeCandidate candidate) => setState(() {
    if (widget.single) {
      final was = _selected.contains(candidate.entityId);
      _selected.clear();
      if (!was) _selected.add(candidate.entityId);
      return;
    }
    if (!_selected.remove(candidate.entityId)) {
      _selected.add(candidate.entityId);
    }
  });

  void _confirm() {
    final chosen = [
      for (final id in _selected)
        ?_candidates.where((c) => c.entityId == id).firstOrNull,
    ];
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final media = MediaQuery.of(context);
    final height = math.max(
      NotionSize.touchTarget * 4,
      math.min(
        media.size.height * .72,
        media.size.height - media.viewInsets.bottom - media.padding.top,
      ),
    );
    final visible = _visible;
    final count = _selected.length;
    final ready = _current && count >= _needed;
    final label = widget.single
        ? (count == 0 ? 'Select a chat' : 'Use this chat')
        : count < _needed
        ? (widget.anchor == null ? 'Select at least two chats' : 'Select chats')
        : widget.anchor == null
        ? 'Merge $count chats'
        : 'Merge ${count + 1} chats';
    final suggesting = _query.trim().isEmpty && _suggested.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'One conversation for one person. Every message keeps its '
              'network; you can unmerge at any time.',
              style: tokens.typography.footnoteMuted,
            ),
            const SizedBox(height: NotionSpace.sm),
            NotionTextField(
              controller: _search,
              hint: 'Search by name or network',
              prefixIcon: Icons.search,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: NotionSpace.xs),
            Expanded(
              child: _candidates.isEmpty
                  ? const NotionEmptyState(
                      icon: Icons.people_outline,
                      title: 'No chats to merge',
                      message:
                          'Only one-to-one chats can be merged. Network groups stay separate.',
                    )
                  : visible.isEmpty
                  ? const NotionEmptyState(
                      icon: Icons.search_off_outlined,
                      title: 'No matching chats',
                      message: 'Try another name or network.',
                    )
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final candidate = visible[index];
                        final row = _CandidateRow(
                          key: ValueKey(candidate.entityId),
                          candidate: candidate,
                          selected: _selected.contains(candidate.entityId),
                          enabled: _current,
                          avatar: personalConversationAvatar(
                            widget.personal,
                            entityId: candidate.entityId,
                            avatar: _projection.avatarFor(
                              candidate.representative,
                            ),
                            name: candidate.name,
                            client: widget.personal.client,
                            size: NotionSize.avatar,
                          ),
                          onTap: () => _toggle(candidate),
                        );
                        if (!suggesting ||
                            (index != 0 && index != _suggested.length)) {
                          return row;
                        }
                        // Section labels above the suggestions and the rest.
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            NotionSectionHeader(
                              title: index == 0 ? 'Suggested' : 'All chats',
                              padding: EdgeInsets.only(
                                top: index == 0 ? 0 : NotionSpace.sm,
                                bottom: NotionSpace.xxs,
                              ),
                            ),
                            row,
                          ],
                        );
                      },
                    ),
            ),
            const SizedBox(height: NotionSpace.sm),
            NotionButton.primary(
              key: const ValueKey('merge-confirm'),
              label: label,
              icon: widget.single ? Icons.swap_horiz : Icons.call_merge,
              expand: true,
              onPressed: ready ? _confirm : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final MergeCandidate candidate;
  final bool selected;
  final bool enabled;
  final Widget avatar;
  final VoidCallback onTap;
  const _CandidateRow({
    super.key,
    required this.candidate,
    required this.selected,
    required this.enabled,
    required this.avatar,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final networks = candidate.networks.toList()
      ..sort((a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)));
    final sources = candidate.sources.length;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: [
        candidate.name,
        for (final network in networks) notionNetworkLabel(network),
        if (sources > 1) '$sources chats',
      ].join(', '),
      child: NotionPressable(
        enabled: enabled,
        scale: NotionMotion.pressRow,
        child: AnimatedContainer(
          duration: NotionMotion.of(context, NotionMotion.quick),
          curve: NotionMotion.standard,
          decoration: BoxDecoration(
            color: selected ? tokens.colors.selected : Colors.transparent,
            borderRadius: NotionRadius.lgAll,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: NotionRadius.lgAll,
              onTap: enabled ? onTap : null,
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NotionSpace.xs,
                    vertical: NotionSpace.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: NotionSize.avatar,
                        child: avatar,
                      ),
                      const SizedBox(width: NotionSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              candidate.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.typography.body,
                            ),
                            const SizedBox(height: NotionSpace.xxs),
                            Wrap(
                              spacing: NotionSpace.xs,
                              runSpacing: NotionSpace.xxs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final network in networks)
                                  _NetworkBadge(network: network),
                                if (sources > 1)
                                  Text(
                                    '$sources chats',
                                    style: tokens.typography.captionMuted,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: NotionSpace.xs),
                      NotionMorphSwitcher(
                        rotate: false,
                        child: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          key: ValueKey(selected),
                          size: NotionSize.iconMd,
                          color: selected
                              ? tokens.colors.accent
                              : tokens.colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkBadge extends StatelessWidget {
  final String network;
  const _NetworkBadge({required this.network});
  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.colors.surface,
        borderRadius: NotionRadius.pillAll,
        border: Border.all(color: tokens.colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotionNetworkGlyph(network: network, size: NotionSize.iconSm - 2),
            const SizedBox(width: NotionSpace.xxs),
            Text(
              notionNetworkLabel(network),
              style: tokens.typography.captionMuted,
            ),
          ],
        ),
      ),
    );
  }
}
