// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

/// Moving around one conversation (FX-06, FX-10, FX-11), shared by the
/// ordinary chat and the merged person chat: putting a row under the glass
/// header, the unread-mention and first-unread buttons over the list, jump
/// to date, and the open chat a search hit returns to.

// ---------------------------------------------------------------------------
// Positioning.

/// Scroll offset that puts the top of row [index] just under the header
/// (and pinned bar) drawn over the reversed list, clamped to the list's
/// extent; null while the row is not laid out.
double? conversationUnderHeaderOffset(
  AutoScrollController controller,
  int index,
) {
  final box = controller.tagMap[index]?.context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final viewport = RenderAbstractViewport.maybeOf(box);
  if (viewport == null) return null;
  final position = controller.position;
  // The reversed list's trailing edge is its top.
  final reveal = viewport.getOffsetToReveal(box, 1).offset;
  final header =
      position.context.storageContext
          .getInheritedWidgetOfExactType<MediaQuery>()
          ?.data
          .padding
          .top ??
      0;
  return (reveal + header + NotionSpace.xs).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
}

/// Scrolls so row [index] sits right under the glass header (the unread
/// divider, a day's first message). [animate]: glide like the jump button
/// (instant under reduced motion); otherwise jump (opening a chat).
Future<bool> conversationRevealRow(
  BuildContext context,
  AutoScrollController controller,
  int index, {
  required bool animate,
}) async {
  if (index < 0 || !controller.hasClients) return false;
  if (!controller.isIndexStateInLayoutRange(index)) {
    await controller.scrollToIndex(
      index,
      duration: NotionMotion.short,
      preferPosition: AutoScrollPosition.end,
    );
    if (!context.mounted || !controller.hasClients) return false;
  }
  final target = conversationUnderHeaderOffset(controller, index);
  if (target == null) return false;
  if (animate && !ConversationMotion.reduced(context)) {
    await controller.animateTo(
      target,
      duration: NotionMotion.long,
      curve: NotionMotion.emphasized,
    );
  } else {
    controller.jumpTo(target);
  }
  return true;
}

// ---------------------------------------------------------------------------
// Unread mentions (Telegram's "@" button).

/// Unread messages of others that the push rules highlight (mentions,
/// keywords), oldest first: the rows newer than [markerRow] (rows are newest
/// first; -1 = every loaded row is unread) minus [handled].
List<Event> conversationUnreadMentions(
  List<Event> rows,
  int markerRow, {
  required bool Function(Event event) highlighted,
  Set<String> handled = const {},
}) {
  final end = markerRow < 0 ? rows.length : math.min(markerRow, rows.length);
  final result = <Event>[];
  for (var i = end - 1; i >= 0; i--) {
    final event = rows[i];
    if (event.senderId == event.room.client.userID) continue;
    if (handled.contains(event.eventId)) continue;
    if (highlighted(event)) result.add(event);
  }
  return result;
}

/// Whether [event] notifies with a highlight under the account's push rules.
bool conversationHighlights(Event event) {
  try {
    return event.room.client.pushruleEvaluator.match(event).highlight;
  } catch (_) {
    return false;
  }
}

/// Unread mentions of [rooms] still to visit: the server's highlight counts
/// minus the ones this page already jumped to.
int conversationMentionCount(Iterable<Room> rooms, int handled) => math.max(
  0,
  rooms.fold<int>(0, (sum, r) => sum + r.highlightCount) - handled,
);

/// The accent "@" over the jump button while the chat has unread mentions
/// (Telegram): it counts them and goes to the oldest one on each tap. Only
/// this button follows sync (the highlight counts arrive with it); the page
/// never rebuilds for it.
class ConversationMentionButton extends StatefulWidget {
  const ConversationMentionButton({
    super.key,
    required this.rooms,
    required this.handled,
    required this.onPressed,
  });

  final List<Room> rooms;

  /// Mentions this page already jumped to.
  final ValueListenable<int> handled;
  final VoidCallback onPressed;

  @override
  State<ConversationMentionButton> createState() =>
      _ConversationMentionButtonState();
}

class _ConversationMentionButtonState extends State<ConversationMentionButton> {
  StreamSubscription<SyncUpdate>? _sync;
  Set<String> _ids = const {};
  int _count = 0;

  @override
  void initState() {
    super.initState();
    widget.handled.addListener(_recount);
    _subscribe();
  }

  @override
  void didUpdateWidget(ConversationMentionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.handled, widget.handled)) {
      oldWidget.handled.removeListener(_recount);
      widget.handled.addListener(_recount);
    }
    final ids = {for (final room in widget.rooms) room.id};
    if (!const SetEquality<String>().equals(ids, _ids) ||
        !identical(
          oldWidget.rooms.firstOrNull?.client,
          widget.rooms.firstOrNull?.client,
        )) {
      _subscribe();
    } else {
      _count = _current();
    }
  }

  int _current() =>
      conversationMentionCount(widget.rooms, widget.handled.value);

  void _subscribe() {
    unawaited(_sync?.cancel());
    _ids = {for (final room in widget.rooms) room.id};
    _count = _current();
    final client = widget.rooms.firstOrNull?.client;
    if (client == null) return;
    _sync = client.onSync.stream.listen((update) {
      final joined = update.rooms?.join;
      if (joined == null || !_ids.any(joined.containsKey)) return;
      _recount();
    });
  }

  void _recount() {
    if (!mounted) return;
    final count = _current();
    if (count != _count) setState(() => _count = count);
  }

  @override
  void dispose() {
    unawaited(_sync?.cancel());
    widget.handled.removeListener(_recount);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final visible = _count > 0;
    return ExcludeSemantics(
      excluding: !visible,
      child: NotionSizeReveal(
        visible: visible,
        alignment: AlignmentDirectional.bottomEnd,
        child: Padding(
          padding: const EdgeInsets.only(bottom: NotionSpace.xs),
          child: Badge(
            backgroundColor: notion.palette.accentFill,
            textColor: notion.palette.onAccentFill,
            label: NotionAnimatedCount(
              count: _count,
              format: (n) => n > 99 ? '99+' : '$n',
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: notion.colors.accent),
              // No blur: the button reveals and hides (glass never animates).
              child: NotionGlassPill(
                key: const ValueKey('conversation-mention'),
                icon: Icons.alternate_email,
                tooltip: 'Unread mentions',
                onPressed: widget.onPressed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "First unread" over the jump button: only when the chat could not be
/// opened at its first unread message (the history around the read marker
/// did not load). A tap goes there; it replaces FluffyChat's "Jump to last
/// read message" banner and never blocks the read marker.
class ConversationFirstUnreadButton extends StatelessWidget {
  const ConversationFirstUnreadButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: !visible,
    child: NotionSizeReveal(
      visible: visible,
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: const EdgeInsets.only(bottom: NotionSpace.xs),
        child: NotionGlassPill(
          key: const ValueKey('conversation-first-unread'),
          icon: Icons.keyboard_arrow_up,
          label: 'First unread',
          tooltip: 'Go to the first unread message',
          onPressed: onPressed,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Jump to date.

/// The oldest row (rows newest first) sent on [day] or later, or -1 when
/// every row is older. A day without messages lands on the next message
/// after it (Telegram).
int conversationRowForDay(List<Event> rows, DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  for (var i = rows.length - 1; i >= 0; i--) {
    if (!rows[i].originServerTs.toLocal().isBefore(start)) return i;
  }
  return -1;
}

/// Whether the loaded [rows] reach back to [day] (the oldest row is older
/// than its start), i.e. no more history is needed to find it.
bool conversationRowsReachDay(List<Event> rows, DateTime day) {
  final oldest = rows.lastOrNull;
  if (oldest == null) return false;
  return oldest.originServerTs.toLocal().isBefore(
    DateTime(day.year, day.month, day.day),
  );
}

/// Asks for a day of the conversation, starting at [around].
Future<DateTime?> pickConversationDay(BuildContext context, DateTime around) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return showNotionDatePicker(
    context: context,
    initialDate: around.toLocal(),
    firstDate: DateTime(2000),
    lastDate: today,
  );
}

// ---------------------------------------------------------------------------
// The open chat a search hit returns to (FX-03).

class _JumpTarget {
  _JumpTarget(this.owner, this.covers, this.jump);
  final State owner;
  final bool Function(Room room) covers;
  final Future<void> Function(Event event) jump;
}

/// Open conversation pages that can show a message in place. A hit in
/// "Search messages" or shared content pops back to the chat it came from
/// and jumps there, instead of stacking a second chat page (two timelines,
/// two read-marker owners).
abstract final class ConversationJumpTargets {
  static final _targets = <_JumpTarget>[];

  /// [covers] says whether a room is shown by [owner]; [jump] scrolls to a
  /// message of such a room.
  static void register(
    State owner, {
    required bool Function(Room room) covers,
    required Future<void> Function(Event event) jump,
  }) {
    unregister(owner);
    _targets.add(_JumpTarget(owner, covers, jump));
  }

  static void unregister(State owner) =>
      _targets.removeWhere((target) => identical(target.owner, owner));

  /// Pops [context]'s navigator back to the newest open page that shows
  /// [event]'s room and jumps to it there. False when no such page is below
  /// in the same navigator (the caller opens the message another way).
  static bool open(BuildContext context, Event event) {
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return false;
    for (final target in _targets.reversed) {
      final owner = target.owner;
      if (!owner.mounted || !target.covers(event.room)) continue;
      final route = ModalRoute.of(owner.context);
      if (route == null || !route.isActive || route.navigator != navigator) {
        continue;
      }
      if (!route.isCurrent) navigator.popUntil((r) => r == route);
      unawaited(target.jump(event));
      return true;
    }
    return false;
  }

  @visibleForTesting
  static int get length => _targets.length;
}
