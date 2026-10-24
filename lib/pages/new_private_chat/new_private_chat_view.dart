// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/new_private_chat/new_private_chat.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../widgets/qr_code_viewer.dart';

class NewPrivateChatView extends StatelessWidget {
  final NewPrivateChatController controller;

  const NewPrivateChatView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final searchResponse = controller.searchResponse;
    final userId = Matrix.of(context).client.userID!;
    return NotionScaffold(
      title: l10n.newChat,
      onBack: () => Navigator.of(context).maybePop(),
      children: [
        NotionTextField(
          controller: controller.controller,
          onChanged: controller.searchUsers,
          hint: l10n.searchForUsers,
          prefixIcon: Icons.search_outlined,
          // Spinner while a lookup runs, clear once there is text.
          suffix: FutureBuilder(
            future: searchResponse,
            builder: (context, snapshot) => NotionMorphSwitcher(
              rotate: false,
              child:
                  searchResponse != null &&
                      snapshot.connectionState != ConnectionState.done
                  ? const SizedBox.square(
                      key: ValueKey('busy'),
                      dimension: NotionSize.touchTarget,
                      child: Center(child: NotionDelayedSpinner()),
                    )
                  : controller.controller.text.isNotEmpty
                  ? IconButton(
                      key: const ValueKey('clear'),
                      tooltip: l10n.clear,
                      icon: const Icon(Icons.clear_outlined),
                      onPressed: () {
                        controller.controller.clear();
                        controller.searchUsers();
                      },
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
          ),
        ),
        const SizedBox(height: NotionSpace.sm),
        // Start page ↔ results fade through; each result set too.
        NotionFadeThrough(
          child: searchResponse == null
              ? Column(
                  key: const ValueKey('start'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: NotionEntrance.stagger([
                    NotionListRow(
                      leading: Icon(
                        Icons.adaptive.share_outlined,
                        size: NotionSize.iconMd,
                      ),
                      title: l10n.shareInviteLink,
                      onTap: controller.inviteAction,
                    ),
                    NotionListRow(
                      leading: const Icon(
                        Icons.group_add_outlined,
                        size: NotionSize.iconMd,
                      ),
                      title: l10n.createGroup,
                      onTap: () => context.go('/rooms/newgroup'),
                    ),
                    if (PlatformInfos.isMobile)
                      NotionListRow(
                        leading: const Icon(
                          Icons.qr_code_scanner_outlined,
                          size: NotionSize.iconMd,
                        ),
                        title: l10n.scanQrCode,
                        onTap: controller.openScannerAction,
                      ),
                    const NotionSectionHeader(title: 'Your Matrix ID'),
                    NotionListRow(
                      title: userId,
                      trailing: NotionIconButton(
                        icon: Icons.copy_outlined,
                        label: 'Copy your ID',
                        onPressed: controller.copyUserId,
                      ),
                    ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: NotionSpace.xl,
                        ),
                        child: Material(
                          shape: RoundedRectangleBorder(
                            borderRadius: NotionRadius.mdAll,
                            side: BorderSide(
                              color: context.notion.colors.border,
                            ),
                          ),
                          color: context.notion.colors.surface,
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => showQrCodeViewer(context, userId),
                            child: Padding(
                              padding: const EdgeInsets.all(NotionSpace.md),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 200,
                                ),
                                child: PrettyQrView.data(
                                  data: 'https://matrix.to/#/$userId',
                                  decoration: PrettyQrDecoration(
                                    shape: PrettyQrSmoothSymbol(
                                      roundFactor: 1,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                )
              : FutureBuilder(
                  key: ValueKey(searchResponse),
                  future: searchResponse,
                  builder: (context, snapshot) {
                    final result = snapshot.data;
                    final error = snapshot.error;
                    if (error != null) {
                      return NotionEmptyState(
                        key: const ValueKey('error'),
                        icon: Icons.cloud_off_outlined,
                        title: 'Couldn’t search for people',
                        message: error.toLocalizedString(context),
                        action: NotionButton(
                          icon: Icons.refresh_outlined,
                          label: l10n.tryAgain,
                          onPressed: controller.searchUsers,
                        ),
                      );
                    }
                    if (result == null) {
                      return NotionSkeleton(
                        child: Column(
                          children: [
                            for (var i = 0; i < 6; i++)
                              const NotionSkeletonRow(),
                          ],
                        ),
                      );
                    }
                    if (result.isEmpty) {
                      return NotionEmptyState(
                        key: const ValueKey('empty'),
                        icon: Icons.search_off_outlined,
                        title: l10n.noUsersFoundWithQuery(
                          controller.controller.text,
                        ),
                      );
                    }
                    return NotionEntranceScope(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, contact) in result.indexed)
                            _ResultEntrance(
                              index: i,
                              playKey: contact.userId,
                              child: NotionListRow(
                                leading: Avatar(
                                  name:
                                      contact.displayName ??
                                      contact.userId.localpart ??
                                      contact.userId,
                                  mxContent: contact.avatarUrl,
                                  presenceUserId: contact.userId,
                                ),
                                title:
                                    contact.displayName ??
                                    contact.userId.localpart ??
                                    contact.userId,
                                subtitle: contact.userId,
                                onTap: () => controller.openUserModal(contact),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Only the first screenful rises in; the results are one column, so later
/// rows stay still.
class _ResultEntrance extends StatelessWidget {
  final int index;
  final Object playKey;
  final Widget child;
  const _ResultEntrance({
    required this.index,
    required this.playKey,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => index < NotionMotion.staggerCap
      ? NotionEntrance(
          playKey: playKey,
          rise: NotionMotion.riseList,
          child: child,
        )
      : child;
}
