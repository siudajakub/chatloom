// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// One explicit public receipt per source, even while automatic receipts are
/// suppressed. Freeze every cutoff at the tap, before awaiting any source.
class ConversationReadButton extends StatefulWidget {
  final List<Room> rooms;

  const ConversationReadButton({super.key, required this.rooms});

  @override
  State<ConversationReadButton> createState() => _ConversationReadButtonState();
}

class _ConversationReadButtonState extends State<ConversationReadButton> {
  bool _sending = false;

  Future<void> _read() async {
    if (_sending ||
        !PersonalPrivacy.surfaceUnlocked ||
        !PersonalPrivacy.surfaceForeground ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final targets = [
      for (final room in widget.rooms) (room, room.lastEvent?.eventId),
    ];
    setState(() => _sending = true);
    try {
      await Future.wait(
        targets.map((target) async {
          final (room, id) = target;
          if (id == null ||
              !id.startsWith(r'$') ||
              room.client.baseUri == null) {
            throw StateError('Read target unavailable');
          }
          await PersonalPrivacy.markRead(
            room,
            id,
            manual: true,
            publicReceipt: true,
          );
        }),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not mark all messages as read. Tap to retry.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => NotionGlassPill(
    icon: _sending ? Icons.more_horiz : Icons.done_all,
    tooltip: L10n.of(context).markAsRead,
    onPressed: _sending || widget.rooms.isEmpty ? null : _read,
  );
}
