// SPDX-License-Identifier: AGPL-3.0-or-later
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

  Future<void> _read() async {
    if (_sending ||
        !PersonalPrivacy.surfaceUnlocked ||
        !PersonalPrivacy.surfaceForeground ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final targets = conversationReadTargets(
      widget.rooms,
      loaded: widget.loadedEvents,
    );
    if (targets.isEmpty) return;
    setState(() => _sending = true);
    try {
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
  Widget build(BuildContext context) => NotionGlassPill(
    icon: _sending ? Icons.more_horiz : Icons.done_all,
    tooltip: L10n.of(context).markAsRead,
    onPressed: _sending || widget.rooms.isEmpty ? null : _read,
  );
}
