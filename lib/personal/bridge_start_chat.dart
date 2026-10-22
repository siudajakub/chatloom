// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Asks before a bridge creates a chat: starting one is never a side effect
/// of searching or of a single stray tap.
Future<bool> confirmBridgedChat(
  BuildContext context, {
  required String name,
  required String network,
}) => showNotionConfirmDialog(
  context: context,
  title: 'Start a $network chat with $name?',
  message: 'ChatLoom asks your $network bridge to open the chat.',
  confirmLabel: 'Start chat',
);

/// The room [roomId] once the account has it (joined or invited); waits for
/// sync up to [timeout]. An invite is returned as is: opening it joins it
/// like any other invite in the inbox.
Future<Room> waitForBridgedChat(
  Client client,
  String roomId, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  Room? usable() {
    final room = client.getRoomById(roomId);
    return room != null &&
            (room.membership == Membership.join ||
                room.membership == Membership.invite)
        ? room
        : null;
  }

  final known = usable();
  if (known != null) return known;
  final arrived = Completer<void>();
  void check(_) {
    if (!arrived.isCompleted && usable() != null) arrived.complete();
  }

  // Listen before checking again, so a sync in between is not missed; the
  // room list is complete once the sync status reports the sync processed.
  final subscriptions = [
    client.onSync.stream.listen(check, onError: (_) {}),
    client.onSyncStatus.stream.listen(check, onError: (_) {}),
  ];
  try {
    check(null);
    await arrived.future.timeout(timeout);
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
  return usable()!;
}

/// Creates the DM with [identifier] on [bridge] and returns its room. Call
/// only after [confirmBridgedChat]; throws [BridgeProvisioningException] or
/// [TimeoutException].
Future<Room> startBridgedChat({
  required BridgeDirectory directory,
  required BridgeEndpoint bridge,
  required String identifier,
  required Client client,
  String? loginId,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final api = directory.api;
  if (api == null) {
    throw BridgeProvisioningException(0, message: directory.disabledReason);
  }
  final contact = await api.createDm(bridge, identifier, loginId: loginId);
  return waitForBridgedChat(client, contact.dmRoomId!, timeout: timeout);
}

/// A short, human reason for a failed start (no ids, no URLs, no bridge
/// jargon): bridge texts go through [humanErrorText], which keeps a
/// network's own sentences ("Phone number is not on WhatsApp.") and rewords
/// bridgev2's technical ones.
String bridgedChatError(Object error, String network) => switch (error) {
  TimeoutException() =>
    'The $network bridge didn’t open the chat in time. It may still appear '
        'in your inbox.',
  BridgeProvisioningException(:final message, unreachable: true)
      when bridgeMessageText(message, network: network) == null =>
    'ChatLoom can’t reach your $network bridge.',
  _ => humanErrorText(error, network: network),
};
