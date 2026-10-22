// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

// "Sign out of <network>" (wave 4, decided by J on 2026-10-21).
//
// Every bridge J runs is a mautrix bridgev2 bridge (mautrix-go v0.32.0).
// bridgev2 documents one sign-out command, `logout <login ID>`
// (`bridgev2/commands/login.go`, `CommandLogout`: no aliases, no
// confirmation; the bridge logs out remotely and deletes the login at
// once), so the confirmation lives in the app. The bridge reads a message as
// a command when it starts with its `command_prefix` and a space, in any
// room, or when it arrives in the user's management room, where the prefix
// is optional (`bridgev2/queue.go`).
//
// The login ID is the bridge's `remote_id`. bbctl's bridge config turns
// state notices off (`bridge_status_notices: none`), so the ID, the exact
// prefix and the management room come from the provisioning API
// `GET /v3/whoami` (`logins[].id`, `command_prefix`, `management_room`),
// which the app already uses for bridge contact search. Logins seen in the
// bridge's own state notices are the fallback; the room those notices
// arrive in is the management room, so no prefix is needed there.

/// Sends one bridge command as a plain text message (test seam).
typedef BridgeCommandSender = Future<void> Function(Room room, String body);

/// The bridge's provisioning `whoami` for a network, or null when the
/// account cannot reach it (test seam).
typedef BridgeWhoamiReader = Future<BridgeWhoami?> Function(String network);

/// The bridgev2 sign-out command for one login.
String bridgeLogoutCommand(String loginId, {String prefix = ''}) =>
    prefix.isEmpty ? 'logout $loginId' : '$prefix logout $loginId';

/// Where and what to send to sign out of one network.
@immutable
class NetworkSignOutPlan {
  const NetworkSignOutPlan(this.room, this.commands);
  final Room room;
  final List<String> commands;
}

class NetworkSignOut {
  NetworkSignOut({
    required this.client,
    required this.monitor,
    BridgeWhoamiReader? whoami,
    BridgeCommandSender? send,
  }) : _whoami = whoami ?? _provisioningWhoami(client),
       _send = send ?? _sendText;

  final Client client;
  final BridgeHealthMonitor monitor;
  final BridgeWhoamiReader _whoami;
  final BridgeCommandSender _send;

  static const _notFound = PersonalCapabilityUnavailable(
    'ChatLoom couldn’t find your account on this network. '
    'Open the bridge chat to sign out there.',
  );

  /// Sends the sign-out command for every signed-in login of [network].
  /// Throws a human-readable failure; nothing is sent when the login or the
  /// bridge chat is unknown.
  Future<void> signOut(String network) async {
    final plan = await this.plan(network);
    for (final command in plan.commands) {
      await _send(plan.room, command);
    }
  }

  Future<NetworkSignOutPlan> plan(String network) async {
    BridgeWhoami? whoami;
    try {
      whoami = await _whoami(network);
    } catch (error, stack) {
      // The notices below may still know the login.
      logBackgroundError('network_sign_out_whoami', error, stack);
    }
    if (whoami != null) {
      final logins = _ids(
        whoami.logins.where((login) => login.usable).map((login) => login.id),
      );
      if (logins.isEmpty) {
        throw const PersonalCapabilityUnavailable(
          'This network is already signed out.',
        );
      }
      final managementId = whoami.managementRoom;
      final management = managementId == null ? null : _joined(managementId);
      final prefix = whoami.commandPrefix;
      final room = management ?? monitor.managementRoom(network);
      // Without a prefix the bridge reads commands only in its management
      // room.
      if (room != null && (prefix.isNotEmpty || identical(room, management))) {
        return NetworkSignOutPlan(room, [
          for (final id in logins) bridgeLogoutCommand(id, prefix: prefix),
        ]);
      }
    }
    final signals = monitor.signalsFor(network);
    final roomId = signals?.managementRoomId;
    final room = roomId == null ? null : _joined(roomId);
    final logins = _ids([
      for (final report in signals?.reports.values ?? <BridgeStateReport>[])
        if (report.state != BridgeHealthState.loggedOut) report.login,
    ]);
    if (room == null || logins.isEmpty) throw _notFound;
    return NetworkSignOutPlan(room, [
      for (final id in logins) bridgeLogoutCommand(id),
    ]);
  }

  Room? _joined(String roomId) {
    final room = client.getRoomById(roomId);
    return room != null && room.membership == Membership.join ? room : null;
  }

  /// Distinct login IDs the command can carry (one word each).
  static List<String> _ids(Iterable<String> ids) => {
    for (final id in ids)
      if (id.isNotEmpty && id.length <= 256 && !id.contains(RegExp(r'\s'))) id,
  }.toList(growable: false);

  static BridgeWhoamiReader _provisioningWhoami(Client client) =>
      (network) async {
        final directory = BridgeDirectory.of(client);
        if (directory.api == null) return null;
        final bridge = discoverBridges(
          client.rooms,
        ).where((bridge) => bridge.network == network).firstOrNull;
        if (bridge == null) return null;
        if (!(directory.reaches?.call(bridge) ?? true)) return null;
        // Through the directory, so search sees the same logins.
        return directory.refreshLogins(bridge);
      };

  static Future<void> _sendText(Room room, String body) async {
    final eventId = await room.sendTextEvent(
      body,
      parseMarkdown: false,
      parseCommands: false,
      addMentions: false,
    );
    // The SDK gives up quietly (null) after its own retries.
    if (eventId == null) {
      throw TimeoutException('bridge command not sent');
    }
  }
}
