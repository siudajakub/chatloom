// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:fluffychat/pages/bootstrap/widgets/new_passphrase_view.dart';
import 'package:fluffychat/pages/bootstrap/widgets/restore_bootstrap_view.dart';
import 'package:fluffychat/pages/bootstrap/widgets/store_recovery_key_view.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/layouts/login_scaffold.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/view_model_builder.dart';
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

        final title = cryptoIdentityState == null
            ? L10n.of(context).loadingPleaseWait
            : cryptoIdentityState.initialized && !viewModel.value.reset
            ? L10n.of(context).restoreCryptoIdentity
            : viewModel.value.reset
            ? viewModel.value.recoveryKey != null
                  ? L10n.of(context).youAreReadyToStart
                  : L10n.of(context).resetCryptoIdentity
            : L10n.of(context).setUpCryptoIdentity;

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
                          title: L10n.of(context).skipChatBackup,
                          message: L10n.of(context).skipChatBackupWarning,
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
                ? const Center(
                    key: ValueKey('loading'),
                    child: NotionDelayedSpinner(size: NotionSize.touchTarget),
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
