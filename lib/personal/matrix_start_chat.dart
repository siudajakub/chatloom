// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_start_chat.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The Matrix user a search query names exactly: a full id
/// (`@anna:beeper.com`) or a bare `@anna` on the account's own server.
/// Null for anything else and for the account itself. Matrix is never
/// searched; this only reads the typed text.
String? matrixIdFromQuery(String query, {required String? ownUserId}) {
  final text = query.trim();
  if (!text.startsWith('@') || text.contains(RegExp(r'\s'))) return null;
  final String id;
  if (text.contains(':')) {
    id = text;
  } else {
    final domain = ownUserId?.domain;
    if (domain == null || text.length < 2) return null;
    // Localparts are lower case; a typed `@Anna` means `@anna`.
    id = '${text.toLowerCase()}:$domain';
  }
  final valid = id.isValidMatrixIdStrict() && id.sigil == '@';
  return valid && id != ownUserId ? id : null;
}

/// The display name [userId] gives on their profile, or null without one.
/// Asks the account's own server (which asks theirs for a remote user);
/// throws [MatrixException] `M_NOT_FOUND` for an unknown user.
Future<String?> matrixProfileName(Client client, String userId) async {
  final profile = await client.getUserProfile(
    userId,
    timeout: const Duration(seconds: 20),
    maxCacheAge: Duration.zero,
  );
  final name = profile.displayname?.trim();
  return name == null || name.isEmpty ? null : name;
}

/// Asks before a Matrix chat is created: the other person gets an invite.
Future<bool> confirmMatrixChat(
  BuildContext context, {
  required String userId,
  String? name,
}) => showNotionConfirmDialog(
  context: context,
  title: 'Start a Matrix chat with ${name ?? userId}?',
  message:
      'ChatLoom creates a private chat and invites $userId. They accept it '
      'in Beeper or another Matrix app.',
  confirmLabel: 'Start chat',
);

/// The direct chat with [userId]: the existing one, or a new private chat
/// with an invite. Call only after [confirmMatrixChat].
Future<Room> startMatrixChat(Client client, String userId) async {
  final roomId = await client.startDirectChat(userId);
  return waitForBridgedChat(client, roomId);
}

/// A short reason for a failed lookup or start.
String matrixChatError(Object error, String userId) => switch (error) {
  MatrixException(errcode: 'M_NOT_FOUND') => 'No Matrix account $userId.',
  TimeoutException() =>
    'Your server didn’t answer in time. The chat may still appear in your '
        'inbox.',
  _ => humanErrorText(error),
};
