// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:chatloom/pages/bootstrap/widgets/new_passphrase_view.dart';
import 'package:chatloom/pages/bootstrap/widgets/restore_bootstrap_view.dart';
import 'package:chatloom/pages/bootstrap/widgets/store_recovery_key_view.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/view_model_builder.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

class BootstrapPage extends StatelessWidget {
  final bool reset;
  const BootstrapPage({required this.reset, super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder(
      create: () =>
          BootstrapViewModel(client: Matrix.of(context).client, reset: reset),
      builder: (context, viewModel, _) {
        final cryptoIdentityState = viewModel.value.cryptoIdentityState;
        if (cryptoIdentityState?.connected == true && !reset) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => viewModel.goToRoomsPageAfterSuccess(context),
          );
        }

        // One vocabulary: "recovery key" for the key, "key backup" for the
        // server backup.
        final title = cryptoIdentityState == null
            ? viewModel.value.loadFailed
                  ? 'Recovery key'
                  : L10n.of(context).loadingPleaseWait
            : viewModel.value.recoveryKey != null
            ? 'Save your recovery key'
            : cryptoIdentityState.initialized && !viewModel.value.reset
            ? 'Enter your recovery key'
            : viewModel.value.reset
            ? 'Reset recovery key'
            : 'Set up a recovery key';

        return LoginScaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: viewModel.value.recoveryKey != null
                ? null
                : CloseButton(
                    onPressed: () async {
                      if (!reset) {
                        final consent = await showOkCancelAlertDialog(
                          context: context,
                          title: 'Skip the recovery key?',
                          message:
                              'Without a recovery key you can lose access to '
                              'your encrypted messages when you change '
                              'devices. You can set it up later in Settings.',
                          okLabel: L10n.of(context).skip,
                          isDestructive: true,
                        );
                        if (consent != OkCancelResult.ok) return;
                        if (!context.mounted) return;
                      }
                      context.go('/rooms');
                    },
                  ),
            title: NotionFadeThrough(
              alignment: AlignmentDirectional.centerStart,
              child: Text(title, key: ValueKey(title)),
            ),
            actions: [
              if (viewModel.value.recoveryKey != null)
                Padding(
                  padding: const EdgeInsets.all(NotionSpace.xs),
                  child: NotionPop(
                    bounce: false,
                    child: NotionButton.primary(
                      label: L10n.of(context).continueText,
                      onPressed: () => context.go('/rooms'),
                    ),
                  ),
                ),
            ],
          ),

          // Each step (loading, new passphrase, recovery key, restore)
          // fades through to the next.
          body: NotionFadeThrough(
            child: cryptoIdentityState == null
                ? viewModel.value.loadFailed
                      ? NotionEmptyState(
                          key: const ValueKey('load-failed'),
                          icon: Icons.cloud_off_outlined,
                          title: 'Couldn’t check your recovery key',
                          message: 'Check your connection and try again.',
                          action: NotionButton(
                            label: L10n.of(context).tryAgain,
                            onPressed: viewModel.retryLoad,
                          ),
                        )
                      : const Center(
                          key: ValueKey('loading'),
                          child: NotionDelayedSpinner(
                            size: NotionSize.touchTarget,
                          ),
                        )
                : !cryptoIdentityState.initialized || viewModel.value.reset
                ? viewModel.value.recoveryKey == null
                      ? NewPassphraseView(
                          viewModel,
                          key: const ValueKey('passphrase'),
                        )
                      : StoreRecoveryKeyView(
                          viewModel,
                          key: const ValueKey('store'),
                        )
                : RestoreBootstrapView(
                    viewModel,
                    key: const ValueKey('restore'),
                  ),
          ),
        );
      },
    );
  }
}
