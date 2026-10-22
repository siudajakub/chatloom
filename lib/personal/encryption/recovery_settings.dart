// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

// Recovery wording, one glossary everywhere: "recovery key" is the key the
// person saves (or its passphrase), "key backup" is the encrypted copy of
// message keys on the server. Never "chat backup", "online key backup" or
// "crypto identity".

/// What Settings knows about recovery on this device.
enum RecoveryStatus {
  /// The check has not finished or could not reach the server.
  unknown,

  /// No recovery key exists for the account.
  notSetUp,

  /// The account has a recovery key, but this device does not hold it.
  notConnected,

  /// Key backup is on and this device is connected to it.
  connected,
}

/// [connected] is the SDK's `initialized && connected`; [initialized] is
/// null when only that combined value is known.
RecoveryStatus recoveryStatusOf({bool? connected, bool? initialized}) {
  if (connected == null) return RecoveryStatus.unknown;
  if (connected) return RecoveryStatus.connected;
  return initialized == true
      ? RecoveryStatus.notConnected
      : RecoveryStatus.notSetUp;
}

/// Settings › Encryption & recovery: the status, then only the actions that
/// make sense for it. Reset is the last, red, and confirmed (see
/// [confirmRecoveryReset]).
class RecoverySettingsBody extends StatelessWidget {
  const RecoverySettingsBody({
    super.key,
    required this.status,
    required this.onCheck,
    required this.onOpenRecovery,
    required this.onVerify,
    required this.onReset,
  });

  final RecoveryStatus status;
  final VoidCallback onCheck;

  /// The recovery key page (`/backup`): set up, or connect this device.
  final VoidCallback onOpenRecovery;
  final VoidCallback onVerify;
  final VoidCallback onReset;

  static const title = 'Encryption & recovery';

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final summary = switch (status) {
      RecoveryStatus.connected =>
        'On. Your recovery key restores your messages on a new device.',
      RecoveryStatus.notConnected =>
        'Your account has a recovery key, but this device isn’t connected '
            'to key backup yet.',
      RecoveryStatus.notSetUp =>
        'Off. Set up a recovery key so you can restore your messages on a '
            'new device.',
      RecoveryStatus.unknown =>
        'Couldn’t check key backup yet. Try again when you’re online.',
    };
    return NotionSettingsScaffold(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionListRow(
            leading: Icon(
              status == RecoveryStatus.connected
                  ? Icons.cloud_done_outlined
                  : Icons.backup_outlined,
            ),
            title: 'Key backup',
            subtitle: summary,
          ),
          NotionSizeReveal(
            visible: status == RecoveryStatus.unknown,
            child: NotionListRow(
              leading: const Icon(Icons.refresh_outlined),
              title: 'Check again',
              onTap: onCheck,
            ),
          ),
          const NotionSettingsSection('Recovery key'),
          if (status == RecoveryStatus.connected) ...[
            NotionListRow(
              leading: const Icon(Icons.key_outlined),
              title: 'Verify recovery key',
              subtitle: 'Check that the key you saved still works',
              onTap: onVerify,
            ),
            NotionListRow(
              leading: Icon(Icons.restart_alt_outlined, color: colors.danger),
              title: 'Reset recovery key…',
              subtitle: 'Only if you lost it. Your old key stops working.',
              onTap: onReset,
            ),
          ] else
            NotionListRow(
              leading: const Icon(Icons.key_outlined),
              title: switch (status) {
                RecoveryStatus.notConnected => 'Enter recovery key',
                RecoveryStatus.notSetUp => 'Set up recovery key',
                _ => 'Open recovery key',
              },
              subtitle: switch (status) {
                RecoveryStatus.notConnected =>
                  'Connect this device and unlock older messages',
                RecoveryStatus.notSetUp =>
                  'Create a key and save it somewhere safe',
                _ => 'Set up or enter your recovery key',
              },
              onTap: onOpenRecovery,
            ),
        ],
      ),
    );
  }
}

/// Reset is destructive: the old recovery key stops working and other
/// devices need to be verified again. The reset itself still happens on the
/// recovery key page, which asks for a new passphrase and shows the new key.
Future<bool> confirmRecoveryReset(BuildContext context) =>
    showNotionConfirmDialog(
      context: context,
      title: 'Reset your recovery key?',
      message:
          'Your current recovery key stops working, and your other devices '
          'need to be verified again. The message keys on this device are '
          'copied into the new key backup. Only do this if you lost your '
          'recovery key.',
      confirmLabel: 'Reset recovery key',
      destructive: true,
    );

/// Recovery state at the moment someone logs out.
enum LogoutRecovery {
  /// Encryption is off: there is nothing to lose.
  noEncryption,
  connected,
  notConnected,
  unknown,
}

enum LogoutChoice { cancel, logOut, setUpRecovery }

/// Telegram/Messenger "Log out?", with the key backup warning only when it
/// is true: a connected recovery key restores the history after signing in
/// again, so it is not threatened with loss.
Future<LogoutChoice> showLogoutConfirmDialog(
  BuildContext context,
  LogoutRecovery recovery,
) async {
  final warn =
      recovery == LogoutRecovery.notConnected ||
      recovery == LogoutRecovery.unknown;
  final message = switch (recovery) {
    LogoutRecovery.connected =>
      'You can sign in again with your Beeper account. Your recovery key '
          'restores your message history.',
    LogoutRecovery.noEncryption =>
      'You can sign in again with your Beeper account.',
    LogoutRecovery.notConnected =>
      'This device isn’t connected to key backup. Encrypted messages that '
          'only this device can read will be lost when you log out. Set up '
          'your recovery key first to keep them.',
    LogoutRecovery.unknown =>
      'ChatLoom couldn’t check your key backup. If you haven’t saved your '
          'recovery key, you can lose access to encrypted messages when you '
          'log out.',
  };
  final choice = await showNotionCustomDialog<LogoutChoice>(
    context: context,
    useRootNavigator: false,
    builder: (context) => NotionDialog(
      title: warn ? 'Log out without a recovery key?' : 'Log out?',
      message: message,
      actions: [
        NotionButton.ghost(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(LogoutChoice.cancel),
        ),
        NotionButton.destructive(
          label: warn ? 'Log out anyway' : 'Log out',
          onPressed: () => Navigator.of(context).pop(LogoutChoice.logOut),
        ),
        if (warn)
          NotionButton.primary(
            label: 'Set up recovery',
            onPressed: () =>
                Navigator.of(context).pop(LogoutChoice.setUpRecovery),
          ),
      ],
    ),
  );
  return choice ?? LogoutChoice.cancel;
}

/// Checks a recovery key or passphrase against the account's key without
/// changing anything; [check] returns null when it matches.
Future<void> showVerifyRecoveryKeyDialog(
  BuildContext context, {
  required Future<RecoveryUnlockFailure?> Function(String keyOrPassphrase)
  check,
}) => showNotionCustomDialog<void>(
  context: context,
  useRootNavigator: false,
  builder: (context) => _VerifyRecoveryKeyDialog(check: check),
);

class _VerifyRecoveryKeyDialog extends StatefulWidget {
  const _VerifyRecoveryKeyDialog({required this.check});
  final Future<RecoveryUnlockFailure?> Function(String) check;

  @override
  State<_VerifyRecoveryKeyDialog> createState() =>
      _VerifyRecoveryKeyDialogState();
}

class _VerifyRecoveryKeyDialogState extends State<_VerifyRecoveryKeyDialog> {
  final _input = TextEditingController();
  bool _busy = false;
  bool _verified = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final key = _input.text.trim();
    if (key.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _verified = false;
    });
    RecoveryUnlockFailure? failure;
    try {
      failure = await widget.check(key);
    } catch (error) {
      failure = classifyRecoveryUnlockError(error);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _verified = failure == null;
      _error = switch (failure) {
        null => null,
        RecoveryUnlockFailure.wrongKey =>
          'This isn’t the recovery key for your account.',
        RecoveryUnlockFailure.offline =>
          'No connection. Try again when you’re online.',
        RecoveryUnlockFailure.other => 'Couldn’t check the key. Try again.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    return NotionDialog(
      title: 'Verify your recovery key',
      message:
          'Enter the recovery key or passphrase you saved. Nothing changes '
          'on your account.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionTextField(
            controller: _input,
            hint: 'Recovery key or passphrase',
            obscureText: true,
            autofocus: true,
            readOnly: _busy,
            error: _error,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _check(),
          ),
          NotionSizeReveal(
            visible: _verified,
            child: Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: Text(
                'This recovery key works. Keep it somewhere safe.',
                style: typography.footnote.copyWith(
                  color: context.notion.colors.success,
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        NotionButton.ghost(
          label: _verified ? 'Done' : 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (!_verified)
          NotionButton.primary(label: 'Check', busy: _busy, onPressed: _check),
      ],
    );
  }
}
