// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/undecryptable_chat_hint.dart';
import 'package:chatloom/personal/encryption/e2ee_health.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// "Fix" from the chat header: why these messages are locked on this device
/// and the step that helps most (recovery key, verification or asking
/// again). Never resets keys; recovery opens the existing screens.
Future<void> showUndecryptableFixSheet(
  BuildContext context, {
  required Client client,
  required List<Event> events,
}) => showNotionSheet<void>(
  context: context,
  title: 'Messages couldn’t be decrypted',
  builder: (_) => _UndecryptableFixBody(client: client, events: events),
);

class _UndecryptableFixBody extends StatefulWidget {
  final Client client;
  final List<Event> events;
  const _UndecryptableFixBody({required this.client, required this.events});

  @override
  State<_UndecryptableFixBody> createState() => _UndecryptableFixBodyState();
}

class _UndecryptableFixBodyState extends State<_UndecryptableFixBody> {
  late final Future<E2eeSnapshot> _snapshot = E2eeSnapshot.load(widget.client);

  int get _count => widget.events.where(isUndecryptable).length;

  void _retry() {
    UndecryptableMessages.retryEach(widget.events);
    Navigator.of(context).pop();
  }

  void _open(E2eeFix fix) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    unawaited(router.push(e2eeFixRoute(fix)!));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${UndecryptableChatHint.label(_count)} on this device. Keys come '
            'from your key backup or from your other signed-in devices.',
            style: tokens.typography.calloutMuted,
          ),
          const SizedBox(height: NotionSpace.xs),
          FutureBuilder<E2eeSnapshot>(
            future: _snapshot,
            builder: (context, snapshot) {
              final state = snapshot.data;
              if (state == null) {
                return snapshot.hasError
                    ? _actions(null)
                    : const Padding(
                        padding: EdgeInsets.all(NotionSpace.md),
                        child: Center(child: NotionDelayedSpinner()),
                      );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NotionListRow(
                    leading: const Icon(Icons.backup_outlined),
                    title: 'Key backup',
                    subtitle: !state.encryptionAvailable
                        ? 'Encryption is off on this device'
                        : !state.backupEnabled
                        ? 'Not set up'
                        : state.backupConnected
                        ? 'Connected on this device'
                        : 'Not connected on this device',
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: 'This session',
                    subtitle: state.sessionVerified
                        ? 'Verified'
                        : 'Not verified, so other devices won’t share keys',
                  ),
                  _actions(recoveryFixFor(state)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _actions(E2eeFix? fix) {
    final retry = NotionButton(
      label: 'Try again',
      icon: Icons.refresh,
      onPressed: _retry,
      expand: true,
      variant: fix == null
          ? NotionButtonVariant.primary
          : NotionButtonVariant.ghost,
    );
    return Padding(
      padding: const EdgeInsets.only(top: NotionSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: NotionSpace.xs,
        children: [
          if (fix != null)
            NotionButton.primary(
              label: switch (fix) {
                E2eeFix.connectRecovery => 'Enter recovery key',
                E2eeFix.openDevices => 'Verify this session',
                _ => 'Encryption & recovery',
              },
              onPressed: () => _open(fix),
              expand: true,
            ),
          retry,
          if (fix == null)
            NotionButton.ghost(
              label: 'Encryption & recovery',
              onPressed: () => _open(E2eeFix.openRecoverySettings),
              expand: true,
            ),
        ],
      ),
    );
  }
}
