// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/read_targets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// One explicit public receipt per source, even while automatic receipts are
/// suppressed. Freeze every cutoff at the tap, before awaiting any source.
/// The cutoff is the newest server event of the page's loaded timeline
/// ([loadedEvents]) or the preview, never a local echo; a source with
/// nothing to mark is skipped ([conversationReadTargets]).
///
/// Shown only while a source is actually unread
/// ([conversationSourceUnread]): the user's own message or reaction, a read
/// receipt or the fully read marker at or after the newest message from
/// someone else hides it; bridge delivery reports and other hidden events
/// never show it.
class ConversationReadButton extends StatefulWidget {
  final List<Room> rooms;

  /// The events the page has loaded for a source room (its timeline).
  final Iterable<Event> Function(Room room)? loadedEvents;

  const ConversationReadButton({
    super.key,
    required this.rooms,
    this.loadedEvents,
  });

  @override
  State<ConversationReadButton> createState() => _ConversationReadButtonState();
}

class _ConversationReadButtonState extends State<ConversationReadButton> {
  bool _sending = false;
  final _subscriptions = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ConversationReadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent rebuilds on every timeline change; keep the subscriptions
    // unless the sources changed.
    if (oldWidget.rooms.length != widget.rooms.length ||
        Iterable<int>.generate(widget.rooms.length)
            .any((i) => !identical(oldWidget.rooms[i], widget.rooms[i]))) {
      _listen();
    }
  }

  /// Re-evaluates visibility only when a sync touches one of the sources
  /// (new message, an own local echo or send, the own receipt or fully read
  /// marker moved) or a source was marked read locally; the button alone
  /// rebuilds.
  void _listen() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final ids = {for (final room in widget.rooms) room.id};
    _subscriptions.add(
      PersonalPrivacy.readChanges.listen((room) {
        if (mounted && widget.rooms.any((r) => identical(r, room))) {
          setState(() {});
        }
      }),
    );
    for (final client in widget.rooms.map((room) => room.client).toSet()) {
      _subscriptions.add(
        client.onSync.stream.listen((update) {
          final joined = update.rooms?.join;
          if (joined == null || !mounted) return;
          if (ids.any(joined.containsKey)) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _read() async {
    if (_sending ||
        !PersonalPrivacy.surfaceUnlocked ||
        !PersonalPrivacy.surfaceForeground ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    var targets = conversationReadTargets(
      widget.rooms,
      loaded: widget.loadedEvents,
    );
    final counted = [
      for (final room in widget.rooms)
        if (room.notificationCount > 0) room,
    ];
    if (targets.isEmpty && counted.isEmpty) return;
    setState(() => _sending = true);
    try {
      // A counted chat needs its newest server event of any kind: the
      // preview skips a reaction to the user's message, which Beeper counts.
      if (counted.isNotEmpty) {
        final newest = {
          for (final room in counted) room: await newestServerEventId(room),
        };
        targets = [
          for (final (room, id) in targets)
            if (!newest.containsKey(room)) (room, id),
          for (final MapEntry(key: room, value: id) in newest.entries)
            if (id != null) (room, id),
        ];
        if (targets.isEmpty) return;
      }
      final failed = await markConversationRead(targets, publicReceipt: true);
      if (failed > 0) throw StateError('Read marker not confirmed');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Couldn’t mark as read.'),
            action: SnackBarAction(label: 'Retry', onPressed: _read),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final needed =
        _sending ||
        conversationNeedsPublicRead(widget.rooms, loaded: widget.loadedEvents);
    if (!needed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: NotionSpace.xs),
      child: NotionGlassPill(
        icon: _sending ? Icons.more_horiz : Icons.done_all,
        tooltip: L10n.of(context).markAsRead,
        onPressed: _sending || widget.rooms.isEmpty ? null : _read,
      ),
    );
  }
}
