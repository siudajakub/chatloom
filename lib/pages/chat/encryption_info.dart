// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/person_location.dart';
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
class _EncryptionInfoState extends State<EncryptionInfo> {
  static const _maxAge = Duration(seconds: 30);
  Future<int>? _count;
  int _last = 0;
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
    if (!room.encrypted) return 0;
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
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: ChatLoomThemes.animationDuration,
      curve: ChatLoomThemes.animationCurve,
      child: FutureBuilder(
        future: _count,
        initialData: _last,
        builder: (context, asyncSnapshot) {
          final unverifiedDevices = asyncSnapshot.data ?? _last;
          if (unverifiedDevices == 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Material(
                  color: theme.colorScheme.surface.withAlpha(128),
                  borderRadius: BorderRadius.circular(
                    AppConfig.borderRadius / 3,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 4.0,
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            child: Icon(Icons.lock_person_outlined, size: 13),
                          ),
                          TextSpan(text: ' '),
                          TextSpan(
                            text: L10n.of(
                              context,
                            ).countUnverifiedDevices(unverifiedDevices),
                          ),
                          TextSpan(text: ' '),
                          TextSpan(
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              decoration: TextDecoration.underline,
                              decorationColor: theme.colorScheme.primary,
                            ),
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
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
