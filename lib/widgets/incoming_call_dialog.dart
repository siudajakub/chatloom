// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class IncomingCallDialog extends StatefulWidget {
  final Event event;
  const IncomingCallDialog({required this.event, super.key});

  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog> {
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription? _onSync;

  @override
  void initState() {
    _initAudioPlayer();
    _onSync = widget.event.room.client.onSync.stream.listen((_) {
      if (!mounted) return;
      if (!widget.event.room.hasActiveMatrixRtcCall) {
        Logs().i('The other party has ended the call');
        Navigator.of(context).pop();
      } else if (widget.event.room.getActiveMatrixRtcMembers().any(
        (member) =>
            member.senderId == widget.event.room.client.userID! &&
            member.deviceId != widget.event.room.client.deviceID!,
      )) {
        Logs().i('User has accepted the call on a different device');
        Navigator.of(context).pop();
      }
    });
    final timeout =
        widget.event.tryParseRtcNotificationContent()?.lifetime ??
        RtcNotificationContent.defaultLifetime;
    Future.delayed(timeout).then((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
    super.initState();
  }

  Future<void> _initAudioPlayer() async {
    await _player.setAsset('assets/sounds/call_ring.mp3');
    await _player.setLoopMode(.one);
    await _player.play();
  }

  @override
  void dispose() {
    _onSync?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayname = widget.event.room.getLocalizedDisplayname();
    final avatar = widget.event.room.avatar;
    final colors = context.notion.colors;
    Widget callButton({
      required IconData icon,
      required Color color,
      required String tooltip,
      required bool accept,
    }) => NotionPressable(
      scale: NotionMotion.pressIcon,
      child: IconButton(
        tooltip: tooltip,
        style: IconButton.styleFrom(
          fixedSize: const Size.fromRadius(NotionSpace.xl),
          backgroundColor: color,
          foregroundColor: NotionMediaColors.onScrim,
        ),
        icon: Icon(icon),
        onPressed: () => context.pop(accept),
      ),
    );
    return AlertDialog(
      title: Center(child: Text(L10n.of(context).incomingCall)),
      content: Column(
        mainAxisSize: .min,
        spacing: NotionSpace.xs,
        children: [
          // The caller springs in, then rings for as long as the call does.
          NotionPop(
            bounce: false,
            from: NotionMotion.dialogFrom,
            child: NotionPulse(
              color: colors.accent,
              borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
              child: Avatar(mxContent: avatar, name: displayname),
            ),
          ),
          NotionEntrance(
            index: 1,
            afterRoute: false,
            child: Text(displayname, textAlign: .center),
          ),
        ],
      ),
      actionsAlignment: .spaceEvenly,
      actions: [
        NotionEntrance(
          index: 2,
          afterRoute: false,
          scale: NotionMotion.popFrom,
          rise: 0,
          child: callButton(
            icon: Icons.call_end_outlined,
            color: colors.danger,
            tooltip: L10n.of(context).reject,
            accept: false,
          ),
        ),
        NotionEntrance(
          index: 3,
          afterRoute: false,
          scale: NotionMotion.popFrom,
          rise: 0,
          child: NotionPulse(
            color: colors.success,
            child: callButton(
              icon: Icons.call_outlined,
              color: colors.success,
              tooltip: L10n.of(context).accept,
              accept: true,
            ),
          ),
        ),
      ],
    );
  }
}
