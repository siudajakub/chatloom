// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

class NewPassphraseView extends StatelessWidget {
  final BootstrapViewModel viewModel;

  const NewPassphraseView(this.viewModel, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCreatePassphrase =
        viewModel.value.newPassphraseEqualsRepeatPassphrase &&
        viewModel.value.newPassphraseNumbers &&
        viewModel.value.newPassphraseSpecialCharacters &&
        viewModel.value.newPassphraseUpperAndLowerCase &&
        viewModel.value.newPassphraseLongEnough;
    final setupError = viewModel.value.setupError;

    return NotionEntranceScope(
      child: ListView(
        padding: const EdgeInsets.all(16.0),
        children: NotionEntrance.stagger([
          const Text(
            'Choose a passphrase for your recovery key, or skip and keep '
            'only the recovery key.',
            textAlign: .center,
          ),
          const SizedBox(height: 16),
          TextField(
            obscureText: viewModel.value.obscureText,
            readOnly: viewModel.value.isLoading,
            controller: viewModel.newPassphraseController,
            decoration: InputDecoration(
              suffixIcon: IconButton(
                icon: Icon(
                  viewModel.value.obscureText
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: viewModel.toggleObscureText,
              ),
              hintText: L10n.of(context).newPassphrase,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            obscureText: viewModel.value.obscureText,
            readOnly: viewModel.value.isLoading,
            controller: viewModel.repeatPassphraseController,
            decoration: InputDecoration(
              hintText: L10n.of(context).repeatPassphrase,
            ),
          ),
          const SizedBox(height: 16),
          // One inline error with "Try again" (no dialog, no snackbar).
          NotionSizeReveal(
            visible: setupError != null,
            child: Padding(
              padding: const EdgeInsets.only(bottom: NotionSpace.md),
              child: NotionCallout(
                icon: Icons.error_outline,
                tone: NotionCalloutTone.danger,
                title: 'Couldn’t create your recovery key',
                message: setupError == null ? null : humanErrorText(setupError),
                actionLabel: L10n.of(context).tryAgain,
                actionBusy: viewModel.value.isLoading,
                onAction: viewModel.retrySetup,
              ),
            ),
          ),
          NotionButton.primary(
            expand: true,
            busy: viewModel.value.isLoading,
            label: L10n.of(context).continueText,
            onPressed: canCreatePassphrase
                ? () => viewModel.setOrSkipPassphrase(
                    viewModel.newPassphraseController.text,
                  )
                : null,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: viewModel.value.isLoading
                ? null
                : () => viewModel.setOrSkipPassphrase(null),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Skip the passphrase'),
          ),
          const SizedBox(height: 16),
          _PassphraseCheckListTile(
            checked: viewModel.value.newPassphraseEqualsRepeatPassphrase,
            label: L10n.of(context).passphrasesMatch,
          ),
          const SizedBox(height: 16),
          _PassphraseCheckListTile(
            checked: viewModel.value.newPassphraseLongEnough,
            label: L10n.of(context).passphraseLengthRequirement,
          ),
          const SizedBox(height: 16),
          _PassphraseCheckListTile(
            checked: viewModel.value.newPassphraseUpperAndLowerCase,
            label: L10n.of(context).passphraseUpperAndLowerCaseRequirement,
          ),
          const SizedBox(height: 16),
          _PassphraseCheckListTile(
            checked: viewModel.value.newPassphraseSpecialCharacters,
            label: L10n.of(context).passphraseSpecialCharactersRequirement,
          ),
          const SizedBox(height: 16),
          _PassphraseCheckListTile(
            checked: viewModel.value.newPassphraseNumbers,
            label: L10n.of(context).passphraseNumberRequirement,
          ),
        ]),
      ),
    );
  }
}

class _PassphraseCheckListTile extends StatelessWidget {
  final String label;
  final bool checked;
  const _PassphraseCheckListTile({required this.label, required this.checked});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return Row(
      spacing: NotionSpace.xs,
      children: [
        // A met requirement morphs its ring into a check.
        NotionMorphSwitcher(
          child: Icon(
            checked ? Icons.check_circle_outlined : Icons.circle_outlined,
            key: ValueKey(checked),
            color: checked ? colors.success : colors.danger,
            size: NotionSize.icon,
          ),
        ),
        Expanded(
          child: AnimatedDefaultTextStyle(
            duration: NotionMotion.quick,
            curve: NotionMotion.standard,
            style: context.notion.typography.footnote.copyWith(
              color: checked ? colors.text : colors.textSecondary,
            ),
            child: Text(label),
          ),
        ),
      ],
    );
  }
}
