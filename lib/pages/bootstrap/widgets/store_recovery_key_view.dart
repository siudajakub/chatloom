// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Shows the new recovery key once, with a copy button and the ways to keep
/// it (file, system keystore).
///
/// Copy puts the key on the clipboard only; it never opens the share sheet,
/// where one tap could hand the key to any app (FX-15). The button turns
/// into a check and, below Android 13 (which shows its own clipboard
/// overlay), a "Recovery key copied" snackbar confirms it. The clipboard is
/// not cleared automatically: Flutter's clipboard API cannot mark the clip
/// sensitive (Android's `EXTRA_IS_SENSITIVE`), and reading it back to clear
/// it would raise Android's paste notice or wipe something copied later.
class StoreRecoveryKeyView extends StatelessWidget {
  final BootstrapViewModel viewModel;
  const StoreRecoveryKeyView(this.viewModel, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NotionSpace.md),
      children: NotionEntrance.stagger([
        Text(
          L10n.of(context).storeRecoveryKeyDescription,
          style: context.notion.typography.callout,
        ),
        const SizedBox(height: NotionSpace.md),
        RecoveryKeyField(recoveryKey: viewModel.value.recoveryKey ?? ''),
        const SizedBox(height: NotionSpace.md),
        CheckboxListTile.adaptive(
          value: viewModel.value.recoveryKeyDownloaded,
          onChanged: (copied) =>
              viewModel.toggleRecoveryKeyDownloaded(copied, context),
          title: Text(L10n.of(context).saveAsFile),
        ),
        if (viewModel.supportsSecureStorage)
          CheckboxListTile.adaptive(
            value: viewModel.value.recoveryKeyStoredInSecureStorage,
            onChanged: viewModel.toggleRecoveryKeyStoredInSecureStorage,
            title: Text(_getSecureStorageLocalizedName(context)),
          ),
      ]),
    );
  }

  String _getSecureStorageLocalizedName(BuildContext context) {
    if (PlatformInfos.isAndroid) {
      return L10n.of(context).storeInAndroidKeystore;
    }
    if (PlatformInfos.isIOS || PlatformInfos.isMacOS) {
      return L10n.of(context).storeInAppleKeyChain;
    }
    return L10n.of(context).storeSecurlyOnThisDevice;
  }
}

/// The new recovery key, selectable, with a copy button that turns into a
/// check once the key is on the clipboard.
class RecoveryKeyField extends StatefulWidget {
  final String recoveryKey;
  const RecoveryKeyField({super.key, required this.recoveryKey});

  @override
  State<RecoveryKeyField> createState() => _RecoveryKeyFieldState();
}

class _RecoveryKeyFieldState extends State<RecoveryKeyField> {
  bool _copied = false;

  Future<void> _copy() async {
    if (widget.recoveryKey.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: widget.recoveryKey));
    if (!mounted) return;
    setState(() => _copied = true);
    await showCopiedNotice(context, 'Recovery key copied');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.colors.surface,
        borderRadius: NotionRadius.mdAll,
        border: Border.all(color: tokens.colors.border),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: NotionSpace.md,
          top: NotionSpace.xxs,
          bottom: NotionSpace.xxs,
          end: NotionSpace.xxs,
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                widget.recoveryKey,
                style: tokens.typography.bodyStrong,
              ),
            ),
            NotionMorphSwitcher(
              rotate: false,
              child: NotionIconButton(
                key: ValueKey(_copied),
                icon: _copied ? Icons.check : Icons.copy_outlined,
                label: _copied ? 'Recovery key copied' : 'Copy recovery key',
                onPressed: _copy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
