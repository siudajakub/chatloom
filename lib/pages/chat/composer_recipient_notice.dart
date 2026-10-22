// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/other_party_can_receive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A calm line above the composer when nobody else in an encrypted chat has
/// a device that could decrypt a message.
///
/// [OtherPartyCanReceiveExtension.otherPartyCanReceiveMessages] only reads
/// what this device already knows: before the device list and the member
/// list are loaded it reports "nobody". The notice therefore appears only
/// after both were loaded once (the same lookup the SDK does before it
/// encrypts) and the answer is still "nobody". The composer stays usable:
/// the other side may sign in later, and the bubble shows the send result.
class ComposerRecipientNotice extends StatefulWidget {
  final Room room;

  /// Loads members and device keys; tests replace it.
  final Future<void> Function(Room room)? confirm;

  const ComposerRecipientNotice({super.key, required this.room, this.confirm});

  static const text = 'No one in this chat can read encrypted messages yet.';

  @override
  State<ComposerRecipientNotice> createState() =>
      _ComposerRecipientNoticeState();
}

class _ComposerRecipientNoticeState extends State<ComposerRecipientNotice> {
  /// The room whose member and device lists were loaded once.
  String? _confirmedRoom;
  String? _confirming;

  static Future<void> _load(Room room) async {
    await room.client.userDeviceKeysLoading;
    await room.requestParticipants(const [
      Membership.join,
      Membership.invite,
    ], true);
  }

  void _confirm(Room room) {
    if (_confirming == room.id || _confirmedRoom == room.id) return;
    _confirming = room.id;
    unawaited(
      (widget.confirm ?? _load)(room).catchError((Object _) {}).whenComplete(
        () {
          if (!mounted || _confirming != room.id) return;
          setState(() {
            _confirming = null;
            _confirmedRoom = room.id;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final unreachable = !room.otherPartyCanReceiveMessages;
    if (unreachable) _confirm(room);
    final visible = unreachable && _confirmedRoom == room.id;
    final tokens = context.notion;
    return NotionSizeReveal(
      visible: visible,
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NotionSpace.md,
            NotionSpace.xs,
            NotionSpace.md,
            0,
          ),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: NotionSize.iconSm,
                color: tokens.colors.textSecondary,
              ),
              const SizedBox(width: NotionSpace.xs),
              Expanded(
                child: Text(
                  ComposerRecipientNotice.text,
                  style: tokens.typography.footnoteMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
