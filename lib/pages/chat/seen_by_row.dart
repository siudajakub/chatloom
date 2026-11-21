// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/personal/media/avatar_resolver.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Position each reader under the most recent outgoing bubble they reached.
/// Event order comes from the source timeline, including hidden receipt targets.
/// In a merged chat a receipt can only advance on its own source.
class SeenByPositions {
  SeenByPositions(
    List<Event> events,
    List<MediaAlbumSlot?> albums,
    Timeline? Function(Event) timelineFor,
  ) {
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (!isAnchor(event)) continue;
      var positions = _sources[event.room];
      if (positions == null) {
        final timeline = timelineFor(event);
        if (timeline == null) continue;
        positions = _sources[event.room] = _SeenBySource(timeline);
      }
      positions.anchors[event.eventId] =
          albums[i]?.members.last.eventId ?? event.eventId;
    }
  }

  final _sources = <Room, _SeenBySource>{};

  static bool isAnchor(Event event) =>
      event.senderId == event.room.client.userID &&
      event.status == EventStatus.synced &&
      !event.redacted &&
      (event.type == EventTypes.Message ||
          event.type == EventTypes.Sticker ||
          event.type == PollEventContent.startType) &&
      event.messageType != EventTypes.KeyVerificationRequest &&
      event.messageType != MessageTypes.Notice;

  List<String> readersOf(Event event, ReceiptTargets targets) =>
      _sources[event.room]?.readersOf(event.eventId, targets) ?? const [];
}

class _SeenBySource {
  _SeenBySource(this.timeline);

  final Timeline timeline;
  final anchors = <String, String>{};
  ReceiptTargets? _targets;
  final _readers = <String, List<String>>{};

  List<String> readersOf(String eventId, ReceiptTargets targets) {
    if (!identical(_targets, targets)) {
      _targets = targets;
      _readers.clear();
      _project(targets.readersAt);
    }
    return _readers[eventId] ?? const [];
  }

  void _project(Map<String, Set<String>> readersAt) {
    if (readersAt.isEmpty) return;
    final remaining = readersAt.values.expand((readers) => readers).toSet();
    final waiting = <String>{};
    for (final event in timeline.events) {
      final readers = readersAt[event.eventId];
      if (readers != null) {
        waiting.addAll(readers.where(remaining.remove));
      }
      final anchor = anchors[event.eventId];
      if (anchor == null || waiting.isEmpty) continue;
      (_readers[anchor] ??= []).addAll(waiting);
      if (remaining.isEmpty) break;
      waiting.clear();
    }
    for (final readers in _readers.values) {
      readers.sort();
    }
  }
}

class SeenByRow extends StatelessWidget {
  final Event event;
  final SeenByPositions positions;
  final RoomReadReceipts? source;

  const SeenByRow({
    super.key,
    required this.event,
    required this.positions,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final receipts = source ?? RoomReadReceipts.of(event.room);
    return ListenableBuilder(
      listenable: receipts,
      builder: (context, _) => _SeenAvatars(
        room: event.room,
        readers: positions.readersOf(event, receipts.targets),
      ),
    );
  }
}

class _SeenAvatars extends StatefulWidget {
  const _SeenAvatars({required this.room, required this.readers});

  final Room room;
  final List<String> readers;

  @override
  State<_SeenAvatars> createState() => _SeenAvatarsState();
}

class _SeenAvatarsState extends State<_SeenAvatars> {
  static const _maxAvatars = 5;
  late final Set<String> _initialReaders;
  late List<String> _displayedReaders;

  @override
  void initState() {
    super.initState();
    _initialReaders = widget.readers.toSet();
    _displayedReaders = widget.readers;
  }

  @override
  void didUpdateWidget(_SeenAvatars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.readers.isNotEmpty) _displayedReaders = widget.readers;
  }

  @override
  Widget build(BuildContext context) {
    final readers = _displayedReaders;
    final more = readers.length - _maxAvatars;
    return NotionSizeReveal(
      visible: widget.readers.isNotEmpty,
      alignment: AlignmentDirectional.topEnd,
      child: Padding(
        padding: const EdgeInsets.only(top: NotionSpace.xxs),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: NotionSpace.xxs,
          runSpacing: NotionSpace.xxs,
          children: [
            for (final id in readers.take(_maxAvatars))
              NotionEntrance(
                key: ValueKey(id),
                enabled: !_initialReaders.contains(id),
                afterRoute: false,
                rise: -NotionSpace.xs,
                duration: NotionMotion.short,
                child: _avatar(id),
              ),
            if (more > 0)
              Tooltip(
                message: readers
                    .skip(_maxAvatars)
                    .map((id) => _user(id).calcDisplayname())
                    .join(', '),
                child: Text('+$more', style: NotionType.caption),
              ),
          ],
        ),
      ),
    );
  }

  User _user(String id) => widget.room.unsafeGetUserFromMemoryOrFallback(id);

  Widget _avatar(String id) {
    final user = _user(id);
    final name = user.calcDisplayname();
    return Tooltip(
      message: 'Seen by $name',
      child: Avatar(
        client: widget.room.client,
        mxContent: userAvatarUri(user),
        name: name,
        size: NotionSize.iconSm,
        shapeBorder: const CircleBorder(),
      ),
    );
  }
}
