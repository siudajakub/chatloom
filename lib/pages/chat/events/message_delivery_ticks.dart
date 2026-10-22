// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The ticks beside the time of an own message. [progress] is what the row
/// already knows from its timeline (sent or delivered); "read" and the bridge
/// bot's delivery receipt come from the room's [RoomReadReceipts], so a
/// receipt rebuilds only these glyphs, never the bubble or the list.
class MessageDeliveryTicks extends StatelessWidget {
  const MessageDeliveryTicks({
    super.key,
    required this.event,
    required this.timeline,
    required this.progress,
    this.color,
    this.readColor,
  });

  final Event event;
  final Timeline timeline;
  final DeliveryProgress progress;
  final Color? color;
  final Color? readColor;

  @override
  Widget build(BuildContext context) {
    final settled =
        progress == DeliveryProgress.sent ||
        progress == DeliveryProgress.delivered;
    if (!settled) {
      final tick = progress.tick;
      if (tick == null) return const SizedBox.shrink();
      return _tick(tick);
    }
    final receipts = RoomReadReceipts.of(event.room);
    return ListenableBuilder(
      listenable: receipts,
      builder: (context, _) {
        final snapshot = receipts.snapshotOf(timeline);
        final state = snapshot.isRead(event)
            ? NotionDeliveryState.read
            : progress == DeliveryProgress.delivered ||
                  snapshot.isAcknowledged(event)
            ? NotionDeliveryState.delivered
            : NotionDeliveryState.sent;
        return _tick(state);
      },
    );
  }

  Widget _tick(NotionDeliveryState state) => NotionDeliveryTick(
    key: const ValueKey('message-delivery-tick'),
    state: state,
    color: color,
    readColor: readColor,
  );
}
