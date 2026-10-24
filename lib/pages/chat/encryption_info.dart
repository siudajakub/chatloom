// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_service_chip.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class EncryptionInfo extends StatefulWidget {
  final Room room;

  const EncryptionInfo({super.key, required this.room});

  @override
  State<EncryptionInfo> createState() => _EncryptionInfoState();
}

/// The list footer rebuilds with the timeline. Loading the participants and
/// checking every device's signature chain runs only when something it
/// depends on can have changed: another room, encryption or membership
/// counts, a device-list change from sync, a return from the "Check" page,
/// or at most every [_maxAge] otherwise (verification done elsewhere).
///
/// Bridged chats never show it: their other members are the bridge bot and
/// puppets of the remote people, whose devices can never be cross-signed, so
/// the count was permanent noise in every chat. Nothing is loaded for them.
/// Encryption is unchanged; the user's own unverified sessions are reported
/// by the E2EE health notice (`lib/personal/encryption/e2ee_health.dart`).
class _EncryptionInfoState extends State<EncryptionInfo> {
  static const _maxAge = Duration(seconds: 30);
  Future<int>? _count;
  int _last = 0;
  int _shown = 0;
  Object? _inputs;
  DateTime _computedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _stale = false;
  StreamSubscription<SyncUpdate>? _deviceLists;

  Room get room => widget.room;

  @override
  void initState() {
    super.initState();
    _listen();
    _refresh();
  }

  @override
  void didUpdateWidget(EncryptionInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room.client, room.client)) _listen();
    if (_stale ||
        _inputsOf(room) != _inputs ||
        DateTime.now().difference(_computedAt) > _maxAge) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _deviceLists?.cancel();
    super.dispose();
  }

  void _listen() {
    _deviceLists?.cancel();
    _deviceLists = room.client.onSync.stream
        .where(
          (sync) =>
              (sync.deviceLists?.changed?.isNotEmpty ?? false) ||
              (sync.deviceLists?.left?.isNotEmpty ?? false),
        )
        .listen((_) => _stale = true);
  }

  static Object _inputsOf(Room room) => (
    room.id,
    isBridgedRoom(room),
    room.encrypted,
    room.summary.mJoinedMemberCount,
    room.summary.mInvitedMemberCount,
  );

  void _refresh() {
    _stale = false;
    _inputs = _inputsOf(room);
    _computedAt = DateTime.now();
    final count = _count = _unverifiedDevices();
    count.then((value) {
      if (mounted && identical(_count, count)) _last = value;
    }, onError: (Object _) {});
  }

  Future<int> _unverifiedDevices() async {
    if (!room.encrypted || isBridgedRoom(room)) return 0;
    final users = await room.requestParticipants();
    final devicesKeysLists = users
        .map((user) => room.client.userDeviceKeys[user.id])
        .nonNulls;
    final devices = devicesKeysLists.fold<List<DeviceKeys>>(
      [],
      (devices, devicesKeysList) => [
        ...devices,
        ...devicesKeysList.deviceKeys.values,
      ],
    );
    return devices
        .where(
          (device) =>
              !device.verified &&
              !device.blocked &&
              !device.hasValidSignatureChain(verifiedByTheirMasterKey: true) &&
              device.encryptToDevice,
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    if (isBridgedRoom(room)) return const SizedBox.shrink();
    return FutureBuilder(
      future: _count,
      initialData: _last,
      builder: (context, asyncSnapshot) {
        final unverifiedDevices = asyncSnapshot.data ?? _last;
        // The last non-zero count stays on the chip while it closes.
        if (unverifiedDevices > 0) _shown = unverifiedDevices;
        // UI-11: no AnimatedSize around the footer (it rebuilt with the
        // timeline); the notice reveals only when the count appears.
        return NotionSizeReveal(
          visible: unverifiedDevices > 0,
          alignment: Alignment.center,
          child: _shown == 0
              ? const SizedBox.shrink()
              : ConversationServiceChip(
                  text: TextSpan(
                    children: [
                      const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Icon(
                          Icons.lock_person_outlined,
                          size: NotionSize.iconSm,
                        ),
                      ),
                      const TextSpan(text: ' '),
                      TextSpan(
                        text: L10n.of(context).countUnverifiedDevices(_shown),
                      ),
                      const TextSpan(text: ' '),
                      ConversationServiceChip.link(
                        context,
                        recognizer: TapGestureRecognizer()
                          ..onTap = () {
                            // Verification there changes the count.
                            _stale = true;
                            context.go(
                              '${chatLocation(context, room.id)}/encryption',
                            );
                          },
                        text: 'Check',
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
