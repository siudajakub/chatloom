// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The ticks beside the time of an own message. [progress] is what the row
/// already knows from its timeline (sent or delivered); "read" and the bridge
/// bot's delivery receipt come from the room's [RoomReadReceipts], so a
/// receipt rebuilds only these glyphs, never the bubble or the list.
///
/// While the message is sending it shows Telegram's clock (after the loader
/// grace). The tree has one shape in every state, so the clock turns into
/// the ✓ in place instead of the tick being mounted anew.
class MessageDeliveryTicks extends StatelessWidget {
  const MessageDeliveryTicks({
    super.key,
    required this.event,
    required this.timeline,
    required this.progress,
    this.color,
    this.readColor,
    this.clock = true,
    this.backdrop,
    this.readAvatars = false,
    this.receiptSource,
  });

  final Event event;
  final Timeline timeline;
  final DeliveryProgress progress;
  final Color? color;
  final Color? readColor;
  final Color? backdrop;

  /// Show the clock while sending; false when an upload ring already shows
  /// the progress (the slot stays, so the ✓ still grows in place).
  final bool clock;
  final bool readAvatars;
  final RoomReadReceipts? receiptSource;

  @override
  Widget build(BuildContext context) {
    final settled =
        progress == DeliveryProgress.sent ||
        progress == DeliveryProgress.delivered;
    final receipts = settled
        ? receiptSource ?? RoomReadReceipts.of(event.room)
        : null;
    return ListenableBuilder(
      listenable: receipts ?? const _Unchanging(),
      builder: (context, _) {
        if (receipts == null) {
          final tick = progress.tick;
          return tick == null ? const SizedBox.shrink() : _tick(tick);
        }
        final snapshot = receipts.snapshotOf(timeline);
        final read = snapshot.isRead(event);
        if (read && readAvatars) return const SizedBox.shrink();
        final state = read
            ? NotionDeliveryState.read
            : progress == DeliveryProgress.delivered ||
                  snapshot.isAcknowledged(event)
            ? NotionDeliveryState.delivered
            : NotionDeliveryState.sent;
        return _tick(state);
      },
    );
  }

  Widget _tick(NotionDeliveryState state) => ConversationMetaChip(
    backdrop: backdrop,
    child: NotionDeliveryTick(
      key: const ValueKey('message-delivery-tick'),
      state: state,
      color: color,
      readColor: readColor,
      sendingClock: clock
          ? NotionSendingClock.delayed
          : NotionSendingClock.hidden,
    ),
  );
}

/// A listenable that never notifies (a message whose receipts do not matter
/// yet), so the ticks keep one tree shape.
class _Unchanging implements Listenable {
  const _Unchanging();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
