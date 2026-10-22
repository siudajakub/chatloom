// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:chatloom/pages/key_verification/key_verification_dialog.dart';
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/device_extension.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';

class RestoreBootstrapView extends StatelessWidget {
  final BootstrapViewModel viewModel;

  const RestoreBootstrapView(this.viewModel, {super.key});

  /// "Try again" for verification with another device; a request that
  /// cannot be sent is explained instead of doing nothing.
  Future<void> _retryVerification(BuildContext context) async {
    try {
      await viewModel.retryKeyVerification();
    } catch (error, stack) {
      if (!context.mounted) return;
      await ErrorReporter.action(
        context,
        onRetry: () => _retryVerification(context),
      ).onErrorCallback(error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyVerification = viewModel.value.keyVerification;
    if (keyVerification != null) {
      Logs().v('Key verification state:', keyVerification.state);
      if (keyVerification.state == KeyVerificationState.askSas) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          KeyVerificationDialog(request: keyVerification).show(context);
        });
      }
    }
    final devices =
        viewModel.value.connectedDevices
            ?.map(
              (device) => (
                title: device.displayname,
                lastActive: device.lastActive,
                icon: device.icon,
              ),
            )
            .toList() ??
        [];
    final stalled =
        keyVerification != null &&
        (keyVerification.state == KeyVerificationState.error ||
            viewModel.value.noSecretsreceived);
    final status = viewModel.value.waitingForSecrets
        ? L10n.of(context).waitingForKeys
        : viewModel.value.noSecretsreceived
        ? L10n.of(context).noKeysTransmitted
        : 'Verification is requested automatically. Accept it in your existing client or use your existing recovery key. The list below shows your devices; it does not select one.';
    return NotionEntranceScope(
      child: ListView(
        padding: const EdgeInsets.all(16.0),
        children: NotionEntrance.stagger([
          if (keyVerification != null) ...[
            ListTile(
              // Waiting ↔ retry morph in place.
              leading: NotionMorphSwitcher(
                rotate: false,
                child: stalled
                    ? IconButton(
                        key: const ValueKey('retry'),
                        onPressed: viewModel.value.isLoading
                            ? null
                            : () => _retryVerification(context),
                        tooltip: L10n.of(context).tryAgain,
                        icon: Icon(Icons.refresh_outlined),
                      )
                    : const SizedBox.square(
                        key: ValueKey('waiting'),
                        dimension: NotionSize.touchTarget,
                        child: Center(child: NotionDelayedSpinner()),
                      ),
              ),
              minLeadingWidth: 40,
              title: NotionFadeThrough(
                child: Text(
                  status,
                  key: ValueKey(status),
                  style: context.notion.typography.callout,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Material(
              color: theme.colorScheme.surfaceContainer,
              clipBehavior: Clip.hardEdge,
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 128),
                child: Scrollbar(
                  thumbVisibility: true,
                  trackVisibility: true,
                  controller: viewModel.devicesScrollController,
                  child: ListView.builder(
                    controller: viewModel.devicesScrollController,
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (context, i) => ListTile(
                      leading: CircleAvatar(
                        foregroundColor: theme.colorScheme.onPrimary,
                        backgroundColor: theme.colorScheme.primary,
                        child: Icon(devices[i].icon),
                      ),
                      title: Text(
                        devices[i].title,
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        L10n.of(context).lastActiveAgo(
                          devices[i].lastActive.localizedTime(context),
                        ),
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(child: Divider(height: 64)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(L10n.of(context).or),
                ),
                Expanded(child: Divider(height: 64)),
              ],
            ),
          ] else ...[
            const Text(
              'Enter your recovery key (or its passphrase) to verify this '
              'device and unlock your message history.',
              textAlign: .center,
            ),
            const SizedBox(height: 32),
          ],
          ErrorShake(
            error: viewModel.value.unlockWithError,
            child: TextField(
              readOnly: viewModel.value.isLoading,
              obscureText: viewModel.value.obscureText,
              controller: viewModel.enterPassphraseOrRecovController,
              minLines: 1,
              maxLines: viewModel.value.obscureText ? 1 : 4,
              onSubmitted: (_) => viewModel.unlock(),
              decoration: InputDecoration(
                hintText: 'Recovery key or passphrase',
                prefixIcon: IconButton(
                  icon: Icon(
                    viewModel.value.obscureText
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: viewModel.toggleObscureText,
                ),
                errorText: viewModel.unlockErrorText,
                errorMaxLines: 4,
                suffixIcon: NotionMorphSwitcher(
                  rotate: false,
                  child: viewModel.value.isLoading
                      ? const SizedBox.square(
                          key: ValueKey('busy'),
                          dimension: NotionSize.touchTarget,
                          child: Center(child: NotionDelayedSpinner()),
                        )
                      : TextButton(
                          key: ValueKey(
                            viewModel.value.passphraseOrRecoveryKeyEntered,
                          ),
                          style: TextButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius / 2,
                              ),
                            ),
                          ),
                          onPressed:
                              viewModel.value.passphraseOrRecoveryKeyEntered
                              ? viewModel.unlock
                              : () => viewModel.openRecoveryKeyFile(context),
                          child: Text(
                            !viewModel.value.passphraseOrRecoveryKeyEntered
                                ? L10n.of(context).openFile
                                // Offline or a server error: the key was
                                // not checked, so the same key is retried.
                                : viewModel.value.unlockFailure != null &&
                                      viewModel.value.unlockFailure !=
                                          RecoveryUnlockFailure.wrongKey
                                ? L10n.of(context).tryAgain
                                : L10n.of(context).unlock,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // The last resort, guarded: a new recovery key replaces the
          // lost one (the bootstrap reset flow, unchanged).
          TextButton(
            onPressed: () async {
              final consent = await showOkCancelAlertDialog(
                context: context,
                title: 'Reset your recovery key?',
                message:
                    'Only do this if you lost your recovery key and have no '
                    'other signed-in device to verify with. Messages that '
                    'only the old key can unlock stay unreadable, and your '
                    'other devices need to be verified again.',
                isDestructive: true,
                okLabel: 'Reset recovery key',
              );
              if (consent != OkCancelResult.ok) return;
              if (!context.mounted) return;
              viewModel.startResetAccount();
            },
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Lost your recovery key?'),
          ),
        ]),
      ),
    );
  }
}
