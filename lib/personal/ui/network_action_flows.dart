// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The confirm-and-run flows of the network chat actions (FX-01, FX-02):
/// Delete chat and Block act on the user's real network account and cannot
/// be taken back from here, so each asks once in plain words; Unblock and
/// Accept are reversible or harmless and run at once. The action itself runs
/// in the background (the inbox row disappears at once for a delete); only
/// the network's answer is shown, in a snackbar.

String _network(Room room) => bridgedNetworkLabel(room) ?? 'the network';

/// The question and the optional checkbox of a network action.
class NetworkActionDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String? optionLabel;
  const NetworkActionDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.optionLabel,
  });

  @override
  State<NetworkActionDialog> createState() => _NetworkActionDialogState();
}

class _NetworkActionDialogState extends State<NetworkActionDialog> {
  bool _option = false;

  @override
  Widget build(BuildContext context) {
    final option = widget.optionLabel;
    return NotionDialog(
      title: widget.title,
      message: widget.message,
      content: option == null
          ? null
          : CheckboxListTile(
              key: const ValueKey('network-action-option'),
              value: _option,
              onChanged: (value) => setState(() => _option = value ?? false),
              title: Text(option, style: context.notion.typography.callout),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              shape: NotionShapes.row,
            ),
      actions: [
        NotionButton.ghost(
          label: MaterialLocalizations.of(context).cancelButtonLabel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        NotionButton.destructive(
          key: const ValueKey('network-action-confirm'),
          label: widget.confirmLabel,
          onPressed: () => Navigator.of(context).pop(_option),
        ),
      ],
    );
  }
}

/// Null when cancelled, else whether the option was ticked.
Future<bool?> _ask(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? optionLabel,
}) => showNotionCustomDialog<bool>(
  context: context,
  builder: (_) => NetworkActionDialog(
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    optionLabel: optionLabel,
  ),
);

/// The words of the delete question for [room] (public for tests).
({String title, String message, String? option}) deleteChatQuestion(
  Room room, {
  required String name,
  bool fromRequest = false,
}) {
  final network = _network(room);
  final features = NetworkChatFeatures.of(room);
  final group = !room.isDirectChatForDisplay;
  if (fromRequest) {
    return (
      title: 'Delete this request?',
      message:
          'The request from $name is removed from $network. $name isn’t '
          'told. This can’t be undone.',
      option: null,
    );
  }
  return (
    title: group ? 'Delete $name?' : 'Delete chat with $name?',
    message: group
        ? 'You leave the group and its messages are deleted from your '
              '$network account on all your devices. This can’t be undone.'
        : 'The chat and its messages are deleted from your $network '
              'account on all your devices. This can’t be undone.',
    option: !features.deleteChatForEveryone
        ? null
        : group
        ? 'Also delete it for all members'
        : 'Also delete it for $name',
  );
}

/// Delete chat on the network (with "also for Anna" where the bridge
/// declares it). [onStarted] runs right after the confirmation, e.g. to
/// leave the chat's page.
Future<void> deleteNetworkChatFlow(
  BuildContext context,
  Room room, {
  required String name,
  bool fromRequest = false,
  VoidCallback? onStarted,
}) async {
  final question = deleteChatQuestion(
    room,
    name: name,
    fromRequest: fromRequest,
  );
  final forEveryone = await _ask(
    context,
    title: question.title,
    message: question.message,
    confirmLabel: 'Delete',
    optionLabel: question.option,
  );
  if (forEveryone == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final network = _network(room);
  onStarted?.call();
  final result = await NetworkChatActions.deleteChat(
    room,
    forEveryone: forEveryone,
    fromMessageRequest: fromRequest,
  );
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          result.done
              ? 'Chat deleted on $network'
              : result.text ?? 'Couldn’t delete the chat. Try again.',
        ),
      ),
    );
}

/// Block (asked once, with "Also report spam" where declared) or unblock
/// (at once) the other person of a bridged DM on the network.
Future<void> blockNetworkUserFlow(
  BuildContext context,
  Room room, {
  required String name,
  required bool block,
}) async {
  final network = _network(room);
  var reportSpam = false;
  if (block) {
    final features = NetworkChatFeatures.of(room);
    final answer = await _ask(
      context,
      title: 'Block $name on $network?',
      message:
          '$name won’t be able to message or call you on $network. The chat '
          'stays in ChatLoom, and you can unblock them later.',
      confirmLabel: 'Block',
      optionLabel: features.reportSpam ? 'Also report spam' : null,
    );
    if (answer == null || !context.mounted) return;
    reportSpam = answer;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await NetworkChatActions.setBlocked(
    room,
    block: block,
    reportSpam: reportSpam,
  );
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          result.done
              ? block
                    ? '$name is blocked on $network'
                    : '$name is unblocked on $network'
              : result.text ?? 'Couldn’t change the block. Try again.',
        ),
      ),
    );
}

/// Accepts a message request; only a refusal is reported.
Future<bool> acceptMessageRequestFlow(BuildContext context, Room room) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await NetworkChatActions.acceptRequest(room);
  if (result.done) return true;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(result.text ?? 'Couldn’t accept the request. Try again.'),
      ),
    );
  return false;
}
