// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The reactions under a bubble: one pill per emoji (Messenger's compact
/// chips, no square frame), most given first. Tap toggles your own
/// reaction, long-press lists who reacted.
class MessageReactions extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final bool strict;

  /// Ring around each chip in the chat background's colour, so chips that
  /// overlap the bubble's edge read as cut out of it.
  final Color? ring;

  const MessageReactions(
    this.event,
    this.timeline, {
    super.key,
    this.strict = false,
    this.ring,
  });

  /// A reaction younger than this when its chip first appears is treated as
  /// just added (it pops); older ones are history and appear still.
  static const Duration freshWindow = Duration(seconds: 4);

  @override
  State<MessageReactions> createState() => _MessageReactionsState();
}

class _MessageReactionsState extends State<MessageReactions> {
  /// Chips present when this row was first built. Later chips are new
  /// reactions and pop in; the first set pops only when it is fresh (the
  /// first reaction on a visible message), never for scrolled-in history.
  Set<String>? _initial;
  final _reconciler = ConversationReactionReconciler();
  ConversationReactionCoordinator? _manager;

  /// Emoji whose intent is unresolved (drawn dimmed); rebuilt only when it
  /// changes for this message.
  Set<String> _pending = const {};

  Event get event => widget.event;
  Timeline get timeline => widget.timeline;
  bool get strict => widget.strict;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(MessageReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId) _initial = null;
    if (!identical(oldWidget.event.room.client, widget.event.room.client)) {
      _listen();
    } else {
      _pending = _computePending();
    }
  }

  void _listen() {
    _manager?.removeListener(_changed);
    _manager = ConversationMessageActions.coordinator(event)
      ..addListener(_changed);
    _pending = _computePending();
  }

  Set<String> _computePending() {
    final manager = _manager!;
    return {
      for (final key in manager.keysFor(
        ConversationMessageActions.scope(event),
      ))
        if (manager.unresolved(key)) key.emoji,
    };
  }

  void _changed() {
    if (!mounted) return;
    final pending = _computePending();
    if (pending.length != _pending.length || !pending.containsAll(_pending)) {
      setState(() => _pending = pending);
    }
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allReactionEvents = event.aggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    );
    final reactionMap = <String, _ReactionEntry>{};
    final client = Matrix.of(context).client;

    for (final e in allReactionEvents) {
      final key = e.content
          .tryGetMap<String, Object?>('m.relates_to')
          ?.tryGet<String>('key');
      if (key == null) continue;
      final entry = reactionMap[key] ??= _ReactionEntry(
        key: key,
        order: reactionMap.length,
      );
      entry.count++;
      entry.reactors.add(e.senderFromMemoryOrFallback);
      entry.reacted |= e.senderId == e.room.client.userID;
      final sent = e.originServerTs;
      final latest = entry.latest;
      if (latest == null || sent.isAfter(latest)) entry.latest = sent;
    }

    final reactionList = reactionMap.values.toList();
    final now = DateTime.now();
    final initial = _initial ??= {
      for (final r in reactionList)
        if (r.latest == null ||
            now.difference(r.latest!) > MessageReactions.freshWindow)
          r.key,
    };
    // Most given first; ties keep the order they were first given in.
    reactionList.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.order.compareTo(b.order);
    });
    _reconciler.didBuild(context, event, timeline);
    final ownMessage = event.senderId == event.room.client.userID;
    return Wrap(
      spacing: NotionSpace.xxs,
      runSpacing: NotionSpace.xxs,
      alignment: ownMessage ? WrapAlignment.end : WrapAlignment.start,
      children: [
        for (final r in reactionList)
          NotionReactionChip(
            key: ValueKey(r.key),
            popIn: !initial.contains(r.key),
            emoji: _ReactionGlyph(r.key),
            count: r.count,
            own: r.reacted,
            ring: widget.ring,
            pending: _pending.contains(r.key),
            semanticLabel:
                '${r.key}, ${r.count} reactions${_pending.contains(r.key) ? ', waiting for source confirmation' : ''}',
            onTap: () => ConversationMessageActions.react(
              context,
              event,
              timeline,
              r.key,
              toggle: true,
              strict: strict,
            ),
            onLongPress: () => _showReactors(context, client: client, entry: r),
          ),
      ],
    );
  }
}

class _ReactionGlyph extends StatelessWidget {
  final String reactionKey;
  const _ReactionGlyph(this.reactionKey);

  @override
  Widget build(BuildContext context) {
    if (reactionKey.startsWith('mxc://')) {
      return MxcImage(
        uri: Uri.parse(reactionKey),
        width: NotionReactions.chipEmoji + NotionSpace.xxs,
        height: NotionReactions.chipEmoji + NotionSpace.xxs,
        animated: false,
        isThumbnail: false,
      );
    }
    var renderKey = Characters(reactionKey);
    if (renderKey.length > 10) {
      renderKey = renderKey.getRange(0, 9) + Characters('…');
    }
    return Text(
      renderKey.toString(),
      maxLines: 1,
      style: NotionType.callout.copyWith(
        fontSize: NotionReactions.chipEmoji,
        height: 1.2,
      ),
    );
  }
}

class _ReactionEntry {
  final String key;

  /// Position of the first reaction with this key, for stable ties.
  final int order;
  int count = 0;
  bool reacted = false;
  final List<User> reactors = [];

  /// Newest reaction with this key, for the "just added" pop.
  DateTime? latest;

  _ReactionEntry({required this.key, required this.order});
}

/// Who reacted with one emoji, as a Notion sheet of avatars and names.
Future<void> _showReactors(
  BuildContext context, {
  required Client client,
  required _ReactionEntry entry,
}) => showNotionSheet<void>(
  context: context,
  title: entry.key.startsWith('mxc://') ? null : entry.key,
  builder: (context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .5,
    ),
    child: ListView(
      shrinkWrap: true,
      children: [
        for (final reactor in entry.reactors)
          NotionListRow(
            leading: Avatar(
              mxContent: reactor.avatarUrl,
              name: reactor.calcDisplayname(),
              client: client,
              size: NotionSize.avatar,
            ),
            title: reactor.calcDisplayname(),
          ),
      ],
    ),
  ),
);
