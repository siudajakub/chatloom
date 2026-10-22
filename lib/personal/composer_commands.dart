// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// The slash commands ChatLoom's composer still runs itself: formatting only.
///
/// The SDK registers every FluffyChat command on each client (`/logout`,
/// `/leave`, `/clearcache`, `/discardsession`, `/ban`, `/kick`, `/join`,
/// `/dm`, `/roomupgrade`, …). Typed into a chat they ran at once, without a
/// confirmation: `/logout` signed the device out and wiped its keys even
/// offline. Telegram and Messenger have no such commands in the message
/// field; a `/word` there is text (a bot command such as `/start`). So every
/// other command is removed at client creation ([restrictComposerCommands])
/// and is sent to the chat as typed. Sign-out, leaving a chat and clearing
/// the cache remain in their screens, behind their own confirmations.
const composerCommands = {'send', 'me', 'plain', 'html'};

/// Removes every command but [composerCommands] from [client] (foreground
/// and notification-action clients alike), so no code path that parses
/// commands (`Room.sendTextEvent` parses by default) can run one.
void restrictComposerCommands(Client client) =>
    client.commands.removeWhere((name, _) => !composerCommands.contains(name));

/// The composer command [text] invokes (`/me waves` → `me`), or null when
/// [text] is a message: plain text, or any other `/word`, which is sent as
/// text. Mirrors the SDK's parsing (the name ends at the first space), so a
/// recognised command never reaches the SDK in a form it would drop.
String? composerCommandOf(Client client, String text) {
  final name = RegExp(r'^/(\w+)(?: |$)').firstMatch(text)?[1]?.toLowerCase();
  if (name == null ||
      !composerCommands.contains(name) ||
      !client.commands.containsKey(name)) {
    return null;
  }
  return name;
}
