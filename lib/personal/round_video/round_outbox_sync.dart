// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'telegram_round_service.dart';

/// Keeps the bubbles of a Telegram chat's own round videos in line with the
/// durable round queue when the chat opens ([TelegramRoundService
/// .reconcileRoom]): accepted rounds drop their local copy, unsent ones say
/// "Not sent · Tap to retry". Renders nothing: every round shows its
/// delivery in its own bubble, like any other message.
class RoundOutboxSync extends StatefulWidget {
  final Room room;
  const RoundOutboxSync({super.key, required this.room});

  @override
  State<RoundOutboxSync> createState() => _RoundOutboxSyncState();
}

class _RoundOutboxSyncState extends State<RoundOutboxSync> {
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RoundOutboxSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id ||
        !identical(oldWidget.room.client, widget.room.client)) {
      _sync();
    }
  }

  void _sync() {
    final room = widget.room;
    // After the first frame: the chat opens without waiting for storage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(room, widget.room)) return;
      unawaited(
        TelegramRoundService.of(
          room.client,
        ).reconcileRoom(room).catchError((Object _) {}),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
